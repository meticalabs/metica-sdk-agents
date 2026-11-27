---
name: ab-assignment
description: Wire Metica's AB Assignment package (com.abassignment.unity) into a Unity project that has both a MeticaSDK route and the game's own AppLovin MAX route, or check a wiring that already exists. Sets the route from ABAssignment.Current.RunMetica when ads start, gives MeticaSDK and MAX the same user id, adds ReportRemoteConfig, ReportAdsInit and TagPlacement on both routes, then runs the validator's ab_assignment rules. Use when the user asks to add, set up, integrate, wire, check or review AB Assignment, the Metica vs Baseline split, the assignment library, or ABAssignment code.
---

# Metica AB Assignment

> This is a skill, not a sub-agent, because the work is a conversation: the user confirms the plan, answers the user id question, and often comes back with a device log. It runs on any integration, whether the integrator generated it or the studio wrote it by hand.

AB Assignment splits players into a Metica group (ads through MeticaSDK) and a Baseline group (ads through the game's own MAX code).
This skill connects the package to a project that already has both routes, and checks the result.

It has two modes:

- **Wire** (the default): discover, plan, edit after one approval, then check.
- **Check only**: when the user asks to check, validate or review. It runs Steps 1, 2, 6 and 7 and writes nothing.

## Resolve the plugin root

Defensive - `$CLAUDE_PLUGIN_ROOT` is sometimes unset in plugin bash environments, so locate the resolver across known install locations and self-verify the root.

```bash
PLUGIN_DIR=""
for cand in "${CLAUDE_PLUGIN_ROOT:-}" "${METICA_SDK_AGENTS_DIR:-}" \
            "$(ls -d "$HOME"/.claude/plugins/cache/*/metica-sdk-agents/* 2>/dev/null | sort -V 2>/dev/null | tail -1)" \
            "$HOME"/.claude/plugins/cache/*/metica-sdk-agents/* \
            "$HOME/.claude/plugins/marketplaces/metica-sdk-agents" \
            "$HOME/.claude/plugins/metica-sdk-agents" \
            "$HOME/.metica-sdk-agents" "$HOME/dev/metica-sdk-agents"; do
    [ -n "$cand" ] && [ -f "$cand/scripts/resolve-plugin-dir.sh" ] || continue
    PLUGIN_DIR="$(bash "$cand/scripts/resolve-plugin-dir.sh" 2>/dev/null)" && [ -n "$PLUGIN_DIR" ] && break
done
[ -n "$PLUGIN_DIR" ] || { echo "Could not locate metica-sdk-agents plugin root. Set METICA_SDK_AGENTS_DIR to the plugin path and retry." >&2; exit 1; }
```

## Read the rules first

Read `$PLUGIN_DIR/references/ab-assignment.md` completely before anything else.
It is the single source of truth: the package rules, the user id rule, and every code shape this skill writes.
Take each line you add from its "Code shapes" section.

## Step 1 - Preconditions

1. **Project.** Find the Unity project root: the nearest directory, from `$(pwd)` up to four parents, that holds `ProjectSettings/ProjectSettings.asset`, unless the user passed `PROJECT`. Say which project you found.
2. **Package.** Follow "Detecting the package" in the reference.
   - Absent: stop. Point the user to the install step in the package README (<https://github.com/meticalabs/ab-assignment-unity#1-install>).
   - Legacy id: stop. Tell the user to move to `com.abassignment.unity` first.
3. **Both routes are in the code.**
   - MeticaSDK is integrated: game code outside `Assets/MeticaSdk/` calls `MeticaSdk.Initialize(` or `MeticaSdk.InitializeAsync(`. If it does not, stop and tell the user to run the `unity-integrator` agent first. With the package installed, the integrator keeps the game's MAX path.
   - The game's own MAX path is still there: game code, or the game's MAX wrapper, calls `MaxSdk.InitializeSdk(`. If an earlier integration removed it, stop: the Baseline group has nothing to run. The user restores it (the `pre-metica-integration` git tag holds the original) or re-runs the integrator with `MAX_MODE=switchable`.
4. **Mode.** In client-managed mode the game owns the split: run check only, and say why.

## Step 2 - Discover

Read the game code and record each finding with its `file:line`:

- **Route decision.** Either a `MeticaAdService.UseMetica` switch (the integrator's switchable output) and the place the bootstrap reads it, or a branch the studio wrote between the MeticaSDK init and the MAX init, with the value that drives it.
- **Ads start.** The method that starts ads, and what calls it. Note when it runs at app start (`Awake` / `Start` of the first scene, a `RuntimeInitializeOnLoadMethod`).
- **Package calls already present.** `ABAssignment.Initialize`, `ReportRemoteConfig`, `Current` / `TryGetCurrent`, `ReportAdsInit`, `TagPlacement`, `ReportCustomId`.
- **Remote Config.** Where the game fetches and activates Remote Config, and whether its in-app defaults (`SetDefaultsAsync`) include `metica_assignment`.
- **User ids.** The third argument of `MeticaInitConfig`, and every `MaxSdk.SetUserId` call.
- **Placements.** Every placement argument passed to a show call and every banner / MRec placement setter, on both routes.
- **Assembly definition.** The `.asmdef` that owns the files you will edit, if there is one.
- **The game's own GDPR prompt**, if it has one. This is for the report only.

Grep finds candidates; Read the surrounding lines to confirm each one is live code, not a comment or a string.

## Step 3 - Plan and one approval

Show the findings, then the edits you will make, each as file plus kind of change. Prefer plan mode when it is available.
Raise these before asking for approval:

- Ads start at app start: the group would be decided before Remote Config answers. Moving the ads start is the user's decision.
- No Remote Config fetch in the game: the package cannot learn the value. The package ships a ready fetch in its "Basic integration" sample.
- Another value already decides the route (a remote flag, another A/B test): the package has to be the only thing that decides it. The package's own `SetDebugOverride` is a development tool and does not count.
- `MaxSdk.SetUserId` already called with an id that is not the one on the Metica route.
- A `null` or empty MeticaSDK user id, or a MAX route with no `MaxSdk.SetUserId`: the package does not know the id the ad stack uses.

Ask the user id question, unless both routes already use `ABAssignment.UserId`:

```
MeticaSDK and MAX must get the same user id, and the package must know it.
  1) ABAssignment.UserId (default: the package's own id, nothing else to wire)
  2) your own stable player id (type the C# expression): it goes to both routes
     and is reported with ABAssignment.ReportCustomId
```

Offer option 2 only when the pinned package version is 2.2.0 or later (`ReportCustomId` starts there); on an older pin, say that the own-id case needs the upgrade first.

Take one approval for the whole plan. Write nothing before it.

## Step 4 - Snapshot

When the project is a git repository with a clean tree, tag the current commit before the first edit:

```bash
git -C "$PROJECT" tag -f pre-ab-assignment
```

With uncommitted changes or no repository, tell the user and wait for a go-ahead.

## Step 5 - Apply the edits

Make each edit with the shapes from the reference, skip what Step 2 found already in place, and keep the game logic around every call you touch (frequency caps, cooldowns, availability guards).

1. **App start.** Add the `ABAssignment.Initialize` startup method to the class that owns the MeticaSDK init (the generated `MeticaAdService` when there is one). Give it the same app id and API key that `MeticaInitConfig` gets: reuse the constants when the code has them, and repeat the same literals when it does not (the integrator's generated `MeticaAdService` holds literals). Mind the argument order, which the reference spells out.
2. **Remote Config.** Add the three `ReportRemoteConfig` calls to the game's existing fetch, ahead of its other handlers.
3. **Ads start.** Make the package's decision drive the route, read once where ads start.
   - With a `MeticaAdService.UseMetica` switch: assign `ABAssignment.Current.RunMetica` to it immediately before the bootstrap reads it.
   - With a branch the studio wrote: read `ABAssignment.Current.RunMetica` once into a local at the ads start and branch on that.
4. **Metica route.** Pass the chosen user id to `MeticaInitConfig` (`ABAssignment.UserId`, or the `UserId` of an `AssignmentResult` the code already holds: it is the same id). Report `AdsInitStage.Started` just before the MeticaSDK init, and the outcome with the SmartFloors group and forced-holdout flag once init returns.
5. **MAX route.** Call `MaxSdk.SetUserId` with the same id before `MaxSdk.InitializeSdk()`. Report `AdsInitStage.Started` before the init and the outcome from the game's `OnSdkInitializedEvent` handler, back on the main thread.
6. **Placements.** Pass every placement through `ABAssignment.TagPlacement` on both routes, and set the tagged banner / MRec placement after each create.
7. **Own id.** When the user chose their own id, add the `ReportCustomId` call next to the ads-start read.

When an edited file compiles into an assembly definition, add `AB.Assignment` to that asmdef's references. Code in `Assembly-CSharp` needs nothing.

## Step 6 - Check

Run the `unity-validator` agent on the project in a fresh subagent context, and give it only the project path.
A marketplace install names it `metica-sdk-agents:unity-validator`; in Codex it is the `metica_unity_validator` custom agent.

From its JSON:

- Report every `ab_assignment_*` row with its level, location and detail.
- For an `ab_assignment_*` FAIL in a file this run edited, fix it and run the validator once more. Stop after two rounds.
- Report any other FAIL in one line each. Those rules belong to the MeticaSDK integration itself, and this skill does not change them.

In check-only mode this step is the result.

## Step 7 - Report

- **Wired:** each edit with its `file:line`, and the user id both routes now use.
- **Left to the user:**
  - Publish the `metica_assignment` Remote Config parameter: JSON, no conditions, no in-app default. The package README has the steps and a command-line tool (<https://github.com/meticalabs/ab-assignment-unity#2-set-up-the-firebase-parameter>).
  - Stop any other test that decides Metica on or off.
  - Call `ABAssignment.SetConsentStatus` from the game's own GDPR prompt, when it has one and does not call it yet.
  - The kill switch is the same parameter with `"enabled": false`.
- **Check on a device.** In a development build, `adb logcat -s Unity | grep ABAssignment` shows:
  - `Events go to Metica ingestion at ... for app <app id>.`
  - `Group metica, route metica, ...` or `Group baseline, route own, ...`
  - `Sent <n> event(s) to Metica (HTTP 202, ...)`
  - ad placements that start with `metica|` or `baseline|`
- **Undo:** `git reset --hard pre-ab-assignment`, when Step 4 created the tag. Print it as a hint; never run it.

## Hard rules

- Never edit files under `Assets/MaxSdk/`, `Assets/MeticaSdk/` or the package folder.
- Never add a read of `ABAssignment.Current`, a `TagPlacement` call or a `ReportAdsInit` call that runs at app start.
- Never write a Remote Config fetch the game does not have, and never add an in-app default for `metica_assignment`.
- One approval before the first write. Check-only mode writes nothing.
- Never print API keys or SDK keys.
