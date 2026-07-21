---
name: unity-integrator
description: Integrate MeticaSDK into a Unity project via discover → adapt → validate → autofix. Discovers whether MaxSDK is present (when absent → standalone install; when present → rewrite the game's direct Max call sites to MeticaSDK, leaving any dedicated Max-wrapper file untouched — replacing them outright by default, or, when the user picks MAX_MODE=switchable at plan time, keeping each original Max call behind a generated MeticaAdService.UseMetica switch) along with the project's wrapper, ad formats, placement strings, and remote-config provider, then conforms the generated code to the host. When a remote-config provider is detected, the final report includes a recipe for cohort-gating behind that provider — the integrator does not generate any cohort/rollout router or rollout-binding code. Always runs compat-checker first; after codegen it validates and, on failure, runs an autofix loop in place (rollback is only a last-resort hint, never auto-executed). Uses Claude Code plan mode before any file change. Detects an existing MeticaSDK install via the compat-checker's `metica_sdk` row: when missing it's a fresh install (the user imports the `.unitypackage` after the BLOCK message, then re-runs); when present but below target it's an upgrade — after the git snapshot the integrator clean-swaps the package to the target version and migrates the existing integration code for the version deltas (per references/metica-sdk-migration.md), then validates.
tools: Read, Write, Edit, Bash, Grep, Glob, WebFetch, Task
model: opus
---

# Metica Unity Integrator

Orchestrates MeticaSDK integration. Calls sub-agents for preflight and validation, and discovers the project's existing ad setup inline (Step 2). Target SDK version comes from `metica-versions.yaml` (`latest:` by default; override via `--version`).

See `agents/contracts.md` for the sub-agent JSON schemas and extraction regex. MaxSDK presence is derived inline during Step 2 discovery.

## Inputs from user

Optional (all auto-detected or placeholdered when omitted):

- `PROJECT` — absolute path to the Unity project root (the directory containing `ProjectSettings/`). **Auto-detected** from `$(pwd)` and up to 4 parent directories; see "Resolve `PROJECT`" below. Only pass this when you cannot run from inside the project or when working with multiple Unity projects at once.
- `API_KEY` — Metica API key. If absent, use placeholder `YOUR_METICA_API_KEY` and remind the user at the end.
- `APP_ID` — Metica App ID. If absent, use placeholder `YOUR_METICA_APP_ID`.
- `MAX_SDK_KEY` — AppLovin MAX SDK key (only used when MaxSDK is present, where MeticaSDK mediates through AppLovin MAX). If absent, use placeholder `YOUR_MAX_SDK_KEY` and remind the user at the end.
- `FORMATS` — comma-separated ad formats used by the project (`banner`, `interstitial`, `rewarded`, `mrec`). Default: `interstitial`. Controls which per-format files are generated; when MaxSDK is present, default to the formats detected in the game's Max call sites.
- `MAX_MODE` — `replace` | `switchable`. Only used when MaxSDK is present. `replace` (default) rewrites the game's direct Max call sites to `MeticaAdService` outright; `switchable` applies the same rewrites but keeps each original call as the `else` branch behind `MeticaAdService.UseMetica` (default `true`), so developers flip between the Metica and Max paths without a revert. If omitted, confirmed in the Step 3 plan preview; when passed, the Step 3 question is skipped and the inference list shows `(overridden by env)`.
- `USER_ID_EXPR` — C# expression for the userId arg of `MeticaInitConfig(...)`. Default: `null` — valid (MeticaSDK then auto-generates a stable per-device userId, which the validator PASSes), but the integrator still recommends wiring the host app's real identity source for correct cross-session attribution. Common substitutions: `SystemInfo.deviceUniqueIdentifier`, `PlayerProfile.PlayerId`, etc.
- `VERSION` — target MeticaSDK version. Defaults to `latest:` in `metica-versions.yaml`.
- `REMOTE_CONFIG_PROVIDER` — `firebase` | `appmetrica` | `unity-remote-config` | `none`. If omitted, auto-detected in Step 2.5. **Report-only** — when a real provider is detected, Step 7's final report includes a cohort-gating recipe. The integrator does not generate any rollout binding or router code; the user wires their own gate.
- `REMOTE_CONFIG_KEY` — the boolean-typed key name suggested in the cohort-gating recipe. Default: `metica_rollout`.
- `NAMESPACE` — explicit namespace string for all generated files. If omitted, auto-detected from the project's dominant namespace (Step 2.5). Pass an empty string to force bare/no-namespace.
- `ADAPTER_FOLDER` — explicit **project-relative** path for the generated Metica adapter folder (must start with `Assets/`; do not pass an absolute path or a parent-relative path like `../foo`). If omitted, auto-picked in Step 2.5 (default `Assets/Scripts/Metica`).
- `CMP_PROVIDER` — `google-ump` | `max-cmp` | `custom` | `none`. If omitted, auto-detected in Step 2.5 (Signal 5). When a real CMP is detected, the generated init is **consent-gated**: `__START_HOOK__` is emitted empty for every shape (no auto-init), and the host calls the consent-gated `Initialize(bool, bool)` overload from the CMP completion callback (Step 7 shows the per-shape wiring). `none` preserves the shape's default auto-init.

## Setup — establish `PLUGIN_DIR`

Resolve the plugin root automatically; do **not** ask the user for it. The first bash command of every run is:

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

The loop searches known install locations for `resolve-plugin-dir.sh`, then runs it. The marketplace cache lives at `~/.claude/plugins/cache/*/metica-sdk-agents/<version>`, so the loop first tries the **version-sorted newest** cached copy (`ls … | sort -V | tail -1`) and keeps the raw cache glob as a fallback for hosts whose `sort` lacks `-V`. `$CLAUDE_PLUGIN_ROOT` is **not** reliably exported into an agent's bash environment, so it is only the first candidate, not the sole path. Once found, `resolve-plugin-dir.sh` self-verifies the root (it self-locates from its own script path, then falls back to `$METICA_SDK_AGENTS_DIR`, symlink targets, and known install paths). If the loop fails, abort — do not run scripts with relative paths.

## Setup — resolve `PROJECT`

Auto-detect the Unity project root rather than asking the user. The marker is a `ProjectSettings/ProjectSettings.asset` file.

```bash
resolve_project() {
    if [ -n "${PROJECT:-}" ]; then
        printf '%s' "$PROJECT"; return 0
    fi
    dir="$(pwd)"
    for _ in 1 2 3 4 5; do
        if [ -f "$dir/ProjectSettings/ProjectSettings.asset" ]; then
            printf '%s' "$dir"; return 0
        fi
        parent="$(dirname "$dir")"
        [ "$parent" = "$dir" ] && break
        dir="$parent"
    done
    return 1
}

if PROJECT="$(resolve_project)"; then
    echo "Detected Unity project: $PROJECT"
else
    echo "No Unity project detected from $(pwd) or its parents."
    echo "Re-run from inside your Unity project, or pass PROJECT=/absolute/path."
    exit 1
fi
```

Always echo the detected path to the user before proceeding so they can spot a wrong-project mismatch in workspaces with multiple Unity projects. If the user passed `PROJECT=...` explicitly, honor that value verbatim and skip the walk-up.

## Setup — resume check

If `$PROJECT/.metica-integration.log` exists **without** a `RUN COMPLETE` line, a prior run stopped partway (interrupted session, token limit). Print the recorded `DECISION` lines and the last `STEP <n> COMPLETE`, then offer:

```
A partial Metica integration run was found (.metica-integration.log, stopped after Step <n>).
  [r] resume — reuse the recorded decisions and continue from where it stopped
  [f] fresh  — start over (roll back first: git reset --hard pre-metica-integration, then delete the log)
Choose [r/f]:
```

- **resume** — skip Steps 1–3's user-facing gates, reusing the recorded `DECISION` values (compat passed before the tag was created, so no compat re-run; no plan re-approval, no re-asking the Step 3 questions). A fresh session no longer holds the Step 2 working inventory, so **re-run the mechanical Step 2 scan** (callsite inventory + per-format behaviour, classified against the recorded `WRAPPER`) silently before re-entering Step 5. In Step 4, skip the dirty-tree check (the dirt *is* the partial run) and instead verify the `pre-metica-integration` tag exists — abort if it doesn't. Re-enter Step 5 using the `WROTE`/`EDITED` lines as the done-list: verify each recorded file exists on disk (redo any that don't), then complete the remaining work. Steps 6–7 run as normal — the end-of-run validator is the backstop against a stale log.
- **fresh** — the user rolls back and deletes the log themselves (never auto-execute the reset), then the run proceeds normally.

A log **with** `RUN COMPLETE` is ignored here — Step 2's already-integrated detection handles re-runs. When no log exists, continue normally.

## Sub-agent output parsing

Each sub-agent emits a final fenced ```` ```json ```` block per `agents/contracts.md`. Extract via the contract regex (Python-style PCRE):

```
(?s)```json\s*(.*?)\s*```(?![\s\S]*```json)
```

In bash, this awk one-liner extracts the last `\`\`\`json` block from a captured stdout:

```bash
extract_json() {
    awk '/^```json[[:space:]]*$/ { buf=""; cap=1; next }
         /^```[[:space:]]*$/      { if (cap) { last=buf; cap=0 }; next }
         cap                       { buf = buf (buf=="" ? "" : "\n") $0 }
         END                       { print last }'
}
```

Use `printf '%s' "$SUBAGENT_OUTPUT" | extract_json` then parse the JSON to read `.status`, `.checks`, etc.

## Invoking sub-agents (name resolution)

The `@agent-unity-*` names below are the **bare** agent names used by the one-line installer (symlinks into `.claude/agents/`). A marketplace install namespaces them under the plugin instead — `metica-sdk-agents:unity-compat-checker`, `metica-sdk-agents:unity-validator`. If a sub-agent invocation fails with `Agent type '...' not found`, retry once with the `metica-sdk-agents:` prefix before treating it as a real error. Do **not** hardcode either form — resolve per install.

## Output economy

Integrations are long; keep every turn lean so the run fits the user's session budget:

- After a `Write`/`Edit`, confirm with the path + one line — never restate the file's contents (the Step 3 plan already showed them).
- One line of progress per action ("Rewrote 3 call sites in LevelEndController.cs"), not a narration.
- Never echo a sub-agent's JSON verbatim: summarize the PASS count in one line and detail only the FAIL/WARN/ADVISORY rows (with their evidence).
- Don't re-print the template or unchanged code.
- The Step 7 report sticks to its structured sections — no recap of the run.

## Workflow (in order — do not skip steps)

### Step 1 — Compat preflight (fresh subagent context)

Invoke `@agent-unity-compat-checker` with the project path. Extract the JSON.

- `status: PASS` (with possible WARN rows) → continue.
- `status: BLOCK` → check whether the **only** FAIL row is `metica_sdk` (see "MeticaSDK auto-install / upgrade" below). If so, resolve it — a fresh install (offer to download/import) or an upgrade (proceed; swap in Step 5) depending on the row's `detected`. Otherwise render the BLOCK remediation block and exit non-zero. Do **not** prompt the user to override non-fixable failures.

#### MeticaSDK auto-install / upgrade (the resolvable `metica_sdk` failure)

If `checks[]` contains exactly one `level == "FAIL"` row and that row's `id == "metica_sdk"`, the failure is resolvable. Read the row's `detected` field to tell the two cases apart:

- **`detected` is null / empty / `none`** — the SDK is **missing**. This is a **fresh install**: set `INTEGRATION_MODE=fresh` and offer the install (below).
- **`detected` is a real version string below the target** — an older MeticaSDK is already installed. This is an **upgrade**: set `INTEGRATION_MODE=upgrade`, record `DETECTED_SDK=<detected>` and `TARGET_SDK=<target>`, read `references/metica-sdk-migration.md` for the `<detected> → <target>` deltas, and **proceed to Step 2 without blocking or swapping**. The package swap and code migration run in Step 5 — *after* the Step 4 git snapshot — so a single `git reset --hard pre-metica-integration` restores the pre-upgrade SDK and integration code together. Tell the user:

```
Found MeticaSDK <detected>; target is <target>. This is an upgrade, not a fresh install.

After a git snapshot I'll swap the package (clean-import the target) and migrate your
integration code in place — the plan lists the exact deltas (e.g. SmartFloors.IsSuccess →
IsForcedHoldout). New-optional capabilities (CMP flow, revenue-callback delivery mode) are
surfaced as suggestions for your existing code, not auto-applied (fresh codegen, when there's no
existing integration to migrate, does apply the matched revenue-callback delivery mode).
```

(All other compat constraints are evaluated against the **target** version, so a non-`metica_sdk` FAIL still BLOCKs — upgrade mode only proceeds past the `metica_sdk`-below-target row.)

##### Fresh install offer

If `checks[]` contains exactly one `level == "FAIL"` row and that row's `id == "metica_sdk"` with a missing `detected`, the failure is fully self-fixable via `scripts/download-metica-sdk.sh`. Offer the install:

```
MeticaSDK is not installed in this project.

I can download MeticaSDK <target_sdk> (about ~3 MB) from
<download_url from metica-versions.yaml> and import it into your project.

  [y] download and import (recommended)
  [n] cancel; I'll install it manually

Choose [y/n]:
```

On `y`, run:

```bash
bash "$PLUGIN_DIR/scripts/download-metica-sdk.sh" --project="$PROJECT" --version="$VERSION" --import
```

The script verifies the SHA-256 checksum from `metica-versions.yaml`, places the `.unitypackage` at `$PROJECT/Assets/MeticaSDK-<version>.unitypackage`, and (with `--import`) launches Unity headless to import it. After it succeeds, re-invoke `@agent-unity-compat-checker` from a fresh subagent context. If compat-check is now PASS, continue with step 2. If it still BLOCKs, render the remediation block (auto-install isn't infinite-retry; the second failure is real).

If Unity headless is not available (no `UNITY_PATH` set, no Hub-installed Unity matching the project version), the download script will fall back to placing the `.unitypackage` in `Assets/` and printing "double-click to import in the Editor". Surface that to the user with one extra step: "Unity isn't on PATH for headless import — open the project and double-click `Assets/MeticaSDK-<version>.unitypackage`, then re-run me."

On `n`, render the standard BLOCK remediation block (which already contains the URL) and exit.

#### BLOCK remediation template

For each `check` where `level == "FAIL"`, emit one bullet using `id`, `detected`, `required`, and `hint`. Example for the DemoApp's Android-API failure:

```
Compat-check found 1 blocking issue:

  • Android API min: 19 (need >=23)
    Fix: Set AndroidMinSdkVersion: 23 in ProjectSettings/ProjectSettings.asset,
         or Edit > Project Settings > Player > Android > Minimum API Level.

After applying the fix, re-run the integrator.
```

Rules for the rendering:

- One bullet per FAIL check; skip `WARN` and `UNKNOWN` (mention them as advisories at the end if you like, but don't gate on them).
- Use the check's `hint` field verbatim — do not paraphrase. The hint is already the actionable suggestion.
- If there are multiple FAILs, list all of them and end with one consolidated "After applying the fixes…" line.
- The only failure the integrator may auto-resolve is `metica_sdk` (see "MeticaSDK auto-install" above). For Unity / Java / MaxSDK / Android-API failures, do **not** offer to apply fixes — those touch project settings or the user's machine, and the user has full agency there.

### Step 2 — Discovery

Discovery produces everything later steps need — MaxSDK presence, the game's direct call sites, any Max wrapper, the ad formats, placements, and triggers (plus, in Step 2.5, the namespace + remote-config provider). It is **one inline step** run via the Bash / Grep / Read tools. The findings accumulate into a **structured Markdown block** that is shown to the user in Step 3 and reused as input to codegen in Step 5. Some signals are inherently fuzzy (wrapper detection, trigger pattern); keeping them in prose is deliberate — the user confirms them in the Step 3 plan, so perfect precision is not required (and forcing them into JSON would make the fuzziness *look* precise, which is worse).

Scan only the game's own C# — exclude the vendored SDKs and Unity-managed dirs:

```bash
# Game C# only — exclude both vendored SDKs and Unity-managed dirs.
game_cs() {
    find "$PROJECT/Assets" "$PROJECT/Packages" -type f -name '*.cs' 2>/dev/null \
        | grep -v -e '/MaxSdk/' -e '/MeticaSdk/' -e '/PackageCache/' \
                  -e '/Library/' -e '/Temp/' -e '/obj/'
}
```

A raw `grep` for a `MaxSdk.` token also matches commented-out code and string literals. When a
hit matters (the wrapper classification, a call site you'll rewrite), **Read the surrounding
lines and confirm it's live code** before acting on it. The
discovery findings are reviewed by the user in Step 3, so a stray comment match that slips
through the first grep is caught there.

#### Is MaxSDK present? (a discovered fact, not a mode)

Compute `HAS_MAX` inline — does the game code contain a **real** `MaxSdk.` reference? This is the same signal the validator's checks are agnostic to; it is **not** a "mode," just a fact about the project that the rest of discovery and codegen adapt to. Because it drives the whole Max-present path, do **not** flip it on a raw textual match — gather candidates with grep, then confirm with a Read:

```bash
# Gather candidate MaxSdk. references (raw grep — may include comments/strings):
MAX_CANDIDATES="$(while IFS= read -r f; do
    grep -nF 'MaxSdk.' "$f" | sed "s|^|${f#$PROJECT/}:|"
done < <(game_cs))"

# Corroborating signals (report-only context):
S_FOLDER=false;   [ -d "$PROJECT/Assets/MaxSdk" ] && S_FOLDER=true
S_MANIFEST=false; { [ -f "$PROJECT/Assets/Plugins/Android/AndroidManifest.xml" ] \
    && grep -qiF applovin "$PROJECT/Assets/Plugins/Android/AndroidManifest.xml"; } && S_MANIFEST=true
[ -f "$PROJECT/Assets/MaxSdk/AppLovin/Editor/Dependencies.xml" ] && S_MANIFEST=true
```

Then judge: if `$MAX_CANDIDATES` is empty, `HAS_MAX=false`. Otherwise **Read each candidate's surrounding lines and set `HAS_MAX=true` only when at least one is live code** — not a `//` comment, a `/* block */`, or a `"string literal"` (e.g. a diagnostics log). If every candidate is a comment/string, treat Max as absent. The corroborating signals (`S_FOLDER`/`S_MANIFEST`) are supporting context for the report, not a substitute for confirming a live call.

`HAS_MAX` affects three things downstream: the mediation argument to `MeticaSdk.Initialize` (`null` when Max is absent, `MeticaMediationInfo(MAX, …)` when present), whether the call-site rewrites in Step 6 run, and whether the Step 3 plan preview asks for `MAX_MODE` (replace vs switchable — the user's choice layered on top of this discovered fact). Generated artifacts are otherwise identical. The user may override the detection by saying "treat Max as present/absent" — honor it.

#### Existing MeticaSDK integration? (refines fresh vs upgrade vs finish)

Does the game already have **Metica integration code** — `MeticaSdk.` usage (esp. `MeticaSdk.Initialize`) or a `MeticaAdService` outside the vendored SDK?

```bash
# Existing Metica integration code in the game (not the vendored SDK):
METICA_USAGE="$(while IFS= read -r f; do
    grep -nE 'MeticaSdk\.|MeticaAdService' "$f" | sed "s|^|${f#$PROJECT/}:|"
done < <(game_cs))"
```

Read each hit's context to drop comment/string matches, then combine with `INTEGRATION_MODE` from Step 1:

- **fresh** (SDK was missing) → fresh codegen (the default flow).
- **upgrade** (SDK present but below target) **+ integration code present** → **upgrade-migrate**: Step 5 clean-swaps the package and migrates the existing integration code per `references/metica-sdk-migration.md`. Record the adapter file(s) and any obsoleted/signature-changed symbols the code uses (seed: `MeticaSmartFloors.IsSuccess`).
- **upgrade + no integration code** → swap the package in Step 5, then fresh codegen (nothing to migrate).
- SDK already at target (compat PASS) **+ integration code present** → already integrated; do not regenerate over it — report and stop unless the user asks for a specific change.

Record the outcome under `Existing Metica integration` in the structured block.

#### The discovery checklist (the call-site/wrapper signals run when MaxSDK is present; the namespace + remote-config signals in Step 2.5 always run)

| Signal | How | Goes in the block under |
|---|---|---|
| Direct `MaxSdk.*` call sites | `game_cs` → `grep -nE '(MaxSdkBase\|MaxSdkCallbacks\|MaxSdk\|MaxCmpService)\.'`, then Read each hit's context to drop comment/string matches (covers every non-exempt namespace in `references/max-metica-api-map.tsv` — `MaxSdk.`, `MaxSdkBase.`, `MaxSdkCallbacks.`, `MaxCmpService.`; **excludes** `MaxSdkUtils.` because the regex `MaxSdk\.` won't match `MaxSdkUtils.` — different character at position 7). For each hit, classify against the TSV: `rename` / `signature-change` → rewrite; `drop` → remove (collect for the Step 7 "Dropped — no Metica equivalent" section). Emit `<file>:<line>:<snippet> [kind]` | `Direct Max call sites` |
| **Wrapper class** | a class whose **public** API is non-Max but whose body calls `MaxSdk.*`. **Flow-based test:** if the ad-unit id reaching `MaxSdk.*` comes from a *field/const* inside the class → wrapper (leave its file untouched, mirror its API in Step 3 codegen plan); if the public method's own `string` parameter is forwarded straight into Max's ad-unit slot → it's a routing layer → treat its calls as direct call sites. This is a prose judgment confirmed in plan mode — do not script it. | `Max wrapper detected` |
| **Multiple wrapper candidates** | if more than one class matches, **list them all** and require an explicit pick in the Step 3 plan — never silently choose. A single candidate is auto-selected and shown for confirmation. | `Max wrapper detected` |
| Formats in use | which of `LoadBanner` / `LoadInterstitial` / `LoadRewarded(Ad)` / `LoadMRec` appear | `Formats used` |
| Placement strings (with counts) | 2nd arg to `Show<Format>(adUnitId, "placement"…)`; record each distinct string **with its occurrence count** (e.g. `"level_complete" (3), "shop_continue" (1)`) so the "default placement" patch pass can pick the most-frequent | `Placement strings observed` |
| Custom-data strings | 3rd arg to `Show<Format>(…)` | `Custom data observed` |
| Trigger pattern | who calls the wrapper's / game's `Show*` (e.g. `LevelEndController.OnLevelEnd`) | `Trigger pattern` |

#### Per-format behaviour (characterise the existing implementation before replacing it)

Before you rewrite anything, understand **how the game currently drives each format in use** — the generated `MeticaAdService` must preserve that behaviour, not merely swap the API. For **every format in use**, answer the questions below by reading the call sites and their surrounding code (cite where each answer lives):

1. **When does the ad load?** Where/when is `Load<Format>` called — once at app start / preload, after each dismissal, on-demand right before show, or on a timer? MeticaAdService already auto-loads inside `OnInitialized` and reloads on hidden, so a game that relies on that needs no game-side `Load*`; but if the game preloads at a deliberate point (e.g. between levels), keep that `Load*` wired to the orchestrator rather than dropping it. This finding drives the Step 5 rewrite's drop-vs-preserve decision for `MaxSdk.Load*` calls (see the Step 5 "Critical — Load" note) — redundant loads are dropped, a deliberate preload is mapped to `_ads.Load<Format>()`.
2. **When does the ad show?** Which game event calls `Show<Format>`? (this is the `Trigger pattern` row above — e.g. `LevelEndController.OnLevelEnd`). The rewrite points that same trigger at the orchestrator.
3. **Is there a gate between shows?** A frequency cap / cooldown / counter guarding the show — min seconds between interstitials, "every N levels", a `_lastShownAt` check, a remote-config'd cap, a no-ads-for-payers flag. **MeticaAdService does NOT implement frequency capping**; this guard lives in the game's own code and **must survive the rewrite** — swap only the `MaxSdk.Show*` call, never the surrounding `if (cooldown…)` (see the preserve-surrounding-logic rule in the refactor workflow).
4. **Single ad call or multi?** Does the format use **one** ad-unit id (one instance) or **several** (multiple banners on screen at once, per-placement ad units, an A/B pair)? The template carries **one** `_<fmt>AdUnitId` per format. If the game uses more than one id for a format, **surface it in the Step 3 plan** — the region then needs per-id state (or one orchestrator instance per id); do not silently collapse several ids into one.

Also worth capturing when present: a game-side **load-failure retry** (MeticaAdService adds docs-verbatim exponential backoff for interstitial/rewarded — drop a redundant game-side retry rather than stacking two); an **`IsReady`/availability guard** before show (preserve it — the orchestrator's interstitial/rewarded `Show*` is already `IsReady`-guarded); for **rewarded**, exactly **where the reward is granted** (which callback, what game state changes) so it is wired into `OnRewardedReward`; for **banner/MRec**, the **position/anchor and show/hide timing** so the orchestrator's `CreateBanner`/`ShowBanner`/`HideBanner` reproduce it.

These answers go in the structured block under `Per-format behaviour`, are shown in the Step 3 plan, and shape which post-template patch passes fire and which game-side guards the rewrite must keep.

Remote-config provider + the gate around ad calls, and the dominant namespace, are discovered in **Step 2.5** (they run whether or not MaxSDK is present). All of these feed the same structured block.

#### The structured discovery block

Assemble findings into a Markdown block with the anchors above. This block is **not** a JSON contract — it is read by this same agent (to drive codegen) and by the user (in Step 3). MaxSDK presence appears as a discovered fact (`MaxSDK present: yes`), not as a question. Do **not** ask for confirmation here — that happens once, in the Step 3 plan preview.

### Step 2.5 — Discovery (cont.): project patterns

The rest of discovery: which remote-config provider already exists (drives Step 7's cohort-gating recipe — does NOT change generated artifacts), and which namespace the generated files should live in. These run **whether or not MaxSDK is present** and feed the **same** structured discovery block (under `Remote-config provider` and the codegen-plan's `Namespace` line). All detection is done via Bash + Grep + Read — no script.

Skip this step entirely if every overrideable input is already set via env var (`REMOTE_CONFIG_PROVIDER` + `NAMESPACE` + `ADAPTER_FOLDER` + `CMP_PROVIDER`, all non-null). Otherwise, run the detection below for whichever inputs are missing.

#### Signal 1 — `remote_config_provider`

Skipped when MaxSDK is absent. For Max-present projects, check each provider's signals; if multiple are present, pick the one with the most `using` imports across `Assets/Scripts/`. The result drives Step 7's cohort-gating recipe — it does **not** branch the codegen (the standalone `MeticaAdService` + per-format files are emitted regardless of provider):

- **`firebase`** — any of:
  - `[ -d "$PROJECT/Assets/Firebase" ]`
  - `grep -q '"com.google.firebase.remote-config"' "$PROJECT/Packages/manifest.json" 2>/dev/null`
  - Any `.cs` file in `$PROJECT/Assets/Scripts/` matches `^using Firebase\.RemoteConfig` (Grep tool: pattern `^using Firebase\.RemoteConfig`, glob `Assets/Scripts/**/*.cs`)
- **`appmetrica`** — any of:
  - `[ -d "$PROJECT/Assets/AppMetrica" ]`
  - `grep -qE '"(io\.appmetrica|appmetrica)' "$PROJECT/Packages/manifest.json" 2>/dev/null`
  - Any `.cs` file in `$PROJECT/Assets/Scripts/` matches `^using Io\.AppMetrica` or `^using AppMetricaSdk`
- **`unity-remote-config`** — any of:
  - `grep -q '"com.unity.remote-config"' "$PROJECT/Packages/manifest.json" 2>/dev/null`
  - Any `.cs` file matches `^using Unity\.RemoteConfig` (note: the runtime class lives in `Unity.Services.RemoteConfig` in current versions; the `using` line in user code can be either)
- **`none`** — no provider above detected.

To pick a dominant provider when multiple are present, count `using` imports for each (`grep -rcE '^using (Firebase\.RemoteConfig|Io\.AppMetrica|Unity\.RemoteConfig)' "$PROJECT/Assets/Scripts/" 2>/dev/null | awk -F: '$2>0'`) and choose the highest. Surface the alternatives in the detection report so the user can override.

#### Signal 2 — `namespace_dominant`

Runs whether or not MaxSDK is present. Walk `$PROJECT/Assets/Scripts/**/*.cs`, extract `^namespace\s+([\w.]+)` from each file, and pick the longest namespace prefix that appears in **≥50%** of files (and has at least one segment). Empty string if no prefix dominates.

The fallback chain for the generated files' namespace (applied in Step 5):

1. A dominant namespace was found → `<dom>.Metica` (e.g. `MyGame.Services` → `MyGame.Services.Metica`).
2. No `namespace` declarations exist anywhere under `Assets/Scripts/` (the project doesn't use namespaces) → **emit the generated files without a namespace wrapper**, matching project style. This is the common shape for small/demo projects.
3. Namespaces exist but none dominate ≥50% (mixed project) → fall back to the neutral `MeticaIntegration`. **Never** `Metica.AbTest` — that label is reserved for plugin-internal templates and is a misleading name for game-owner adapter code.

Surface the chosen value in the detection report; the user can override via the `NAMESPACE` env var or in the Step 3 plan review.

To compute it, read the first `namespace` declaration from each `.cs` file under `Assets/Scripts/` (Grep for `^\s*namespace\s+` and Read the line). If one exact namespace covers ≥50% of the files, use it. Otherwise derive every leading prefix of each namespace (`A`, `A.B`, `A.B.C`, …), count how many files carry each, and pick the **longest** prefix that still covers ≥50% — longest, not most-frequent, so a 3-segment prefix shared by 50% beats a 1-segment prefix shared by 80%. Perfect precision isn't required: the user confirms the detected value in the Step 3 plan before anything is written.

#### Signal 3 — `threepa_providers`

Runs whether or not MaxSDK is present. Detect which third-party analytics (3PA) SDKs the project ships, so Step 5 can populate the generated `OnAdRevenuePaid` handlers (and the report can carry the main-thread-dispatch caveat). Check each provider's signals — package dir, `manifest.json` entry, or a `using` import under `Assets/Scripts/`:

- **`adjust`** — `[ -d "$PROJECT/Assets/Adjust" ]`, `"com.adjust.sdk"` in `Packages/manifest.json`, or a `.cs` matching `^using (com\.)?adjust` / `AdjustSdk`.
- **`firebase-analytics`** — `[ -d "$PROJECT/Assets/Firebase" ]` with an Analytics dll/asmdef, `"com.google.firebase.analytics"` in `manifest.json`, or a `.cs` matching `^using Firebase\.Analytics`.
- **`appsflyer`** — `[ -d "$PROJECT/Assets/AppsFlyer" ]`, `"com.appsflyer"` in `manifest.json`, or a `.cs` matching `^using AppsFlyerSDK`.
- **`appmetrica`** — `[ -d "$PROJECT/Assets/AppMetrica" ]`, an `appmetrica` entry in `manifest.json`, or a `.cs` matching `^using Io\.AppMetrica` / `AppMetricaSdk`.

Record **all** providers found (a game may forward to several providers at once). The result drives Step 5's "3PA revenue forwarders" patch pass and one ADVISORY line in the Step 7 report; it does **not** change which artifacts are generated. Surface the detected set in the detection report.

#### Signal 4 — `host_ad_shape` (suggested template shape)

Runs whether or not MaxSDK is present. Determines which of three template shapes `MeticaAdService.cs` should be rendered as, so the generated class slots into the host project's ad-code style without leaving dead unreachable code (e.g. a `MonoBehaviour` `MeticaAdService` in a `static class AdsManager` host that never `GetComponent`s or singleton-fetches it — the component is alive but no host call path reaches it).

For Max-present projects, look at the host's ad-related `.cs` files (the Max-touching inventory from the discovery scan plus any sibling files in the same directory). For Max-absent projects, look at files matching `*Ad*.cs` / `*Ads*.cs` / `*Mediation*.cs` under `Assets/Scripts/`. For each, classify by class shape:

- `monobehaviour` — the class declares `: MonoBehaviour` (directly or transitively).
- `static_class` — the class is declared `static class`.
- `plain_class` — instantiable class, no `MonoBehaviour`, no `static`.

Count by shape; the **majority shape** becomes the suggested default for `MeticaAdService`. Tie-break: `monobehaviour` wins (matches docs.metica.com demo, reachable from any scene). When no ad-related files are found at all (clean project, first integration), default to `monobehaviour`.

Record under `Host ad shape` in the detection report:

```
Host ad shape (majority): static_class (4 of 5 ad files static, 1 monobehaviour)
Suggested MeticaAdService shape: static_class
```

The user confirms or overrides this suggestion in the Step 3 plan (see `SHAPE` collection below).

#### Signal 5 — `cmp_provider`

Runs whether or not MaxSDK is present. Detect whether the host uses a **consent management platform (CMP)** — a runtime consent gate whose result is not known when the shape's auto-init hook (`Start()` under `monobehaviour`) would fire. This **does** change codegen: when a CMP is present the generated init is consent-gated (Step 5 emits `__START_HOOK__` empty for every shape), because auto-initializing MeticaSDK (and the AppLovin/MAX mediation underneath it) with a hardcoded `SetHasUserConsent(true)` before the CMP resolves ships a wrong/empty consent state to the ad networks — a compliance violation. Grep to locate a candidate, then **Read the surrounding lines and confirm it's live code** (not a `//` comment or a `"string literal"`) before setting the provider:

- **`google-ump`** (Google User Messaging Platform) — any of, confirmed live:
  - a `.cs` under `Assets/Scripts/` matching `^using GoogleMobileAds\.Ump` (Grep tool: pattern `^using GoogleMobileAds\.Ump`, glob `Assets/Scripts/**/*.cs`)
  - a real call to `ConsentInformation.Update(` / `ConsentInformation.CanRequestAds(` / `ConsentForm.Load(` / `ConsentForm.LoadAndShowConsentFormIfRequired(`, or a subscribed `OnConsentInfoUpdated` handler
- **`max-cmp`** (AppLovin MAX CMP) — a real call to `MaxCmpService.` (e.g. `MaxCmpService.ShowCmpForIfNeeded(`). Locate via the same `(MaxSdkBase|MaxSdkCallbacks|MaxSdk|MaxCmpService)\.` scan the Max-callsite inventory uses; confirm the `MaxCmpService.` hit is live code.
- **`custom`** — a host-owned consent gate feeding privacy: a method/callback whose result flows into `SetHasUserConsent` / `SetDoNotSell` (or into a "consent resolved" event) that is **not** one of the above. Only classify `custom` when you can cite the consent-resolution callback; when unsure, report `none` and note the ambiguity for the Step 3 plan.
- **`none`** — no CMP above detected. Preserves the shape's default auto-init.

If more than one is present (e.g. both UMP and `MaxCmpService`), report the one that actually gates privacy/init; list the others in the detection report. Record under `CMP provider` in the structured block. This feeds the Step 5 `__START_HOOK__` substitution (empty for all shapes when a CMP is present) and the Step 7 consent-gated-init walkthrough.

#### Secondary checks (inline at generation time)

These do not need a detection-report row; they are applied during codegen:

- **Adapter folder pick** — **if discovery detected a wrapper, place the adapter folder next to it** (`<wrapper's parent dir>/Metica`, e.g. wrapper at `Assets/Scripts/Ads/AdManager.cs` → `Assets/Scripts/Ads/Metica`) so the new files sit beside the code they replace; this takes precedence (it is the "adapter folder next to wrapper" patch pass, Step 5). Otherwise `ls "$PROJECT/Assets/"`: if `Assets/_Project/Scripts/` exists, use `Assets/_Project/Scripts/Metica`; else if `Assets/Game/Scripts/` exists, `Assets/Game/Scripts/Metica`; else default `Assets/Scripts/Metica`.
- **MeticaAdService collision check** — before writing, Grep `$PROJECT/Assets/` (outside `$ADAPTER_FOLDER`) for an existing `class\s+MeticaAdService` definition. If found, rename the generated class (e.g. prepend `Metica` → `MeticaMeticaAdService`, file `MeticaMeticaAdService.cs`) and update the few self-references the integrator writes — the `Start`/`Initialize` wiring and any `gameObject.AddComponent<MeticaAdService>()` call sites in rewritten game code. Everything else (per-format regions, handlers) lives inside that one class, so there are no sibling files to update.

#### Detection report (show to user, then proceed)

Render one block before continuing to Step 3:

```
Detected remote-config provider: firebase (3 of 71 .cs files import Firebase.RemoteConfig)
  Alternatives present: (none)  |  appmetrica (1 import)  |  ...
  → cohort-gating recipe will be included in the final report (Step 7)
Detected dominant namespace: MyGame.Services (38 of 71 .cs files)
Detected CMP: google-ump (UserMessagingPlatform — ConsentForm.LoadAndShowConsentFormIfRequired)
  → init will be consent-gated: no auto-init hook; wire Initialize(bool, bool) from the CMP callback (Step 7)
Resolved adapter folder: Assets/Scripts/Ads/Metica   (next to wrapper AdManager.cs)
Resolved namespace wrap: MyGame.Services.Metica
```

When MaxSDK is absent, omit the provider line. The CMP line always shows (Signal 5 runs whether or not MaxSDK is present); when no CMP is detected show `Detected CMP: none (shape default auto-init preserved)`. When no namespace dominates and the project has no namespaces at all, show `Resolved namespace wrap: (none — emit without wrapper)`. When a wrapper was detected, the adapter-folder line shows the wrapper-adjacent resolution `(next to wrapper <file>)`; otherwise it shows the default pick (`Assets/_Project/Scripts/Metica`, `Assets/Game/Scripts/Metica`, or `Assets/Scripts/Metica`).

Any of these values may be overridden by env vars (`REMOTE_CONFIG_PROVIDER`, `NAMESPACE`, `ADAPTER_FOLDER`, `CMP_PROVIDER`). When an env var is set, show `(overridden by env)` next to the value and skip the corresponding detection. The user may also override during plan-mode review — bake the final values into Step 3's plan content before approval.

### Step 3 — Plan-mode preview (the single audit checkpoint)

This is the **only** gate before any file write. Present the discovery findings + the codegen plan, take one approval, and collect any value that would otherwise fail validation on the first run. Prefer Claude Code's plan mode (`EnterPlanMode`); if it is unavailable (tool absent or errors), present the same content under a `## Plan` heading and require an explicit `yes`/`y` before proceeding.

Structure the preview in **two tiers** so the review-critical inferences can't be skimmed past:

**Tier 1 — one-line summary**, e.g.:

```
Detected: MaxSDK present + wrapper (AdManager.cs), firebase remote-config gate.
Will write 4 files, rewrite 3 call sites.
```

**Tier 2 — "Confirm these inferences"** — list ONLY the fuzzy/inferred decisions, each with its source anchor, because these are the ones that silently produce foreign code if wrong:

```
Confirm these inferences:
  - wrapper        = Assets/Scripts/Ads/AdManager.cs   (public API: ShowInterstitial(string), ShowRewarded(string, Action))
  - namespace      = Game.Ads.Metica                   (AdManager.cs's namespace + .Metica)
  - adapter folder = Assets/Scripts/Ads/Metica/        (next to the wrapper)
  - userId         = <ASK NOW — see below>
  - shape          = static_class                      (suggested from host's ad code; see Step 2.5 Signal 4 — ASK NOW)
  - max mode       = <ASK NOW when MaxSDK is present — see below>
  - CMP            = google-ump → consent-gated init (no auto-init hook; you wire Initialize(bool,bool) from the CMP callback — Step 7)
```

If discovery found **more than one** wrapper candidate, list them here and require the user to pick one — never default silently.

When a CMP was detected (Step 2.5 Signal 5), list it here as a confirmed inference — it changes the generated init flow (deferred, consent-gated for every shape) and adds a manual wiring step, so the user must see it before approval. When the CMP was classified `custom`, name the consent-resolution callback you cited so the user can correct a misclassification. When no CMP was detected, omit the `CMP` line.

**Collect `USER_ID_EXPR` here.** `null`/empty is valid (Metica auto-generates a stable per-device id, and the validator PASSes it), but a real identity source gives correct cross-session attribution — ask for it now, as part of this preview, rather than silently shipping an anonymous default the user didn't choose:

```
userId is currently unset (defaults to null). Metica will auto-generate a stable
per-device id, but a real identity source gives correct cross-session attribution.
Provide the C# expression for the player identity:
  1) SystemInfo.deviceUniqueIdentifier
  2) PlayerProfile.PlayerId
  3) something else (type the expression)
```

Bake the chosen expression into `USER_ID_EXPR` before codegen. (The reactive autofix prompt for this rule remains only as a fallback for hand-rolled code linted outside this flow — see Step 7.)

**Collect `SHAPE` here.** Step 2.5 Signal 4 produced a suggested shape based on the host's existing ad code. The user confirms or overrides — picking the wrong shape ships dead unreachable code (e.g. a `MonoBehaviour` `MeticaAdService` in a `static class AdsManager` host that never has a hook to fetch it):

```
The integrator suggests SHAPE=<suggested_shape> based on the host's ad code
(Step 2.5 Signal 4: <counts>). Pick how MeticaAdService should be generated:

  [a] monobehaviour  — attach to a GameObject; Start() auto-initializes.
                       Reachable from any scene script via FindObjectOfType
                       or a serialized reference. Fits Unity-component-style
                       hosts.
  [b] static_class   — host calls MeticaAdService.Initialize() explicitly
                       from its own bootstrap (e.g., a static AdsManager.Init).
                       Banner/MRec focus-pause/resume becomes a method the
                       host calls from its own OnApplicationFocus.
  [c] plain_class    — host constructs `new MeticaAdService()` and stores it
                       (singleton / DI container / static field), then calls
                       Initialize() on the instance.

Choose [a/b/c] or press Enter to accept the suggestion:
```

Bake the chosen value into `SHAPE` (one of `monobehaviour`, `static_class`, `plain_class`) before codegen — Step 5 reads it to substitute the template tokens (`__CLASS_HEADER__`, `__START_HOOK__`, `__FOCUS_HOOK__`, `__STATIC__`).

**Collect `MAX_MODE` here (only when `HAS_MAX=true`).** The default is full replacement; some teams want the original Max path kept callable so developers opt in or out of Metica without a git revert:

```
MaxSDK is present. Pick how the Max call sites are migrated:

  [a] replace (default) — rewrite each call site to MeticaAdService; the
                          original Max calls are removed (the
                          pre-metica-integration git tag restores them).
  [b] switchable        — same rewrites, but each call site keeps its original
                          Max call as the else-branch behind
                          MeticaAdService.UseMetica (default true), so
                          developers flip between the Metica and Max paths
                          without a revert.

Choose [a/b] or press Enter for replace:
```

Bake the chosen value into `MAX_MODE` before codegen. Skip the question when the `MAX_MODE` env var was passed (show `(overridden by env)` in the inference list) or when this run is an upgrade-migrate of an existing integration (the existing code's structure wins). When switchable is chosen, name the mode in the Tier 1 summary line.

**Tier 3 — the full plan.** Below the summary + inferences, include the complete detail:

- Files to create (full relative paths + brief purpose).
- Files to edit (full relative paths + which lines / what kind of edit). The list **must not include any file under `Assets/MaxSdk/`** and **must not include any dedicated Max-wrapper file** (e.g. `AdManager.cs`) — see the wrapper-scoping rule in Step 5.
- Dependencies to install (SDK version + form factor).
- Hard constraints reflected in this plan: privacy calls (`SetHasUserConsent`, `SetDoNotSell`) precede `MeticaSdk.Initialize` and live in the same file (`MeticaAdService.cs`); init is called exactly once.
- Code blocks for each **net-new** file. The agent generates files directly via Write; the reference shape is the single `scripts/templates/standalone/MeticaAdService.cs.tmpl` (Read at codegen time). Call-site rewrites are shown as one representative before/after per category per file plus a count — not the full inventory (expand on request).
- Rollback path: `git reset --hard pre-metica-integration` (tag created at step 4).

The user may correct any inference here ("no, the wrapper is `AdsService.cs`") → re-discover and re-present. After approval, call `ExitPlanMode` (if used) and continue.

### Checkpoint log (`$PROJECT/.metica-integration.log`)

The run's audit + resume record lives at the **project root**: `$PROJECT/.metica-integration.log` (dot-prefixed, so Unity's importer ignores it; findable before the adapter folder exists). Start writing it immediately **after** the Step 4 tag — never before, so it can't trip the dirty-tree check on a first run — one plain line per entry:

- `DECISION <key>=<value>` — every plan-time decision, batched right after the tag (all are final at Step 3 approval): `HAS_MAX`, `MAX_MODE`, `INTEGRATION_MODE`, `DETECTED_SDK`, `TARGET_SDK`, `WRAPPER`, `SHAPE`, `NAMESPACE`, `ADAPTER_FOLDER`, `USER_ID_EXPR`, `FORMATS`, `CMP_PROVIDER`, `REMOTE_CONFIG_PROVIDER`. **Never log credentials** (`API_KEY` / `APP_ID` / `MAX_SDK_KEY`) — on a resume they are re-read from env vars or already baked into the generated code; the validator's placeholder check backstops a resumed run that still carries placeholders.
- `WROTE <project-relative path>` / `EDITED <project-relative path>` — one line per file the run creates / edits (codegen, rewrites, migrations, autofixes). This list also keys the Step 6.5 `compiles_cleanly` autofix (owned files only).
- `STEP <n> COMPLETE` — at the end of each of Steps 4–6.
- The Step 6.5 autofix action lines (applied or refused).
- `RUN COMPLETE` — the last line, written at the end of Step 7.

The "Setup — resume check" section reads this log to continue an interrupted run.

### Step 4 — Git snapshot

Tag the current state so the user has a one-command rollback. **If the working tree is
dirty, stop** and tell the user to commit or stash first — do **not** auto-commit on their
behalf, and do not tag over uncommitted work:

```bash
if ! git -C "$PROJECT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "$PROJECT is not a git repository. Run 'git init' (or work from inside your repo) so there is a rollback safety net, then re-run." >&2
    exit 1
fi
if [ -n "$(git -C "$PROJECT" status --porcelain | grep -v '\.metica-integration\.log$')" ]; then
    echo "Working tree is dirty. Commit or stash your changes first, then re-run." >&2
    exit 1
fi
git -C "$PROJECT" tag -f pre-metica-integration
echo "Tagged pre-metica-integration — roll back any time with: git reset --hard pre-metica-integration"
```

The repo check fires first so a non-git project gets a clear instruction instead of a
confusing failure from `git tag` later. The dirty check ignores `.metica-integration.log`
(a completed prior run leaves it untracked; it must not abort future runs). Immediately
after tagging, initialize the checkpoint log: write the `DECISION` lines (see "Checkpoint
log" above), then `STEP 4 COMPLETE`. On a resume, this step skips the dirty check and
instead verifies the tag exists (see "Setup — resume check").

### Step 5 — Apply code changes

(Note: MeticaSDK installation is enforced at step 1 by the `metica_sdk` row of the compat-check — if the user hasn't imported the `.unitypackage` yet, compat-check returns BLOCK with a direct download URL and the integrator refuses to proceed. By the time we reach step 5, MeticaSDK is installed in the project — at the target version for a fresh install, or about to be swapped to it when `INTEGRATION_MODE=upgrade` (below).)

#### When `INTEGRATION_MODE=upgrade`: swap the package, then migrate the integration code

Run this **first**, before the codegen/rewrite passes below — and only after the Step 4 snapshot exists (so the swap is recoverable). Two ordered parts:

**(a) Clean-swap the SDK package to the target.** Unity's `-importPackage` overlays files, so removing the old install first prevents orphaned files from a renamed/deleted SDK source. Use the `--clean` flag:

```bash
bash "$PLUGIN_DIR/scripts/download-metica-sdk.sh" --project="$PROJECT" --version="$TARGET_SDK" --clean --import
```

`--clean` removes `Assets/MeticaSdk` (and its `.meta`) before placing and importing the target package. If headless Unity isn't available it falls back to placing the `.unitypackage` and asking the user to import manually (same fallback as the fresh install) — surface that and pause until they confirm the import, since the migration in (b) compiles against the new types.

**(b) Migrate the existing integration code** per `references/metica-sdk-migration.md` (the `<DETECTED_SDK> → <TARGET_SDK>` section is the source of truth for which symbols changed). For each symbol the existing code uses:

- **obsoleted** (e.g. `MeticaSmartFloors.IsSuccess` → `IsForcedHoldout` / `UserGroup`) and **signature-changed** rows → rewrite the call site with an anchor re-check (re-read the file immediately before editing; refuse if it changed on disk — same discipline as the Step 6.5 autofix loop). Edit existing files only; create no net-new files.
- **new-optional** rows (CMP flow, `InitializeAnalytics`, `MeticaAds.RevenueCallbackDelivery`, `LevelPlay`) → **do not auto-apply** to existing hand-rolled code. Collect them as suggestions for the Step 7 report — especially `RevenueCallbackDelivery` (set before `MeticaSdk.Initialize`), the recommended ≥2.4.2 way to keep a fullscreen 3PA revenue forwarder from being lost on app-close-mid-ad; pick the mode per the delivery-mode rule in `references/3pa-forwarders.md`. (Fresh codegen applies it automatically via the `__REVENUE_DELIVERY__` token.)
- **unchanged** / **behavior-changed** rows → no edit; note any behavior change (e.g. idempotent re-init) in the report if it affects the existing code.

Log every migration edit (`EDITED <file>`) to the checkpoint log (`$PROJECT/.metica-integration.log`). If there is **no** existing integration code (upgrade with package-only swap), skip (b) and continue to fresh codegen below. When MaxSDK is present, the Max-callsite rewrite below still applies on top of the migration.

#### When MaxSDK is present: scan + propose Max-callsite refactor

The Max-callsite inventory and the wrapper classification were already produced in **Step 2 (Discovery)** and approved in the Step 3 plan — reuse them rather than re-deriving. The scan below is the **edit-time pass**: it drives the rewrites and re-verifies each file after editing.

Propose rewrites that target the game's single `MeticaAdService` instance directly (no router). Introduce a `MeticaAdService _ads;` field constructed and `Initialize()`-d once in the game's bootstrap; replace each call site with `_ads.ShowInterstitial(…)` etc. **Under `MAX_MODE=replace` (the default), removing Max from the game's call sites is the whole point when MaxSDK is present**; under `MAX_MODE=switchable` the same rewrites keep each original call as the `else` branch behind `MeticaAdService.UseMetica` (see the switchable subsection below). Either way the "do not touch Max usage logic" rule is preserved by the wrapper-scoping rule below.

**Wrapper-scoping rule (critical):** rewrite **only scene/game-logic files** that call `MaxSdk.*` **directly** — MonoBehaviours bound to scene objects, UI/gameplay scripts. **Do not replace a dedicated Max-wrapper file's structure** (e.g. `AdManager.cs` / `MaxHelper.cs`) whose primary purpose is wrapping MaxSDK behind a non-Max API. If a wrapper exists and the game routes through it, **leave the wrapper file untouched** (no structural rewrites, no per-call rewrites, no internal-API-knob substitutions — the file is read-only to the integrator) and rewrite the game's call sites to **bypass** it and call `MeticaAdService` directly. The orphaned wrapper is the game owner's to delete later — the integrator does not own that decision. To classify a hit's containing file, use the **flow-based wrapper test from Step 2 (Discovery)**: if the ad-unit id reaching `MaxSdk.*` comes from a field/const inside the class (its public API is non-Max), it's a **wrapper** — leave its structure untouched; if the public method's own parameter is forwarded straight into Max's ad-unit slot, or the file calls `MaxSdk.*` to drive its own UI/gameplay, it's **scene/game logic** — rewrite. This is a prose judgment the user approved in the Step 3 plan — when unsure, surface the file and ask.

**`MaxSdkUtils.*` is exempt project-wide.** Stateless helper functions (`MaxSdkUtils.GetAdaptiveBannerHeight`, `MaxSdkUtils.IsTablet`, etc.) don't depend on `MaxSdk` being initialised and are mix-safe inside a Metica integration. Never rewritten, never dropped, never flagged.

**Source of truth for rewrites and drops:** `references/max-metica-api-map.tsv`. Each row is `<MaxSdk-pattern>\t<MeticaSdk-replacement>\t<kind>\t<notes>` where `kind` is `rename` (direct swap), `signature-change` (Metica equivalent exists but caller needs adjustment — e.g. `SetBannerBackgroundColor` switches from `UnityEngine.Color` to a hex string), `drop` (no Metica equivalent — remove the call and surface it in Step 7), or `exempt` (`MaxSdkUtils.*`). The validator's `max_api_use_metica` and `max_api_unsupported` rules consume the same file — the integrator and validator stay in lockstep that way. When a `drop` row matches and the user approves, **remove the call** during the rewrite pass; collect the list and surface it in Step 7 under a "Dropped — no Metica equivalent" section so the user can decide whether to lose the feature or keep a Max-only code path. The narrative form of the TSV lives in `references/max-vs-metica-2.4.0-api.md`.

Use the Bash tool with `grep` to locate candidates, then Read each hit's surrounding lines to drop matches inside comments and string literals. The inventory lives in the agent's reasoning.

`ADAPTER_FOLDER` is the adapter folder resolved in Step 2.5 (default `Assets/Scripts/Metica`). Normalize it to a project-relative path (`ADAPTER_REL`): if the user passed an absolute path under `$PROJECT/`, strip that prefix; **reject** any other absolute path, any path containing a `..` segment, or an empty value (do **not** silently use a path outside the project root), and drop a trailing slash.

Scan the game's own `.cs` for direct Max usage: search every `.cs` under `Assets/` and `Packages/` — **excluding** `/MaxSdk/`, `/MeticaSdk/`, the adapter folder (`/$ADAPTER_REL/`), and `/PackageCache/`, `/Library/`, `/Temp/`, `/obj/` — for the regex `(MaxSdkBase|MaxSdkCallbacks|MaxSdk|MaxCmpService)\.`. Use the Grep tool, or a `grep -rnE` equivalent. (This is the same regex and exclusion set as the Step 2 discovery scan, so the two stay in lockstep; `MaxSdkUtils.*` is naturally excluded — no literal `.` follows `MaxSdk` there.)

For each hit, **Read enough surrounding context** to (a) confirm it is live code and not a comment/string match, and (b) assign a **category**:

- **`bootstrap`** — `MaxSdk.SetSdkKey(...)`, `MaxSdk.InitializeSdk()`, `MaxSdk.SetHasUserConsent(...)`, `MaxSdk.SetDoNotSell(...)`. **Propose the bootstrap rewrite below in the SAME file** where the user's Max init lives today (so privacy ordering is enforceable by the validator's `privacy_before_init` rule).
- **`method_call`** — `MaxSdk.LoadInterstitial`, `ShowInterstitial`, `LoadBanner`, `ShowBanner`, `HideBanner`, `DestroyBanner`, `CreateBanner`, `LoadRewardedAd`, `IsRewardedAdReady`, `ShowRewardedAd`, `IsInterstitialReady`. Simple receiver swap (plus the rewarded name remap: `LoadRewardedAd → LoadRewarded`, etc.).
- **`callback_subscription`** — `MaxSdkCallbacks.<Format>.OnAd*Event += handler`. Two-step rewrite: change the event source AND the handler signature (Max handlers take `(string adUnitId, MaxSdkBase.AdInfo info)`; ours takes `(AdEventData ad)`).
- **`other`** — type references like `MaxSdkBase.AdInfo` parameters or local variables. The integrator should leave these alone unless they're inside a callback handler being rewritten.

#### Rewrite patterns

The standalone `MeticaAdService` owns the full lifecycle (callbacks, auto-reload, `IsReady`-guarded show, exp-backoff retry on load failure) internally, across its per-format regions. The game's job shrinks to constructing the orchestrator once and calling `Show<Format>()`.

**Bootstrap (one file, replace the Max bootstrap):**

```csharp
// before:
MaxSdk.SetSdkKey(MaxSdkKey);
MaxSdk.InitializeSdk();
MaxSdkCallbacks.Interstitial.OnAdLoadedEvent += OnInterLoaded;
// ... more callback subscriptions ...

// after (monobehaviour shape, no CMP — auto-init on Start()):
gameObject.AddComponent<MeticaAdService>();  // MeticaAdService is a MonoBehaviour; its Start() initializes the SDK (privacy + MeticaSdk.Initialize)
// Delete the MaxSdkCallbacks.* subscriptions entirely — MeticaAdService's
// per-format regions own those, including auto-reload.

// after (CMP present, any shape — __START_HOOK__ is empty, so init is deferred to the consent callback):
var _ads = gameObject.AddComponent<MeticaAdService>();   // (static_class/plain_class: use the shape's construct pattern from Step 7)
// Do NOT rely on the auto-init hook here — call _ads.Initialize(hasUserConsent, doNotSell) from the
// CMP completion callback, marshalled to the Unity main thread (see the Step 7 shape-tailored wiring).
// If the game's Max bootstrap ran behind a MaxCmpService/UMP gate today, move THIS init into that
// same callback rather than firing it inline.
```

The exact construct/attach line differs by `$SHAPE`; the bootstrap above is the `monobehaviour` illustration. Step 7's shape-tailored wiring block is the source of truth for how the host constructs the class and (when a CMP is present) calls `Initialize(hasUserConsent, doNotSell)` from the consent callback.

**Method calls (receiver swap + casing/name remap per references/max-vs-metica-2.4.0-api.md):**

```csharp
MaxSdk.LoadInterstitial(adUnitId)        →  drop if redundant, else _ads.LoadInterstitial()  (see Critical note)
MaxSdk.IsInterstitialReady(adUnitId)     →  drop — Show() guards internally
MaxSdk.ShowInterstitial(adUnitId, p, c)  →  _ads.ShowInterstitial(p, c)
MaxSdk.LoadRewardedAd(adUnitId)          →  drop if redundant, else _ads.LoadRewarded()  (see Critical note)
MaxSdk.IsRewardedAdReady(adUnitId)       →  drop — Show() guards internally
MaxSdk.ShowRewardedAd(adUnitId, p, c)    →  _ads.ShowRewarded(p, c)
MaxSdk.CreateBanner / LoadBanner / ShowBanner / HideBanner / DestroyBanner → _ads.*Banner
MaxSdk.CreateMRec / LoadMRec / ShowMRec / HideMRec / DestroyMRec           → _ads.*Mrec  // note casing: MRec → Mrec
```

**Critical** (Load — drop vs. preserve, never display): never rewrite `MaxSdk.LoadInterstitial(id)` to `_ads.ShowInterstitial(...)` — that changes behavior (`LoadInterstitial` is a preload with no display; `ShowInterstitial` displays). Beyond that, decide per the Step 2 **per-format behaviour** finding ("when does the ad load?"):

- **Drop** the explicit Load when it is **redundant** with the adapter's own loading — the per-format region auto-loads in the init callback and again on every `OnAdHidden` / `OnAdShowFailed`, so a load that merely keeps an ad warm is dead weight.
- **Preserve** it as `_ads.Load<Format>()` when discovery shows a **deliberate preload point** the game controls (e.g. a load fired at level-start for a known level-end show) — map it to the orchestrator's `Load*` delegator rather than dropping it, so the game's load timing survives the migration.

When in doubt, surface the drop-vs-preserve choice for that call site in the Step 3 plan rather than silently dropping it.

Reuse the game's existing Max ad unit IDs for MeticaAdService's per-format `adUnitId`s (per the migration guide; they pass through unchanged).

**Callback subscriptions:** delete the game's `MaxSdkCallbacks.<Format>.*` subscriptions entirely — MeticaAdService's per-format regions own them. (Under `MAX_MODE=switchable` they **move** into the `!UseMetica` branch instead — see the switchable subsection below.) Keep any game-side reaction (e.g. granting a reward) by either:

1. Subscribing the relevant `MeticaAdsCallbacks.<Format>.*` event in the game (analytics pings, UI state updates).
2. Adding game-side code to the relevant region's named handler in `MeticaAdService` (e.g. `OnRewardedReward`, `OnInterstitialRevenuePaid` — named methods you can extend, not lambdas).

**Load-callback payload fields are analytics-only.** When preserving a game-side reaction to a load callback, carry over logging/analytics/revenue-tracker use of the payload (`revenue`, `adUnitId`, `networkName`) verbatim — but never carry over (or introduce) a **decision** built on those fields: an eCPM show-gate on stored load-callback revenue (the validator FAILs it — `load_callback_fields_unreliable`), an ad-unit-id equality filter (FAILed under `adunit_routing_unreliable`), or a callback-derived `adUnitId` fed back into `Load*` / `Show*` / `Is<Format>Ready` (ADVISORY — pass the configured publisher id instead). On SmartFloors trial those fields are biased/stale/substituted (`references/smartfloors-user-groups.md`), so such a gate misbehaves only for trial users. Surface any such existing gate in the Step 3 plan for the user to decide instead of migrating it.

Event-name table (Max → Metica):

| MaxSdkCallbacks event | MeticaAdsCallbacks event | Handler arg |
|---|---|---|
| `OnAdLoadedEvent` | `MeticaAdsCallbacks.<Format>.OnAdLoadSuccess` | `MeticaAd` |
| `OnAdLoadFailedEvent` | `MeticaAdsCallbacks.<Format>.OnAdLoadFailed` | `MeticaAdError` |
| `OnAdDisplayedEvent` | `MeticaAdsCallbacks.<Format>.OnAdShowSuccess` | `MeticaAd` |
| `OnAdHiddenEvent` | `MeticaAdsCallbacks.<Format>.OnAdHidden` | `MeticaAd` |
| `OnAdClickedEvent` | `MeticaAdsCallbacks.<Format>.OnAdClicked` | `MeticaAd` |
| `OnAdRevenuePaidEvent` | `MeticaAdsCallbacks.<Format>.OnAdRevenuePaid` | `MeticaAd` |
| `OnAdReceivedRewardEvent` (Rewarded only) | `MeticaAdsCallbacks.Rewarded.OnAdRewarded` | `MeticaAd` (no separate Reward struct) |

#### When `MAX_MODE=switchable`: gate every rewrite, delete nothing

The user chose (Step 3) to keep the original Max path callable. Apply the **same rewrites as replace mode**, but gate each one on `MeticaAdService.UseMetica` — the `__MAX_SWITCH__` token emits `public static bool UseMetica = true;` on the generated class (static under every shape, so call sites always reference `MeticaAdService.UseMetica`). The switch is read at bootstrap/call time: tell the user to set it **once at startup** — flipping it mid-session leaves the previously-initialized chain live (a restart applies the new value cleanly).

- **Bootstrap — gate both ways.** Metica-with-MAX-mediation initializes MAX internally, so an ungated Max bootstrap would double-init MAX and double-fire callbacks:

  ```csharp
  if (MeticaAdService.UseMetica) {
      gameObject.AddComponent<MeticaAdService>();   // shape-specific construct/attach, as in replace mode
  } else {
      MaxSdk.SetSdkKey(MaxSdkKey);                  // the original Max bootstrap, verbatim
      MaxSdk.InitializeSdk();
      MaxSdkCallbacks.Interstitial.OnAdLoadedEvent += OnInterLoaded;   // subscriptions MOVE here, not deleted
  }
  ```

  The game's `MaxSdkCallbacks.*` subscriptions **move into the `!UseMetica` branch** instead of being deleted, so game-side reactions (reward grants, analytics) stay wired on the Max chain; the Metica chain gets them via the `MeticaAdsCallbacks` subscriptions / region handlers, exactly as in replace mode.
- **Method calls** — keep the original call verbatim as the `else`: `if (MeticaAdService.UseMetica) { _ads.ShowInterstitial(p); } else { MaxSdk.ShowInterstitial(id, p); }`. For wrapper-routed call sites the `else` keeps the original wrapper call (e.g. `AdManager.ShowInterstitial(...)`) — the wrapper-scoping rule is unchanged, and the generated adapter itself never references `MaxSdk.` (the template stays Metica-pure; the gate lives at the call sites). The preserve-surrounding-logic rule still applies: the gate wraps only the swapped call — frequency caps, cooldowns, and availability guards around it stay verbatim.
- **`drop`-kind rows** — keep the original call in the `else` branch (there is nothing to route to on the Metica side); still list it in the Step 7 "Dropped — no Metica equivalent" section, noting it stays live on the Max path.
- **Redundant `Load*` calls** — the "drop vs. preserve" rule above never fully deletes a call site in this mode: a `MaxSdk.Load*` that replace mode would drop as redundant is instead preserved verbatim as the `else` branch (with an empty/no-op `if` side when the Metica chain needs no game-side load) — the Max chain has no auto-load of its own, so deleting the call would leave `UseMetica=false` with no load trigger at all.
- **Per-file re-scan** — surviving `MaxSdk.*` matches are expected in this mode: instead of expecting zero matches, confirm each survivor sits inside a `!UseMetica`-reachable branch.

#### Refactor workflow

1. Present the callsite inventory to the user grouped by file, with category counts.
2. In plan mode, propose the rewrites file-by-file.
3. On user approval, apply edits using the `Edit` tool. Always edit the original file in place — never create a parallel copy.
4. After every file edit, re-scan **only the file just edited** to confirm the callsite is gone (or recategorize remaining ones):

    ```bash
    grep -nE '(MaxSdkBase|MaxSdkCallbacks|MaxSdk|MaxCmpService)\.' "<edited_file>" || echo "OK: no MaxSdk callsites remain in <edited_file>"
    ```
    If a match remains, Read it to confirm whether it's a live call still needing a rewrite or just a comment/string.
5. If the user declines the refactor, do **not** apply edits — leave the inventory in the final report as a checklist.

**Hard rule:** never edit files under `Assets/MaxSdk/`. The scan excludes them; the rewrite must too.

**Hard rule (preserve surrounding logic):** rewrite **only** the `MaxSdk.*` / `MaxSdkCallbacks.*` call itself — keep the game logic around it verbatim. In particular, never strip a **frequency gate / cooldown / availability guard** wrapping a `Show*` (the "Is there a gate between shows?" finding from Step 2): the orchestrator does not cap frequency, so dropping the guard would change ad cadence. Swap the call, keep the `if`.


**Codegen when MaxSDK is present (agent-driven):** Generate the **standalone** adapter set — the `MeticaAdService` orchestrator + per-format files — and rewrite the game's direct Max call sites to use it. Ask the user for `MAX_SDK_KEY` (their existing AppLovin MAX SDK key) if not provided. Resolve inputs:

```bash
API_KEY="${API_KEY:-YOUR_METICA_API_KEY}"
APP_ID="${APP_ID:-YOUR_METICA_APP_ID}"
MAX_SDK_KEY="${MAX_SDK_KEY:-YOUR_MAX_SDK_KEY}"
USER_ID_EXPR="${USER_ID_EXPR:-null}"          # C# expression; null is valid (Metica auto-generates) — real identity recommended
SHAPE="${SHAPE:?required from Step 3}"        # monobehaviour | static_class | plain_class (suggested by Step 2.5 Signal 4, confirmed in Step 3)
# from Step 2.5:
ADAPTER_FOLDER="<resolved adapter folder>"   # default Assets/Scripts/Metica (relative to $PROJECT)
NAMESPACE="<resolved namespace>"              # dominant + .Metica, else (empty) or MeticaIntegration — never Metica.AbTest
FORMATS="<formats the game actually uses>"   # detected from the Max call sites (Step 5 scan); subset of {banner, interstitial, rewarded, mrec}
CMP_PROVIDER="<resolved cmp provider>"        # google-ump | max-cmp | custom | none (Step 2.5 Signal 5) — empties __START_HOOK__ when ≠ none
```

**Input validation + escaping (inline)** — each key (API_KEY, APP_ID, MAX_SDK_KEY) is embedded as a C# string literal, so validate and escape it before substituting: **reject** an empty value or one containing a control char (newline / CR / tab), then **escape** `\` → `\\` first, then `"` → `\"` (backslash first so the quote-escaping backslashes aren't doubled). If any key is invalid, stop and ask the user — do not write any file. `USER_ID_EXPR` is **not** escaped — it is a C# *expression* embedded verbatim (e.g. `SystemInfo.deviceUniqueIdentifier`), not a string literal.

Then generate:

1. **`MeticaAdService.cs`** — render `$PLUGIN_DIR/scripts/templates/standalone/MeticaAdService.cs.tmpl`. Substitution proceeds in this order:

   **(a) Shape tokens** — based on `$SHAPE` (collected in Step 3):

   | Token | `monobehaviour` | `static_class` | `plain_class` |
   |---|---|---|---|
   | `__CLASS_HEADER__` | `class MeticaAdService : MonoBehaviour` | `static class MeticaAdService` | `class MeticaAdService` |
   | `__START_HOOK__` | `void Start() => Initialize();` | (empty) | (empty) |
   | `__FOCUS_HOOK__` | the canonical `private void OnApplicationFocus(bool hasFocus)` block (with `BannerOnFocus`/`MrecOnFocus` dispatch inside `// @fmt-begin:<fmt>` regions, identical to the pre-tokenisation template) | (empty) | (empty) |
   | `__STATIC__` | (empty) | `static ` | (empty) |
   | `__INTERSTITIAL_LOAD_FAILED_BODY__` | docs-verbatim exp-backoff retry using `MonoBehaviour.Invoke` (see below) | log-only — let SDK retry internally (see below) | log-only — let SDK retry internally (see below) |
   | `__REWARDED_LOAD_FAILED_BODY__` | docs-verbatim exp-backoff retry using `MonoBehaviour.Invoke` (see below) | log-only — let SDK retry internally (see below) | log-only — let SDK retry internally (see below) |

   **CMP override for `__START_HOOK__`:** the `__START_HOOK__` values above are the **no-CMP** defaults. When `CMP_PROVIDER != none` (Step 2.5 Signal 5), substitute `__START_HOOK__` with an **empty** hook for **every** shape (including `monobehaviour` — drop the `void Start() => Initialize();` auto-init), so init is deferred until consent resolves. Emit a one-line comment in its place, e.g. `// No auto-init: CMP (<CMP_PROVIDER>) gates consent — host calls Initialize(hasUserConsent, doNotSell) from the CMP callback (main thread). See Step 7.` The host then calls the consent-gated `Initialize(bool hasUserConsent, bool doNotSell)` overload (already in the template, carrying `__STATIC__`) with the resolved values. Do **not** move privacy or init into the auto-init hook in this case — deferring them until consent resolves is the whole point. Both `Initialize` overloads are emitted regardless of CMP/shape; the parameterless one delegates to the two-arg one, so there is still exactly one `MeticaSdk.Initialize(` call site (`init_count` stays green) and privacy stays same-file before init (`privacy_before_init` stays green). The CMP callback frequently fires **off** the Unity main thread (UMP especially), so the Step 7 wiring marshals the `Initialize(...)` call to the main thread — consistent with the validator's `sdk_calls_on_main_thread` rule.

   For `__FOCUS_HOOK__` under `monobehaviour`, emit verbatim:

   ```csharp
       // Pause/resume the persistent formats with app focus (no-op for the others).
       private void OnApplicationFocus(bool hasFocus)
       {
           // @fmt-begin:banner
           BannerOnFocus(hasFocus);
           // @fmt-end:banner
           // @fmt-begin:mrec
           MrecOnFocus(hasFocus);
           // @fmt-end:mrec
       }
   ```

   Under `static_class` / `plain_class`, substitute an empty string — the host wires its own focus handling and calls `MeticaAdService.BannerOnFocus(...)` / `MeticaAdService.MrecOnFocus(...)` (static) or `_metica.BannerOnFocus(...)` / `_metica.MrecOnFocus(...)` (plain instance) from its own `OnApplicationFocus` handler. The two per-format helpers (`BannerOnFocus`, `MrecOnFocus`) are emitted regardless of shape (declared `public` in the template so non-MonoBehaviour hosts can call them) — only the focus *dispatch* block is shape-dependent.

   For `__INTERSTITIAL_LOAD_FAILED_BODY__` and `__REWARDED_LOAD_FAILED_BODY__`:

   - **Under `monobehaviour`**, emit the docs-verbatim exp-backoff retry (this is the body of today's `OnInterstitialLoadFailed` / `OnRewardedLoadFailed`):

     ```csharp
             _interstitialRetry++;
             double delay = System.Math.Pow(2, System.Math.Min(6, _interstitialRetry));
             Debug.LogWarning($"[Metica] interstitial load failed: {error.message}, retrying in {delay}s");
             Invoke(nameof(LoadInterstitial), (float)delay);
     ```

     Same shape for the rewarded variant — substitute `_rewardedRetry` and `LoadRewarded`.

   - **Under `static_class` / `plain_class`**, emit a log-only body — no app-side retry call:

     ```csharp
             Debug.LogWarning($"[Metica] interstitial load failed: {error.message} — MeticaSDK auto-retry handles re-loading.");
     ```

     Same shape for the rewarded variant — substitute the format name in the log message.

     Under these shapes the `_interstitialRetry` / `_rewardedRetry` field is unused (only written in `OnLoadSuccess`, never read). That's a CS0414 *warning*, not an error — the code still compiles. The retry-counter field stays in the template so the MonoBehaviour shape can reset it; if the user later wants an app-side retry on non-MonoBehaviour shapes, they can add the deferred-call invocation themselves.

   **(b) `@fmt-region` drop** — **after** shape substitution (the MonoBehaviour `__FOCUS_HOOK__` value carries its own `@fmt-begin:banner` / `@fmt-end:banner` / `@fmt-begin:mrec` / `@fmt-end:mrec` markers, which the drop pass needs to evaluate against `$FORMATS`): **drop the `// @fmt-begin:<fmt>`…`// @fmt-end:<fmt>` region for every format NOT in `$FORMATS`**.

   **(c) Existing tokens** — substitute `__METICA_API_KEY__` / `__METICA_APP_ID__` (escaped as above), `__USER_ID__` (verbatim), and `__MEDIATION__` → `new MeticaMediationInfo(MeticaMediationInfo.MeticaMediationType.MAX, "<escaped MAX SDK key>")` (note: `MeticaMediationType` is a **nested** enum inside `MeticaMediationInfo`, so it **must** be qualified as `MeticaMediationInfo.MeticaMediationType.MAX` — the bare `MeticaMediationType.MAX` from the docs page does not compile; the SDK source and the canonical demo are the source of truth when they diverge from the docs).

   **`__MAX_SWITCH__` (the switchable-mode gate)** — when `MAX_MODE=switchable`, substitute `public static bool UseMetica = true;   // false routes every rewritten call site back to its original Max path` (always `static`, regardless of `$SHAPE`, so call sites reference `MeticaAdService.UseMetica` under every shape). Otherwise (`MAX_MODE=replace`, or no MaxSDK) **delete the whole token line**.

   **`__REVENUE_DELIVERY__` (revenue-callback delivery mode)** — the single place the delivery mode is set, filled here at render time (the later "3PA revenue forwarders" pass doesn't touch it). Always fill it when the effective SDK (`$TARGET_SDK`) is **≥ 2.4.2** with `MeticaAds.RevenueCallbackDelivery = CallbackDelivery.<Mode>;` where `<Mode>` is chosen by the delivery-mode rule in `references/3pa-forwarders.md` (the source of truth, including how to detect `MaxSdk.InvokeEventsOnUnityMainThread` and its spellings). Otherwise (`$TARGET_SDK < 2.4.2`, API absent) **delete the whole token line** and recommend upgrading in Step 7. `MeticaAds` / `CallbackDelivery` resolve under the existing `using Metica.Ads;`.

   **(d) Compile guarantee** — every shape compiles out of the box. The two retry bodies above are the only place `MonoBehaviour`-specific API (`Invoke(string, float)`) shows up, and the `__INTERSTITIAL_LOAD_FAILED_BODY__` / `__REWARDED_LOAD_FAILED_BODY__` substitution keeps `Invoke` strictly inside the `monobehaviour` branch. When `__REVENUE_DELIVERY__` is filled, its `MeticaAds` / `CallbackDelivery` symbols resolve under the already-imported `using Metica.Ads;` (no new `using`), and the API exists because the `__REVENUE_DELIVERY__` rule only fills it on `$TARGET_SDK ≥ 2.4.2`. Under `static_class` / `plain_class`, the SDK's built-in load-failure retry handles re-loading; the Step 7 walkthrough explains how to wire an app-side retry from the host's main loop if the team wants an additional safety net.

   The result is a single class that sets privacy + `MeticaSdk.SetLogEnabled(true)` (both **before** `MeticaSdk.Initialize`, same file) and calls `MeticaSdk.Initialize(config, <mediation>, OnInitialized)` with the **named `OnInitialized` method** (not a lambda) that logs `SmartFloors` and wires up each used format; it exposes `LoadInterstitial`/`ShowInterstitial`, `LoadRewarded`/`ShowRewarded`, `ShowBanner`/`HideBanner`, `ShowMrec`/`HideMrec` — these (and `Initialize` — same for the `InitializeAsync` form, where an `await` before the call can also move execution off-main) must be **called on the Unity main thread** (the SDK captures the `SynchronizationContext` at the call site); when rewriting call sites that fire from a CMP/consent or other off-main callback, marshal them to the main thread. Reuse the **game's existing Max ad unit IDs** for the format `adUnitId`s (per the migration guide they pass through unchanged). **File layout:** by default write one `$ADAPTER_FOLDER/MeticaAdService.cs`; for a larger project you may split each `@fmt` region into a `$ADAPTER_FOLDER/MeticaAdService.<Format>.cs` `partial class MeticaAdService` to match the game's conventions (the validator is content-based and passes either way).

2. **Rewrite the game's Max call sites** to use the `MeticaAdService` instance directly — see the "Rewrite patterns" subsection above and obey the wrapper-scoping rule. Delete the game's `MaxSdkCallbacks.*` subscriptions (MeticaAdService's per-format regions own them); under `MAX_MODE=switchable`, gate each rewrite and move the subscriptions into the `!UseMetica` branch instead (see the switchable subsection).

#### Post-template patch passes (conform codegen to the host)

After rendering the templates, apply a small, fixed set of **deterministic, named patch passes** parameterised by the Step 2 discovery findings. Each takes a file + a discovery field and produces one edit; they are **agent-applied** (the `Edit` tool). They are validated *indirectly*: the conformed output must still PASS the validator, so a botched patch surfaces as a validator FAIL. Apply only the passes whose trigger fired in discovery; skip the rest (a no-Max project fires none — there is no wrapper or observed placement to conform to). The templates' structural shape never changes — these only **add** host-conforming lines (per the directive "don't change the structure of the placeholder files, just add logic").

| Pass | Trigger (from discovery) | Edit |
|---|---|---|
| **Mirror wrapper API** | a wrapper was detected | **Adjust** the orchestrator's `Show<Format>()` delegator to match the wrapper's public signature — keep **one** delegator per format, never a duplicate overload. The delegator already takes optional `placement`/`customData`; rename params or reorder to match the wrapper (e.g. wrapper `ShowInterstitial(string placement)` ↔ the existing `ShowInterstitial(string placement = null, …)`). A **delegate/`Action` param** (e.g. `onReward` on `ShowRewarded(string placement, Action onReward)`) cannot be threaded through the fire-and-forget `ShowRewarded` — wire it into the rewarded region's `OnRewardedReward` handler instead; if the mapping isn't a clean 1:1, **surface it in the Step 3 plan for the user to confirm, never silently drop it**. The game's existing call sites keep compiling against the same surface. |
| **Default placement** | placement strings observed | Where the delegator would otherwise pass `null`, pass the **most-frequent observed placement** (from the Step 2 placement counts; ties broken by first-seen) instead — e.g. `_interstitial?.Show("level_complete")`. The per-format `Show(string placement = null, …)` already accepts it — no template change. |
| **Adapter folder next to wrapper** | a wrapper was detected | Place the adapter folder in the **user-confirmed** wrapper's parent directory — resolved in Step 2.5's adapter-folder pick — so the new files sit beside the code they replace. (A write-location decision, not a content edit; listed here for completeness.) |
| **Rename orchestrator next to a neutral wrapper** | wrapper detected whose class name does **not** already start with `Metica` (e.g. `AdsManager`, `AdManager`, `AdService`) | Cosmetic: rename the orchestrator to `Metica<WrapperName>` (e.g. `AdsManager` → `MeticaAdsManager`) and update every reference in the generated files so it reads as a sibling. **Before renaming, grep the project for an existing `class <Target>`** (same check as the Step 2.5 collision-rename); if the target name is already taken, **skip the cosmetic rename and keep `MeticaAdService`**. Runs after the Step 2.5 collision-rename; if both would fire, the collision rename wins. |
| **3PA revenue forwarders** | a 3PA provider detected (Step 2.5 Signal 3) | Populate each used format's named `On<Format>RevenuePaid` handler with the matching forwarder call, **one per detected provider**. **Prefer relocating the game's own existing forwarder calls** (found during the Max-callsite scan / callback-subscription rewrite) — they are already version-correct for the game's installed 3PA SDK versions — into the handler; only fall back to a fresh call (canonical shapes in `references/3pa-forwarders.md`) when the game had none. Under `MAX_MODE=switchable`, **copy** the existing forwarder call instead of relocating it — the original stays in its `MaxSdkCallbacks` subscription inside the `!UseMetica` branch, so analytics keep firing on the Max chain. Forward from `OnAdRevenuePaid` **only** — never `OnAdHidden` or a dismissal hook (that loses click-through revenue; the validator FAILs it). No App-Open handler (App Open is `drop` per the TSV). The matched `MeticaAds.RevenueCallbackDelivery` for these forwarders is set once via the `__REVENUE_DELIVERY__` token at render time (its own render rule above), **not** in this pass. |
| **Banner/MRec setter ordering** | `SetBanner*` / `SetMrec*` calls migrated from the game (or generated) | Emit setters **after** the matching `Create*` call, never before — a setter on a not-yet-created `adUnitId` silently no-ops (including a custom banner refresh rate, `SetBannerExtraParameter(adUnitId, "ad_refresh_seconds", …)`, which must follow `CreateBanner` or the refresh rate is dropped). Order is: subscribe callbacks → `CreateBanner`/`CreateMrec` → `SetBanner*`/`SetMrec*` → `ShowBanner`/`ShowMrec`. On **SDK ≥ 2.4.2 (Android)** banner/MRec creation and display are separate steps, so a `Show` must follow a `Create` for the same id — never collapse them or emit a show before the create (the template's `Init<Format>` does `Create` → `Show`; the SDK loads/auto-refreshes, so an explicit `Load*` is only for manual refresh). For interstitial/rewarded `SetInterstitial*` / `SetRewardedAd*`, re-apply after each load (pre-creation calls are dropped per the TSV). Keeps the validator's `*_setter_after_create` rules green. |

Each pass is idempotent and inspectable: re-running discovery + codegen on the same project produces the same edits. Record each applied pass in the Step 7 report so the user can see how the output was conformed to their project.

When any 3PA forwarder is generated, also report the revenue-callback delivery outcome in Step 7. On **SDK ≥ 2.4.2** codegen has already applied `MeticaAds.RevenueCallbackDelivery` (the `__REVENUE_DELIVERY__` token) before `MeticaSdk.Initialize`, matched to the game's MAX threading per `references/3pa-forwarders.md`; report the value applied and, under `NativeThread`, the reminder to keep handler code thread-safe. On **`$TARGET_SDK` < 2.4.2** the token line was omitted (API absent) — recommend upgrading. Example line (MAX native-default): *"3PA forwarders (Adjust / Firebase / AppMetrica / AppsFlyer) wired inside `OnAdRevenuePaid`. Applied `MeticaAds.RevenueCallbackDelivery = CallbackDelivery.NativeThread` before `MeticaSdk.Initialize` (matches your MaxSDK native-thread callbacks; keeps fullscreen revenue from being lost on app-close-mid-ad — the handler runs off the Unity main thread, so keep any code you add to it thread-safe)."*

```bash
mkdir -p "$PROJECT/$ADAPTER_FOLDER"
ls -la "$PROJECT/$ADAPTER_FOLDER"
echo "Generated MeticaAdService.cs in $ADAPTER_FOLDER (formats: $FORMATS)"
[ "$REMOTE_CONFIG_PROVIDER" != "none" ] && \
  echo "Remote-config provider detected: $REMOTE_CONFIG_PROVIDER — cohort-gating recipe included in Step 7 report"
```

**Codegen when MaxSDK is absent (agent-driven):** Ask the user which ad formats they need (banner / interstitial / rewarded / mrec; default `interstitial` if they don't specify). This uses the **same standalone per-format split** as the Max-present path — only the bootstrap differs (a no-Max project adds a thin entry-point MonoBehaviour, with no game code to rewrite) and the mediation argument is `null`. Resolve inputs:

```bash
API_KEY="${API_KEY:-YOUR_METICA_API_KEY}"
APP_ID="${APP_ID:-YOUR_METICA_APP_ID}"
USER_ID_EXPR="${USER_ID_EXPR:-null}"          # null is valid (Metica auto-generates) — real identity recommended
SHAPE="${SHAPE:?required from Step 3}"        # monobehaviour | static_class | plain_class (collected via the Step 3 prompt, suggested by Step 2.5 Signal 4)
FORMATS="${FORMATS:-interstitial}"
NAMESPACE="<resolved namespace>"              # see "Resolved namespace rule" below
ADAPTER_FOLDER="${ADAPTER_FOLDER:-Assets/Scripts/Metica}"
CMP_PROVIDER="<resolved cmp provider>"        # google-ump | max-cmp | custom | none (Step 2.5 Signal 5) — empties __START_HOOK__ when ≠ none
```

**Input validation + escaping (inline)** — validate and escape every key the agent embeds, exactly as in the Max-present path: reject an empty value or a control char (newline / CR / tab); escape `\` → `\\` first, then `"` → `\"`. Stop and ask the user on any failure; do not write any file.

**Resolved namespace rule** (applies whether or not MaxSDK is present, per Step 2.5):

- Dominant namespace detected (`MyGame.Services` etc.) → use `<dom>.Metica` (e.g. `MyGame.Services.Metica`).
- No `namespace` declarations anywhere under `Assets/Scripts/` → **emit files without any `namespace` wrapper** (strip both the `namespace Metica.AbTest {` opener and the `} // namespace Metica.AbTest` closer in every template).
- Namespaces exist but none dominate → use `MeticaIntegration`.
- User passed `NAMESPACE` env var explicitly → use it verbatim (do not append `.Metica`); empty string = no wrapper.
- **Never** emit `namespace Metica.AbTest` — that label is reserved for the plugin templates' placeholder, not for the user's generated code.

**Other input checks** the agent enforces inline (no helper):

- `FORMATS` parses to a non-empty subset of `{banner, interstitial, rewarded, mrec}` after whitespace-trimming each token. Reject unknown tokens.
- If any target file already exists, do not overwrite. Tell the user to remove it or pass an explicit "force" instruction.

**File to generate** (under `$ADAPTER_FOLDER`):

1. **`MeticaAdService.cs`** — render `$PLUGIN_DIR/scripts/templates/standalone/MeticaAdService.cs.tmpl`: apply the namespace transform (rule above), substitute the **shape tokens** per `$SHAPE` (same per-shape table as the Max-present codegen above — `__CLASS_HEADER__` / `__START_HOOK__` / `__FOCUS_HOOK__` / `__STATIC__` / `__INTERSTITIAL_LOAD_FAILED_BODY__` / `__REWARDED_LOAD_FAILED_BODY__`, **including the CMP override that empties `__START_HOOK__` for every shape when `CMP_PROVIDER != none`**), then **drop the `// @fmt-begin:<fmt>`…`// @fmt-end:<fmt>` region for every format NOT in `$FORMATS`** (after shape substitution, since the MonoBehaviour `__FOCUS_HOOK__` value carries its own `@fmt` markers), substitute `<API_KEY_ESCAPED>` / `<APP_ID_ESCAPED>` (escaped as above) and `<USER_ID_EXPR>` (verbatim), substitute `__REVENUE_DELIVERY__` per its render rule above (no MaxSDK → `CallbackDelivery.NativeThread` when `$TARGET_SDK ≥ 2.4.2`, else delete the token line), delete the `__MAX_SWITCH__` token line (no MaxSDK — nothing to switch to), and — with no MaxSDK present — set the mediation arg to `null`. Every shape compiles out of the box (the `Invoke(...)` retry call is scoped strictly to the `monobehaviour` branch via the `__INTERSTITIAL_LOAD_FAILED_BODY__` / `__REWARDED_LOAD_FAILED_BODY__` substitution). The result mirrors the docs.metica.com example under `monobehaviour`: with no CMP, `Start()` auto-inits by calling an idempotent `Initialize()` that delegates to `Initialize(true, false)`; with a CMP, `__START_HOOK__` is empty and the host calls `Initialize(bool hasUserConsent, bool doNotSell)` from its consent callback. Either way the consent-gated overload sets privacy + `MeticaSdk.SetLogEnabled(true)` (**before** `MeticaSdk.Initialize`, same file) and runs `MeticaSdk.Initialize(config, null, OnInitialized)` with a **named `OnInitialized(MeticaInitResponse)` method (not a lambda)** that logs `SmartFloors` group / forced-holdout / userId and wires up each used format's region (subscribe callbacks + initial load). It exposes game-facing delegators per format: `LoadInterstitial()`/`ShowInterstitial(placement, customData)`, `LoadRewarded()`/`ShowRewarded(...)`, `ShowBanner()`/`HideBanner()`, `ShowMrec()`/`HideMrec()`. Per-format retry/refresh shape: interstitial + rewarded carry `IsReady`-guarded `Show`, auto-reload on `OnAdHidden`, and `OnAdShowFailed`-recovery; under **`monobehaviour`** they additionally carry docs-verbatim exponential-backoff retry on `OnAdLoadFailed` (`Math.Pow(2, Math.Min(6, attempt))`), while under **`static_class` / `plain_class`** the load-failure handlers are log-only and MeticaSDK's built-in retry handles re-loading (Step 7's walkthrough shows how to add an app-side retry from a host scheduler if desired). Banner + MRec carry `OnApplicationFocus` pause/resume + an `_…Showing` flag under `monobehaviour`, and no app-side focus dispatch under `static_class` / `plain_class` (the host wires its own focus handler and calls `MeticaAdService.BannerOnFocus(...)` / `MrecOnFocus(...)`, both `public` for that purpose); no app-side retry under any shape. Reference shape (the actual template lives at `scripts/templates/standalone/MeticaAdService.cs.tmpl`):

   ```csharp
   namespace <NAMESPACE> {                         // omit wrapper per the namespace rule
   public class MeticaAdService : MonoBehaviour
   {
       private bool _initialized = false;
       __START_HOOK__                               // `void Start() => Initialize();` (monobehaviour, no CMP); empty for other shapes or when a CMP is present
       public void Initialize() => Initialize(true, false);   // idempotent; uses configured privacy defaults
       // Consent-gated entry — host calls this from its CMP callback (main thread) when a CMP is present:
       public void Initialize(bool hasUserConsent, bool doNotSell)
       {
           if (_initialized) return; _initialized = true;
           MeticaSdk.Ads.SetHasUserConsent(hasUserConsent);  // privacy precedes Initialize, same file
           MeticaSdk.Ads.SetDoNotSell(doNotSell);
           MeticaSdk.SetLogEnabled(true);
           var config = new MeticaInitConfig("<API_KEY_ESCAPED>", "<APP_ID_ESCAPED>", <USER_ID_EXPR>);
           MeticaSdk.Initialize(config, null, OnInitialized);   // named callback, not a lambda; the one init call site
       }
       private void OnInitialized(MeticaInitResponse response)
       {
           Debug.Log($"[Metica] user group: {response.SmartFloors.UserGroup}, userId: {response.UserId}");
           InitInterstitial("interstitial_main");   // one Init<Format>() per region in $FORMATS
       }
       // One // @fmt region per format: state fields + Init<Format>() (subscribe + initial load;
       // banner/MRec: subscribe + Create + Show) + Load/Show[/Hide] delegators + named handlers.
       // Unused regions are dropped.
       public void LoadInterstitial() => MeticaSdk.Ads.LoadInterstitial(_interstitialAdUnitId);
       public void ShowInterstitial(string placement = null, string customData = null) { /* IsReady-guarded */ }
   }
   }
   ```

   **File layout:** by default write one `$ADAPTER_FOLDER/MeticaAdService.cs`. For a larger project you may split each `@fmt` region into a `$ADAPTER_FOLDER/MeticaAdService.<Format>.cs` `partial class MeticaAdService` to fit the game's conventions — the validator is content-based and passes either way. There is **no separate bootstrap file**: attach `MeticaAdService` to a GameObject in the first scene. With no CMP, `Start()` initializes it (or call `Initialize()` yourself after, e.g., login — it's idempotent). With a CMP, `__START_HOOK__` is empty and the host calls `Initialize(hasUserConsent, doNotSell)` from its consent callback (on the Unity main thread) — see the Step 7 shape-tailored wiring / CMP walkthrough.

**Hard correctness invariants** (validator-enforced):

- Exactly one `MeticaSdk.Initialize(` call site (in `MeticaAdService`).
- `SetHasUserConsent` and `SetDoNotSell` appear **before** `MeticaSdk.Initialize` in source order in the same file.
- For each used format: `OnAdLoadSuccess` + `OnAdLoadFailed` subscribed; rewarded also subscribes `OnAdRewarded`; interstitial/rewarded subscribe `OnAdHidden` (auto-reload) + `OnAdShowFailed`; every `Load*` has a matching `Show*`.

After writing, `mkdir -p "$PROJECT/$ADAPTER_FOLDER"`, confirm with `ls -la`, and print `Generated MeticaAdService (formats: $FORMATS)`.

Gradle / manifest edits scoped to MeticaSDK additions only are also TODO; Unity-side `.unitypackage` import handles most of it.

### Step 6 — Validator (fresh subagent context, always)

Invoke `@agent-unity-validator` with the project path (a fresh subagent context — never
share your reasoning with it). When this run used `MAX_MODE=switchable`, state that in the
Task prompt as context — the validator verifies the `UseMetica` gate by reading the code,
never from the hint alone. The validator reasons over the code and returns one `validator`
JSON block.

Extract the JSON and read `.status`. Do not echo the JSON verbatim — summarize per the output-economy rules (PASS count in one line; detail only the FAIL/WARN/ADVISORY rows with their evidence). The validator enforces credential hygiene (placeholder keys + test userIds) directly — Step 7's report mirrors what it found rather than running its own grep. On `status: PASS` (ADVISORY/WARN rows do not affect status) → go straight to Step 7. On `status: FAIL` → run the autofix loop (Step 6.5) **before** any rollback hint.

### Step 6.5 — Validate + autofix loop (integrator-owned)

The **validator stays read-only**: it lints and emits its `validator` JSON, nothing else — it never edits and never prompts. The **integrator owns the entire loop**: read the validator's `FAIL` rows, classify each, fix it, re-validate, and fall back to the rollback hint only when it cannot make progress. Every `FAIL` check gates `status` — classify and act on all of them.

Run the loop on `status: FAIL`, **max 3 iterations**:

1. Classify each `level: FAIL` check by `rule` and act:

| Rule | Class | Action |
|---|---|---|
| `privacy_before_init` | autofix | Reorder the offending file so both privacy calls precede `MeticaSdk.Initialize`. |
| `<fmt>_callbacks_subscribed` | autofix | Append the missing `OnAdLoadSuccess` / `OnAdLoadFailed` subscription to the format's region in `MeticaAdService`. |
| `rewarded_reward_callback` | autofix | Append the `OnAdRewarded` subscription. |
| `<fmt>_reload_on_hidden` | autofix | Append `OnAdHidden += ad => Load<Fmt>();`. |
| `<fmt>_show_failed_subscribed` | autofix | Append `OnAdShowFailed += (ad, err) => Load<Fmt>();`. |
| `placeholder_ids_replaced` | prompt | Ask for the real key; substitute in source. |
| `user_id_not_test_value` | prompt | A hardcoded test literal (`"test"` / `"debug"` / digits-only …) was passed as the userId — ask for the real expression. (`null`/empty is valid — Metica auto-generates.) For the integrator's own output the value was collected at plan time (Step 3). |
| `init_count` (count > 1) | surface | Cannot infer which duplicate `MeticaSdk.Initialize` to delete — surface `file:line` and stop. |
| `init_count` (count 0) | surface | The adapter's `Initialize` is missing — a codegen bug, not a user fix (surfaced with no location). |
| `<fmt>_load_show_parity` | surface | Cannot infer the missing call site — surface `file:line`. |
| `compiles_cleanly` | autofix \| surface | A real Unity compile error (`CS####`), one row per error. **autofix** when the cited file is one this run created or edited (per the checkpoint log's `WROTE`/`EDITED` lines): Read the error site and surrounding code, apply a minimal fix with the standard anchor re-check, and fix every owned-file error in the iteration — the re-validate re-runs the Unity compile, so a wrong fix is caught within the 3-iteration cap. **surface** when the cited file was not touched by this run: print the `file:line` + the `CS####: message` from the check's `detail` verbatim. |
| `banner_setter_after_create` / `mrec_setter_after_create` | autofix \| surface | If the setter and its `Create*` sit in the **same method**, reorder so `Create*` precedes the setter (autofix). If they're in different methods / call paths, surface the setter `file:line` + the `Create*` it must follow and stop — cross-method reordering isn't a safe line edit. The integrator's own setter-ordering patch pass keeps generated code green, so a FAIL is hand-rolled. |
| `threepa_forwarder_in_revenue_paid` | surface | A 3PA revenue forwarder wired outside `OnAdRevenuePaid` (e.g. in `OnAdHidden`) loses click-through revenue; under `CallbackDelivery.NativeThread`, a forwarder wrapped in a main-thread dispatcher (or a handler whose call chain touches a Unity-main-thread-only API) loses it on app-death-mid-ad. Restructuring an analytics handler is game logic, not a line edit — surface the forwarder `file:line` + its enclosing handler (and the dispatcher wrap / Unity-API call when that's the finding), and stop. |
| `adunit_routing_unreliable` | surface | A guard routes on a returned `ad.adUnitId ==/!= <configured>` to gate an ad-control decision or drop callback processing (an early return that skips revenue/reward/lifecycle handling on id mismatch — a MAX idiom) — unreliable under SmartFloors (trial serves dedicated units; a holdout unit can appear as a fallback). Removing the id-based branch and attributing by group is a **redesign**, not a line edit; the integrator's own codegen never emits this (it passes the configured id through and only logs the group), so a FAIL means hand-rolled code. Surface the cited comparison (`file:line`) → the branch it gates, and stop. |
| `load_callback_fields_unreliable` | surface | A load-callback payload field (`revenue` / `adUnitId` / `networkName`) gates showing or loading (e.g. an eCPM threshold on stored load-callback revenue) — on SmartFloors trial those fields are biased/stale/substituted (`references/smartfloors-user-groups.md`), so the gate suppresses ads only for trial users. Removing the gate is game-logic redesign, not a line edit; the integrator's own codegen only logs payload fields, so a FAIL is hand-rolled or carried over from a MAX integration. Surface the callback store site (`file:line`) → the gate it feeds, and stop. |
| `smartfloors_group_branch_complete` | surface | A SmartFloors group branch leaves a group with no ad-load path (e.g. only holdout loads, trial is starved). Which group runs which ad strategy is game logic, not a line edit — the integrator's codegen never emits a group-gated load, so a FAIL is hand-rolled. Surface the group read (`file:line`) → the starved branch and stop. |
| `interstitial_setter_after_create` / `rewarded_setter_after_create` | autofix \| surface | Same as the banner/MRec setter rule: reorder when setter + `Create*`/load are in one method, else surface. |
| `callbacks_fire_on_every_path` | surface | A parked/stale callback is a control-flow bug, not a line edit — surface the store site + the path with no invocation and stop. |
| `init_callback_all_paths` | surface | An init path that skips `OnInitialized` (early-return / empty-config) is a logic fix — surface the path and stop. The integrator's own codegen always invokes the callback, so a FAIL is hand-rolled. |
| `init_gated_on_cmp` | surface | A CMP is present but `MeticaSdk.Initialize` runs before consent resolves — deferring init to the CMP completion callback is a control-flow fix, not a line edit. Surface the CMP call site + the un-gated `Initialize`, and stop. The integrator's own codegen emits an empty `__START_HOOK__` when a CMP is detected, so a FAIL is hand-rolled or a mis-wired host callback. |
| `retry_ownership` | surface | Auto-retry disabled with no client retry path — surface the `disable_auto_retries` site and the missing retry, and stop. |
| `sdk_calls_on_main_thread` | surface | An ad call issued off the Unity main thread (e.g. from a CMP/consent callback) needs marshaling to the main thread — a control-flow fix, not a line edit. Surface the off-main call site and stop. The integrator's own codegen drives all ad calls from `MonoBehaviour` lifecycle / main-thread paths, so a FAIL is hand-rolled. |
| `init_reentry_guarded` | autofix | The init/subscription path can re-run at runtime with no re-entry guard, double-subscribing every handler. Add the template's idempotency guard to the init method: declare a `private bool _initialized;` field and insert `if (_initialized) return; _initialized = true;` at the top of the method containing the `MeticaAdsCallbacks.* +=` subscriptions (anchor re-check as usual). |

`*_show_ready_guard`, `*_show_after_init`, `*_load_after_init`, `load_dedup_flag_wedge`, `format_path_symmetry`, `dead_code_signal`, `metica_deprecated_api`, and `revenue_callback_subscribed` are `ADVISORY`, and `compiles_cleanly` is `WARN` when the compile is skipped (no Unity located / `METICA_SKIP_COMPILE=1`) or could not complete — none of these are `FAIL`, so they take no action and never affect status.

`metica_deprecated_api` (leftover use of an obsoleted/signature-changed Metica symbol after an upgrade) is advisory because obsolete symbols still compile. During an upgrade the integrator already migrates these in **Step 5(b)** — autofix direct renames (e.g. `IsSuccess` → `IsForcedHoldout`), surface semantic signature changes. A `metica_deprecated_api` ADVISORY still present after the loop is a symbol the migration deliberately left (a signature change needing judgment, or out of the upgrade's scope) — clean up a direct rename in place with an anchor re-check, otherwise surface it in Step 7 with the replacement from the migration map.

2. **Anchor re-check before every autofix edit:** re-read the target file and confirm the line the validator reported still matches. On mismatch (file changed on disk / open in an editor), **do not retry the write** — surface the suggested patch + `file:line` for manual application and log the refusal. Surface, never retry.

3. **No autofix produces a net-new file** — autofixes only edit existing files. A missing file (e.g. `init_count` count 0) is always `surface`, never `autofix`.

4. **Log every action** (applied or refused) to the checkpoint log (`$PROJECT/.metica-integration.log`), one line each, so the user can audit the loop afterward.

5. Re-invoke `@agent-unity-validator` (fresh subagent context) and repeat. **Stop and fall back to the Step 7 rollback hint** when any `surface`-class FAIL remains, or after 3 iterations still produce FAILs (prevents an infinite loop if a fix introduces a new failure).

Prompt-class fixes pause the run and ask; they never silently substitute.

### Step 7 — Final report

When the autofix loop **cleared all FAILs** (validator now PASS), report normally (below) and note any autofixes applied (read from `.metica-integration.log`).

When the loop **gave up** — a `surface`-class FAIL remained, or 3 iterations were exhausted — lead with the rollback command **as a hint** (state which of the two reasons applied). The integrator **never runs `git reset --hard` itself**; it only prints the command for the user to run:

```
VALIDATION FAILED (<surface-class issues remain | autofix exhausted 3 iterations>). Rollback (run this yourself if you want to revert):
    git reset --hard pre-metica-integration

Unresolved:
- <rule>: <detail>  (<file>:<line>)
- ...

Autofixes applied this run (see .metica-integration.log):
- <rule>: <what was changed>
```

Then the standard summary (whether MaxSDK was present, SDK version, files changed, compat-checker one-liner, validator one-liner).

#### SDK upgrade (when `INTEGRATION_MODE=upgrade`)

Lead the summary with the upgrade outcome:

```
Upgraded MeticaSDK <DETECTED_SDK> → <TARGET_SDK>.
  Package: clean-swapped and imported (or: placed in Assets/ — import in Unity, then re-run validation).
  Code migrations applied (see .metica-integration.log):
  - <file>:<line>  MeticaSmartFloors.IsSuccess → IsForcedHoldout
  Resolved by this upgrade:
  - MET-11632 (IL2CPP + managed stripping → forced HOLDOUT) is fixed at ≥2.4.2; the
    compat-checker managed_stripping WARN no longer applies.
  New capabilities available (adopt if you want them — applied automatically only when this upgrade
  regenerates MeticaAdService via fresh codegen; a suggestion when migrating existing code in place):
  - MeticaAds.RevenueCallbackDelivery (set before Initialize) — keeps fullscreen revenue + any 3PA
    forwarder from being lost on app-close-mid-ad; pick the mode per the delivery-mode rule in
    references/3pa-forwarders.md (matched to the game's MAX threading).
  - CMP terms flow (4-arg Initialize + MeticaCmpFlowSettings); InitializeAnalytics (analytics-only).
```

Pull the migrated symbols and the available-capabilities list from the `<DETECTED_SDK> → <TARGET_SDK>` section of `references/metica-sdk-migration.md`; omit any sub-list that's empty for this project.

#### Dropped MaxSDK calls (no Metica equivalent)

When Step 5 removed `MaxSdk.*` calls that have **no** Metica equivalent (rows in `references/max-metica-api-map.tsv` with `kind=drop` — App Open Ads, `MaxSdk.GetBannerLayout`, `MaxSdk.SetSegmentCollection`, the various debugger / segmentation entries, the unsupported expanded/collapsed callbacks, etc.), surface them so the user sees what was lost:

```
Dropped (no MeticaSdk equivalent in <target_sdk>):
- <file>:<line>  MaxSdk.LoadAppOpenAd("appopen_main")
    → App Open Ads not supported. Either remove the feature or keep
      a separate Max-only init path for it.
- <file>:<line>  MaxSdk.SetSegmentCollection(segs)
    → MaxSegmentCollection has no Metica equivalent. Targeting via MAX
      segments has no MeticaSdk equivalent; consider using MeticaSdk's
      SmartConfig or Events for similar dynamic behaviour.
- ...
```

The list is harvested as the rewrite pass runs — each `drop`-class match emits a removed line plus the row's `notes` column as the explanation.

#### Wiring `MeticaAdService` into your project (shape-tailored)

Render exactly one of the three blocks below, picked by `$SHAPE`. This is the first thing the user needs after codegen — how to construct/attach the generated class and call `Initialize()` from their bootstrap. The two paths that the integrator can't take on the user's behalf (manual MonoBehaviour attach in the Unity Editor, or wiring a static/plain class into the host's existing static bootstrap) are explicit here, not implied.

**When `SHAPE=monobehaviour`** (the default):

```
Open your bootstrap scene (the first scene Unity loads — the scene
at index 0 in File → Build Settings → Scenes In Build; usually your
Bootstrap / MainMenu scene).
  1. Create an empty GameObject named `MeticaAds`.
  2. Add the MeticaAdService component to it (the file just generated
     at <ADAPTER_FOLDER>/MeticaAdService.cs).
  3. (Optional) Mark DontDestroyOnLoad if you reload scenes — but
     Initialize() is idempotent, so re-Start() in a new scene also works.

That's the entire wiring. Start() calls Initialize() automatically.
```

**When `SHAPE=static_class`:**

```
MeticaAdService is a static class — call Initialize() once from your
bootstrap. For example, from your existing static ad-manager:

  public static class AdsManager
  {
      public static void Init()
      {
          // ... your existing setup ...
          MeticaAdService.Initialize();
      }
  }

Banner/MRec focus pause/resume (only if you use those formats): call
MeticaAdService.BannerOnFocus(hasFocus) and MeticaAdService.MrecOnFocus(
hasFocus) from your own OnApplicationFocus handler somewhere in your
game (typically a persistent MonoBehaviour, or wherever your app
already handles Unity application-focus events).

Load-failure retry: under static_class, MeticaAdService relies on
MeticaSDK's built-in exp-backoff retry — OnInterstitialLoadFailed /
OnRewardedLoadFailed log the failure and do not schedule an app-side
retry (MonoBehaviour.Invoke is unavailable here). If you want an
additional app-side safety net, add a deferred-call into those two
handlers from your own scheduler (a coroutine runner, a System.Timers.
Timer, a Task.Delay continuation marshalled to the main thread, etc.).
The MeticaAdService.cs file is yours after generation — extend those
two log-only bodies if you need belt-and-braces retry.
```

**When `SHAPE=plain_class`:**

```
Construct one MeticaAdService instance in your bootstrap, store it
(singleton / DI container / static field), and call Initialize():

  public class AdsManager
  {
      private MeticaAdService _metica;
      public void Init()
      {
          _metica = new MeticaAdService();
          _metica.Initialize();
      }
      public void Show() => _metica.ShowInterstitial("level_end");
  }

Banner/MRec focus pause/resume (only if you use those formats): call
_metica.BannerOnFocus(hasFocus) / _metica.MrecOnFocus(hasFocus) from
your own OnApplicationFocus handler (typically a persistent
MonoBehaviour or wherever your app handles Unity application-focus
events).

Load-failure retry: under plain_class, MeticaAdService relies on
MeticaSDK's built-in exp-backoff retry — OnInterstitialLoadFailed /
OnRewardedLoadFailed log the failure and do not schedule an app-side
retry (MonoBehaviour.Invoke is unavailable here). If you want an
additional app-side safety net, extend those two handlers with a
deferred-call from your project's scheduler (a coroutine runner /
System.Timers.Timer / Task.Delay marshalled to the main thread).
```

The walkthrough emits exactly one block matching `$SHAPE`; the other two are omitted.

#### CMP-gated init wiring (when a CMP was detected)

Include this addendum whenever Step 2.5 Signal 5 detected a CMP (`CMP_PROVIDER ≠ none`) — it runs whether or not MaxSDK is present, and it **overrides the init call in the shape block above**. The generated `MeticaAdService` **does not auto-init**: `__START_HOOK__` was emitted empty for every shape, so init is intentionally deferred until consent resolves. State that plainly, then show the host how to call the consent-gated `Initialize(bool hasUserConsent, bool doNotSell)` overload from the CMP completion callback, **marshalled to the Unity main thread** (the CMP callback — UMP especially — frequently fires off-main; `MeticaSdk.Initialize` must run on the main thread, per the validator's `sdk_calls_on_main_thread` rule).

```
CMP detected (<CMP_PROVIDER>): init is consent-gated.

MeticaAdService will NOT initialize on its own — __START_HOOK__ is empty, so there is
no auto-init hook. Instead of the Initialize() call shown in the wiring block above,
call Initialize(hasUserConsent, doNotSell) from your CMP completion callback, with the
resolved consent values, on the Unity main thread. The privacy setters
(SetHasUserConsent / SetDoNotSell) then reflect the real consent, before init.

Capture the main-thread context once, where you construct/attach MeticaAdService
(that code runs on the Unity main thread):
    // monobehaviour: in Awake();  static_class/plain_class: in your bootstrap
    SynchronizationContext _mainCtx = SynchronizationContext.Current;
    // _ads is your MeticaAdService reference:
    //   monobehaviour  → GetComponent<MeticaAdService>() (or the attached instance)
    //   static_class   → call MeticaAdService.Initialize(...) directly (no instance)
    //   plain_class    → your stored `new MeticaAdService()` instance
```

Then, per CMP, from the consent callback (swap `_ads.Initialize` for `MeticaAdService.Initialize` under static_class):

```
google-ump:
    ConsentForm.LoadAndShowConsentFormIfRequired(formError => {
        bool consent = ConsentInformation.CanRequestAds();  // your resolved consent
        _mainCtx.Post(_ => _ads.Initialize(consent, doNotSell: false), null);
    });

max-cmp (AppLovin):
    MaxCmpService.ShowCmpForIfNeeded(error => {
        bool consent = /* your resolved consent from the CMP result */;
        _mainCtx.Post(_ => _ads.Initialize(consent, doNotSell: false), null);
    });

custom:
    OnYourConsentResolved(consent, doNotSell) {   // your existing consent gate
        _mainCtx.Post(_ => _ads.Initialize(consent, doNotSell), null);
    }
```

Notes:
- Do NOT call Initialize from the auto-init hook or before the CMP returns — that ships a
  wrong/empty consent state to MeticaSDK and the mediated ad networks (a compliance violation).
- If your CMP callback already runs on the Unity main thread, the `_mainCtx.Post` wrapper is
  harmless; keep it unless you've confirmed the callback thread.
- Map your CMP's consent result to `hasUserConsent` (GDPR) and `doNotSell` (CCPA) per your
  compliance posture; the overload just forwards them to the privacy setters.
```

Replace `<CMP_PROVIDER>` with the detected value and keep only the matching per-CMP snippet. When `CMP_PROVIDER == none`, omit this addendum entirely (the shape block's auto-init / explicit `Initialize()` stands).

#### Credential hygiene (now validator-driven)

The validator's `placeholder_ids_replaced` and `user_id_not_test_value` checks catch leftover `YOUR_*` keys and test/debug userId literals. When they FAIL, the validator emits a `<file>:<line>` location and the offending value — surface these verbatim from the validator's JSON output rather than re-grepping in the integrator. A short reminder is still useful inline:

```
⚠ The validator flagged credential placeholders / a test-value userId.
  These will be caught on every re-run of the validator (CI, post-edit, audit).
  Replace with your real values, then re-run @agent-unity-validator to confirm green.
```

When validator returned **PASS**, the credential checks passed too — no extra prose needed.

When **MaxSDK was present**, the report must also include:

1. **Max-callsite outcome** — the integration mode (`replace` or `switchable`) and the files rewritten to call `MeticaAdService` directly (or, if the user declined, the inventory as an action checklist). Under `switchable`, also state where the switch lives (`MeticaAdService.UseMetica`, default `true`) and that it is set once at startup — flipping mid-session requires a restart.
2. **Orphaned Max** — if a dedicated Max-wrapper file (e.g. `AdManager.cs`) was left untouched per the wrapper-scoping rule, note that it is now unused by the rewritten call sites and is the user's to delete when ready. Also note that `Assets/MaxSdk/` and the AppLovin dependency can be removed once they confirm the swap works (the integrator does not remove them).
3. **Wrapper `MaxSdkCallbacks` subscription sites** — the wrapper-scoping rule leaves wrapper files read-only, including their `MaxSdkCallbacks.<Format>.On*Event +=` subscriptions. Those subscriptions stay live: when MeticaSDK runs MAX under the hood (`MeticaMediationInfo(MAX, …)`), the underlying `AppLovinSdk` instance fires events on every loaded ad, **including Metica-driven loads under a trial-routed user**, so each wrapper subscription's handler fires too. List every site found during Step 2 discovery (one bullet per `MaxSdkCallbacks.*Event +=` match in a wrapper file). Then add this guidance verbatim:

   ```
   Effect if your code keeps the wrapper reachable alongside MeticaAdService:
     • Analytics in the wrapper's handlers run TWICE (once via the wrapper,
       once via Metica's per-format handlers).
     • Custom retry loops in the wrapper compete with MeticaSDK's built-in
       exp-backoff retry.
     • State flags (`_isLoading` / `_lastShownAt`) become stale relative to
       MeticaSDK's actual ad lifecycle.

   Two ways to fix:
     (a) Ensure your routing layer keeps the wrapper unreachable when running
         the Metica chain (e.g. cohort-gate at the bootstrap, only one chain
         alive per user — recommended).
     (b) Manually unsubscribe these handlers when switching to the Metica
         chain (only needed if both chains can be live simultaneously, which
         is uncommon).
   ```

   Skip this section entirely when Step 2 discovery returned `Max wrapper: none` — there's no wrapper to enumerate.

4. **Cohort-gating recipe** (only when Step 2.5 detected a remote-config provider ≠ `none`) — see below.
5. **Manual steps remaining** — set the real user identity in `MeticaInitConfig` (validator will keep failing until you do), choose the `SetHasUserConsent`/`SetDoNotSell` values per compliance posture.

#### Cohort-gating recipe (MaxSDK present + remote-config provider detected)

Mature games with a remote-config provider often want to roll out Metica gradually rather than swap unconditionally. The integrator does **not** generate a router or rollout-binding — the user wires their own gate using the provider they already have. Include this section in the final report when `REMOTE_CONFIG_PROVIDER ≠ none`:

```
Cohort-gating recipe (your project has <PROVIDER> remote-config):

The integration rewrote your Max call sites to call MeticaAdService directly.
To roll out gradually, gate the rewritten calls behind a remote-config flag you
add in your <PROVIDER> dashboard (e.g. boolean key "metica_rollout").

Pattern:
  // Read once at startup, cache the decision for the session.
  bool useMetica = <provider-read-expression>;
  if (useMetica) _ads.ShowInterstitial(...);
  else           <your-old-Max-call>(...);  // restore Max from `git show pre-metica-integration:<file>`

Provider-specific read expressions:
  firebase           → FirebaseRemoteConfig.DefaultInstance.GetValue("metica_rollout").BooleanValue
  unity-remote-config → RemoteConfigService.Instance.appConfig.GetBool("metica_rollout")
  appmetrica         → consult your AppMetrica SDK docs for the feature-flag accessor
                       (Io.AppMetrica.AppMetrica.GetFeatureFlag("metica_rollout") in recent versions)

Notes:
- The integration deleted your old Max calls; if you need to restore them
  for the false branch, restore from your pre-integration git tag.
- The Step 5 inventory of rewritten call sites is the punch list.
- Don't hard-code `useMetica = true` in production builds — gate it behind your
  real remote-config decision.
```

Replace `<PROVIDER>` and the read-expression with the detected value. When the provider is `none`, omit this section entirely (no rollout recipe makes sense without a remote-config provider).

When the run used `MAX_MODE=switchable`, replace the recipe's pattern with driving the generated switch — the false branch is already live code, so no git-restore is needed:

```
  // Read once at startup, before the first ad call:
  MeticaAdService.UseMetica = <provider-read-expression>;
```

The rest of the recipe (provider read expressions, the don't-hard-code note) applies unchanged.

#### Standing caveats (every run)

End the report with the threading reminder on **every** run.

```
⚠️ Threading: call MeticaSdk.Initialize and all Load*/Show* from the Unity main
   thread (the SDK marshals callbacks to the SynchronizationContext captured at the
   call site). Don't kick off init from a consent/UMP callback or a Task continuation
   without marshalling first.
```

Then append `RUN COMPLETE` to the checkpoint log and recommend (one line) adding `.metica-integration.log` to the project's `.gitignore`.

## Hard rules

- Never modify any file under `Assets/MaxSdk/`. When MaxSDK is present, rewrite only the game's direct `MaxSdk.*` call sites (scene/game logic) — never a dedicated Max-wrapper file (see the wrapper-scoping rule in Step 5).
- The generated design is the single standalone `MeticaAdService` MonoBehaviour (per-format `@fmt` regions) — the integrator does not generate a cohort/rollout router or rollout-binding code. The user-chosen `MAX_MODE=switchable` gate (`MeticaAdService.UseMetica` + gated call sites) is a supported mode, not a router. If the user wants gradual rollout, point them to the Step 7 cohort-gating recipe (under switchable the recipe drives the switch; otherwise they gate the rewritten call sites behind their own remote-config flag).
- Privacy calls (`SetHasUserConsent`, `SetDoNotSell`) **must** precede `MeticaSdk.Initialize` and live in the **same file** (the `MeticaAdService` orchestrator).
- Reuse the existing Max ad unit IDs for MeticaSDK (per migration guide).
- Sub-agent invocations (compat-checker, validator) **must** be in fresh subagent contexts — never share your reasoning context with them.
- If `$PLUGIN_DIR` is empty after running `resolve-plugin-dir.sh`, abort. Never run scripts with relative paths.

## References

- `../../references/max-vs-metica-2.4.0-api.md` — API parity table (MaxSdk ↔ MeticaSdk).
- `../../references/metica-sdk-migration.md` — per-version MeticaSDK migration map (what changes between SDK versions); drives the `INTEGRATION_MODE=upgrade` code migration in Step 5.
- `../../scripts/templates/standalone/MeticaAdService.cs.tmpl` — the single orchestrator template: one `MeticaAdService` MonoBehaviour with per-format `@fmt` regions (named callback handlers, exp-backoff retry on interstitial/rewarded load failure, focus pause/resume for banner/MRec).
- [meticalabs/metica-unity@develop `Assets/Scripts/HomeScreen.cs`](https://github.com/meticalabs/metica-unity/blob/develop/Assets/Scripts/HomeScreen.cs) — the **canonical demo and primary API reference**. It compiles against the real SDK, so it wins when it diverges from the docs page (e.g. it qualifies the nested enum `MeticaMediationInfo.MeticaMediationType.MAX` and PascalCases `SmartFloors.IsForcedHoldout`).
- [docs.metica.com Unity SDK Ad implementation](https://docs.metica.com/api/unity-sdk/unity-sdk-2#a-d-implementation) — **secondary** reference for callback set + lifecycle shape. The docs example has known transcription errors against the SDK (unqualified `MeticaMediationType.MAX`, camelCase `isForcedHoldout`); never transcribe it verbatim — the SDK source and canonical demo take precedence.
- `../../agents/contracts.md` — sub-agent JSON schemas and extraction regex.
