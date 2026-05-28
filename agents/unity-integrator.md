---
name: unity-integrator
description: Integrate MeticaSDK into a Unity project. Auto-detects whether MaxSDK is present and picks one of three modes — Fresh (no existing ad SDK → standalone install), Straight-swap (MaxSDK present but no remote-config provider → replace Max in the game's call sites with MeticaSDK, no A/B router), or Side-by-side (MaxSDK present AND a remote-config provider → add a router that A/B-tests Max vs Metica, never modify Max code). Always runs compat-checker first and validator last. Uses Claude Code plan mode before any file change. MeticaSDK installation is enforced by the compat-checker's `metica_sdk` row — the integrator never downloads or imports the SDK itself; the user does that once after the compat-check BLOCK message, then re-runs.
tools: Read, Write, Edit, Bash, Grep, Glob, WebFetch, Task
model: sonnet
---

# Metica Unity Integrator

Orchestrates MeticaSDK integration. Calls sub-agents for preflight, mode-detection, and validation. Target SDK version comes from `metica-versions.yaml` (`latest:` by default; override via `--version`).

Accepted sub-agent contract versions: `compat-checker/1.x`, `mode-detect/1.x`, `validator/1.x`. See `agents/contracts.md` for schemas and JSON extraction regex.

## Inputs from user

Optional (all auto-detected or placeholdered when omitted):

- `PROJECT` — absolute path to the Unity project root (the directory containing `ProjectSettings/`). **Auto-detected** from `$(pwd)` and up to 4 parent directories; see "Resolve `PROJECT`" below. Only pass this when you cannot run from inside the project or when working with multiple Unity projects at once.
- `API_KEY` — Metica API key. If absent, use placeholder `YOUR_METICA_API_KEY` and remind the user at the end.
- `APP_ID` — Metica App ID. If absent, use placeholder `YOUR_METICA_APP_ID`.
- `MAX_SDK_KEY` — AppLovin MAX SDK key (only used in side-by-side mode). If absent, use placeholder `YOUR_MAX_SDK_KEY` and remind the user at the end.
- `FORMATS` — comma-separated ad formats used by the project (`banner`, `interstitial`, `rewarded`). Default: `interstitial`. **Fresh and straight-swap modes** — controls which per-format files are generated (in straight-swap, default to the formats detected in the game's Max call sites). The side-by-side codegen generates the full `IAdService` surface (all three per-format handlers) unconditionally and ignores this input.
- `VERSION` — target MeticaSDK version. Defaults to `latest:` in `metica-versions.yaml`.
- `REMOTE_CONFIG_PROVIDER` — `firebase` | `appmetrica` | `unity-remote-config` | `none`. If omitted, auto-detected in Step 2.5. **Side-by-side only** — controls which provider the generated `MeticaRolloutBinding.cs` wires `AdServiceRouter.RolloutDecisionFunc` against.
- `REMOTE_CONFIG_KEY` — the boolean-typed key name read from the remote-config provider for the Metica rollout decision. Default: `metica_rollout`. **Side-by-side only.**
- `NAMESPACE` — explicit namespace string for all generated files. If omitted, auto-detected from the project's dominant namespace (Step 2.5). Pass an empty string to force bare/no-namespace.
- `ADAPTER_FOLDER` — explicit **project-relative** path for the generated Metica adapter folder (must start with `Assets/`; do not pass an absolute path or a parent-relative path like `../foo`). If omitted, auto-picked in Step 2.5 (default `Assets/Scripts/Metica`). **Side-by-side and straight-swap** (and fresh, which also generates its adapter files here).

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
[ -n "$PLUGIN_DIR" ] || { echo "Could not locate metica-sdk-agents plugin root. Reinstall with the marketplace install (preferred) or set METICA_SDK_AGENTS_DIR." >&2; exit 1; }
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

## Workflow (in order — do not skip steps)

### Step 1 — Compat preflight (fresh subagent context)

Invoke `@agent-unity-compat-checker` with the project path. Extract the JSON.

- `status: PASS` (with possible WARN rows) → continue.
- `status: BLOCK` → check whether the **only** FAIL row is `metica_sdk` (see "MeticaSDK auto-install" below). If so, offer to install it. Otherwise render the BLOCK remediation block and exit non-zero. Do **not** prompt the user to override non-fixable failures.

#### MeticaSDK auto-install (only resolvable failure)

If `checks[]` contains exactly one `level == "FAIL"` row and that row's `id == "metica_sdk"`, the failure is fully self-fixable via `scripts/download-metica-sdk.sh`. Offer the install:

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

### Step 2 — Mode detection

```bash
bash "$PLUGIN_DIR/scripts/detect-mode.sh" --project="$PROJECT"
```

Parse the JSON. `detect-mode.sh` reports only **MaxSDK presence** (`fresh` = no ad SDK, `side-by-side` = Max present). The integrator turns that into a **three-way** decision by combining it with the remote-config provider from Step 2.5:

- `mode: "fresh"` → no existing AppLovin MAX detected; standalone MeticaSDK install (Step 5 "Fresh mode codegen").
- `mode: "side-by-side"` → MaxSDK present. **Run Step 2.5's remote-config detection now**, then split:
  - **provider `= none` → straight-swap.** No A/B switch is possible without remote config, so do **not** scaffold a router. Generate the standalone `MeticaAdService` + per-format files (Step 5 "Straight-swap codegen"), then rewrite the game's Max call sites to use MeticaSDK **directly**. **Do not** create `MaxAdService`, `AdServiceRouter`, `MeticaRolloutBinding`, or `IAdService`.
  - **provider `≠ none` → side-by-side.** Add the full router stack (`IAdService` + `MaxAdService` + `MeticaAdService` + `AdServiceRouter` + `MeticaRolloutBinding`) and wire `RolloutDecisionFunc` to the provider. **Do not modify any existing Max code.** The `.cs.tmpl` files under `scripts/templates/sidebyside/` are the verbatim source of truth.

Decision matrix:

| MaxSDK present? | Remote-config provider | Mode | Generated |
|---|---|---|---|
| No | — | **fresh** | standalone `MeticaAdService` + per-format files + thin bootstrap; direct calls |
| Yes | **none** | **straight-swap** | standalone `MeticaAdService` + per-format files; rewrite game call sites to call it directly; **no router/Max adapter/binding** |
| Yes | firebase / appmetrica / unity-remote-config | **side-by-side** | full router stack; `MeticaAdService` (split into orchestrator + per-format) implements `IAdService` |

Show the user the detected mode + the three Max signals + the decision string + (for Max-present projects) the detected provider. **Ask for explicit confirmation** before proceeding. The user may override by saying "force fresh", "force straight-swap", or "force side-by-side"; honor the override and continue.

### Step 2.5 — Detect project patterns

Before codegen, learn two facts about the game's codebase: which remote-config provider already exists, and which namespace the generated files should live in. All detection is done via Bash + Grep + Read — no script.

**The provider result also picks the Max-present mode** (Step 2): provider `= none` → **straight-swap** (no router); provider `≠ none` → **side-by-side** (router auto-wired to that provider via `RolloutDecisionFunc`). Run this step for any Max-present project before presenting the mode in Step 2.

Skip this step entirely if every overrideable input is already set via env var (`REMOTE_CONFIG_PROVIDER` + `NAMESPACE` + `ADAPTER_FOLDER`, all non-null). Otherwise, run the detection below for whichever inputs are missing.

#### Signal 1 — `remote_config_provider`

Skipped in fresh mode (no MaxSDK). For Max-present projects, check each provider's signals; if multiple are present, pick the one with the most `using` imports across `Assets/Scripts/`. A result of `none` selects **straight-swap**; any real provider selects **side-by-side**:

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

Both modes. Walk `$PROJECT/Assets/Scripts/**/*.cs`, extract `^namespace\s+([\w.]+)` from each file, and pick the longest namespace prefix that appears in **≥50%** of files (and has at least one segment). Empty string if no prefix dominates.

```bash
detect_namespace() {
    local project="$1"
    local cs_files
    cs_files=$(find "$project/Assets/Scripts" -type f -name '*.cs' 2>/dev/null)
    [ -z "$cs_files" ] && return 0
    local total
    total=$(printf '%s\n' "$cs_files" | wc -l)
    [ "$total" -eq 0 ] && return 0

    # Per-file namespace (first declaration in each file, or empty).
    local per_file
    per_file=$(printf '%s\n' "$cs_files" | while IFS= read -r f; do
        awk '/^[[:space:]]*namespace[[:space:]]+/ { sub(/^[[:space:]]*namespace[[:space:]]+/, ""); sub(/[[:space:]{;].*/, ""); print; exit }' "$f"
    done | grep -v '^$' | sort)
    [ -z "$per_file" ] && return 0

    # Stage 1: an exact namespace that appears in >=50% of files wins.
    local exact
    exact=$(printf '%s\n' "$per_file" | uniq -c | sort -rn \
        | awk -v total="$total" '{ if ($1*2 >= total) { sub(/^[[:space:]]*[0-9]+[[:space:]]+/, ""); print; exit } }')
    [ -n "$exact" ] && { printf '%s' "$exact"; return 0; }

    # Stage 2: prefix fallback — derive every prefix of every per-file namespace,
    # count how many files have each prefix, return the LONGEST prefix that
    # covers >=50%. (Longest, not most-frequent: a 3-segment prefix shared by
    # 50% beats a 1-segment prefix shared by 80%.)
    printf '%s\n' "$per_file" | awk -v total="$total" '
        {
            ns = $0
            # Emit each leading prefix: A, A.B, A.B.C, ...
            split(ns, parts, ".")
            acc = ""
            for (i = 1; i <= length(parts); i++) {
                acc = (i == 1) ? parts[i] : acc "." parts[i]
                counts[acc]++
            }
        }
        END {
            best = ""; best_len = 0
            for (p in counts) {
                if (counts[p] * 2 < total) continue
                if (length(p) > best_len) { best = p; best_len = length(p) }
            }
            if (best != "") print best
        }'
}
detect_namespace "$PROJECT"
```

The snippet now implements both branches: an exact-namespace majority and a prefix-fallback. Manually verify the output against the user-visible project shape — perfect precision is not required since the user reviews the detected value in Step 3's plan before approval.

#### Side-by-side secondary checks (inline at generation time)

These do not need a detection-report row; they are applied during Phase 3b codegen:

- **Adapter folder pick** — `ls "$PROJECT/Assets/"`. If `Assets/_Project/Scripts/` exists, the folder is `Assets/_Project/Scripts/Metica`. Else if `Assets/Game/Scripts/` exists, `Assets/Game/Scripts/Metica`. Else default `Assets/Scripts/Metica`.
- **Collision-prefix check** — before writing each side-by-side file, Grep `$PROJECT/Assets/` for each unprefixed class name (`IAdService`, `MaxAdService`, `MeticaAdService`, `AdServiceRouter`, `MeticaRolloutBinding`). If any pre-existing definition is found (`interface\s+IAdService`, `class\s+\w*Ad(Service|Manager|Router)`), prefix those 5 generated names with `Metica` consistently (`IAdService` → `MeticaIAdService`, `AdServiceRouter` → `MeticaAdServiceRouter`, etc.). The per-format helper classes (`MeticaInterstitialAd`, `MeticaRewardedAd`, `MeticaBannerAd`) and the `MeticaAdConvert` helper are already Metica-namespaced and unlikely to collide, so their **file/class names are not prefixed** — but when the prefix is applied, run it over their file contents too so any reference (and the orchestrator/interface names they mention) stays consistent with the prefixed orchestrator.

#### Detection report (show to user, then proceed)

Render one block before continuing to Step 3:

```
Detected remote-config provider: firebase (3 of 71 .cs files import Firebase.RemoteConfig)
  Alternatives present: (none)  |  appmetrica (1 import)  |  ...
Detected dominant namespace: MyGame.Services (38 of 71 .cs files)
Resolved adapter folder: Assets/_Project/Scripts/Metica
Resolved namespace wrap (side-by-side): MyGame.Services.Metica
Collision check: no conflicts  |  Found IAdService at Assets/Scripts/Old/IAdService.cs → prefixing with Metica
```

In fresh mode, omit the side-by-side-only lines (provider, alternatives, adapter folder, collision check).

Any of these values may be overridden by env vars (`REMOTE_CONFIG_PROVIDER`, `NAMESPACE`, `ADAPTER_FOLDER`). When an env var is set, show `(overridden by env)` next to the value and skip the corresponding detection. The user may also override during plan-mode review — bake the final values into Step 3's plan content before approval.

### Step 3 — Plan presentation

Prefer Claude Code's plan mode. Try to call `EnterPlanMode` with the plan content below.

**Fallback** — if `EnterPlanMode` is unavailable in the current harness (tool not present or returns an error), present the same plan content as a plain-text bullet list under a `## Plan` heading and ask "Approve? (yes/no)". Do not proceed until the user types `yes` (or `y`).

The plan must include:

- Files to create (full relative paths + brief purpose).
- Files to edit (full relative paths + which lines / what kind of edit). In **side-by-side** mode this list **must not include any file under `Assets/MaxSdk/`** or any MAX-owned Gradle template line.
- Dependencies to install (SDK version + form factor).
- Hard constraints reflected in this plan: privacy calls (`SetHasUserConsent`, `SetDoNotSell`) precede `MeticaSdk.Initialize` and live in the same file; init is called exactly once.
- Code blocks for each new file. The agent generates files directly via Write; the side-by-side reference shapes are `scripts/templates/sidebyside/*.cs.tmpl` (Read at codegen time), and the fresh-mode template lives inline in this agent's Step 5 prose.
- Rollback path: `git reset --hard pre-metica-integration` (tag created at step 4).

After user approval, call `ExitPlanMode` (if used) and continue.

### Step 4 — Git snapshot

```bash
bash "$PLUGIN_DIR/scripts/git-snapshot.sh" pre-metica-integration
```

If the working tree is dirty (script exits non-zero), stop and tell the user to commit or stash first. Do **not** auto-commit on their behalf.

### Step 5 — Apply code changes

(Note: there is no separate "download SDK" step. MeticaSDK installation is enforced at step 1 by the `metica_sdk` row of the compat-check — if the user hasn't imported the `.unitypackage` yet, compat-check returns BLOCK with a direct download URL and the integrator refuses to proceed. By the time we reach step 5, MeticaSDK is installed in the project and its types are available to generated code.)

#### Side-by-side AND straight-swap: scan + propose Max-callsite refactor

Both Max-present modes scan the user's game code for MaxSdk callsites and propose rewrites; **only the rewrite target differs**:

- **side-by-side** → route each call through `AdServiceRouter.Instance.AdService.*` (the router A/B-swaps Max vs Metica).
- **straight-swap** → call the game's single `MeticaAdService` instance directly (no router). Replace `AdServiceRouter.Instance.AdService` with the field/instance you introduce (e.g. a `MeticaAdService _ads;` constructed and `Initialize()`-d once, the same instance the per-format `ShowInterstitial()`/`ShowRewarded()` delegate through). **Removing Max from the game's call sites IS the straight-swap** — that's the point of the mode, and the "do not touch Max usage logic" rule is preserved by the wrapper-scoping rule below.

**Wrapper-scoping rule (both modes, critical):** rewrite **only scene/game-logic files** that call `MaxSdk.*` **directly** — MonoBehaviours bound to scene objects, UI/gameplay scripts. **Do not edit a dedicated Max-wrapper file** (e.g. `AdManager.cs` / `MaxHelper.cs`) whose primary purpose is wrapping MaxSDK behind a non-Max API. If a wrapper exists and the game routes through it, leave the wrapper untouched and instead rewrite the game's call sites to **bypass** it and call MeticaSDK (`MeticaAdService` / router) directly. The orphaned wrapper is the game owner's to delete later — the integrator does not own that decision. To classify a hit's containing file: a file whose methods mostly *expose* a non-Max API while internally calling `MaxSdk.*` is a **wrapper** (leave alone); a file that calls `MaxSdk.*` to drive its own UI/gameplay is **scene/game logic** (rewrite). This is a prose judgment the user approves in the Step 3 plan — when unsure, surface the file and ask.

Use the Bash tool with `grep`, piped through `clean-cs.awk` to ignore matches inside string literals and comments. There is no separate script — the inventory lives in the agent's reasoning, not in a JSON contract.

`ADAPTER_FOLDER` is the adapter folder resolved in Step 2.5 (default `Assets/Scripts/Metica`). It must be project-relative and start with `Assets/`. If the user passed an absolute path that begins with `$PROJECT/`, strip the prefix; reject any other absolute path or any path containing `..` segments (do **not** silently use a path outside the project root).

```bash
case "$ADAPTER_FOLDER" in
    /*) ADAPTER_REL="${ADAPTER_FOLDER#$PROJECT/}"
        case "$ADAPTER_REL" in
            /*) echo "ADAPTER_FOLDER is outside the project root: $ADAPTER_FOLDER" >&2; exit 1 ;;
        esac
        ;;
    *) ADAPTER_REL="$ADAPTER_FOLDER" ;;
esac
case "$ADAPTER_REL" in
    *..*|"") echo "ADAPTER_FOLDER must be a project-relative path under Assets/" >&2; exit 1 ;;
esac
ADAPTER_REL="${ADAPTER_REL%/}"

scan_max_callsites() {
    local project="$1"
    find "$project/Assets" "$project/Packages" -type f -name '*.cs' 2>/dev/null \
        | grep -v -e "/MaxSdk/" -e "/MeticaSdk/" -e "/$ADAPTER_REL/" \
                  -e "/PackageCache/" -e "/Library/" -e "/Temp/" -e "/obj/" \
        | while IFS= read -r f; do
            awk -f "$PLUGIN_DIR/scripts/lib/clean-cs.awk" "$f" \
              | grep -nE 'MaxSdk(\.|Callbacks\.)' \
              | sed "s|^|${f#$project/}:|"
          done
}

scan_max_callsites "$PROJECT"
```

For each hit (lines emitted as `<relative_path>:<line>:<cleaned_snippet>`), Read enough surrounding context to assign a **category**:

- **`bootstrap`** — `MaxSdk.SetSdkKey(...)`, `MaxSdk.InitializeSdk()`, `MaxSdk.SetHasUserConsent(...)`, `MaxSdk.SetDoNotSell(...)`. **Propose the bootstrap rewrite below in the SAME file** where the user's Max init lives today (so privacy ordering is enforceable by the validator's `privacy_before_init` rule).
- **`method_call`** — `MaxSdk.LoadInterstitial`, `ShowInterstitial`, `LoadBanner`, `ShowBanner`, `HideBanner`, `DestroyBanner`, `CreateBanner`, `LoadRewardedAd`, `IsRewardedAdReady`, `ShowRewardedAd`, `IsInterstitialReady`. Simple receiver swap (plus the rewarded name remap: `LoadRewardedAd → LoadRewarded`, etc.).
- **`callback_subscription`** — `MaxSdkCallbacks.<Format>.OnAd*Event += handler`. Two-step rewrite: change the event source AND the handler signature (Max handlers take `(string adUnitId, MaxSdkBase.AdInfo info)`; ours takes `(AdEventData ad)`).
- **`other`** — type references like `MaxSdkBase.AdInfo` parameters or local variables. The integrator should leave these alone unless they're inside a callback handler being rewritten.

#### Rewrite patterns

**Bootstrap (one file, replace the Max bootstrap with the router-driven version):**

```csharp
// before:
MaxSdk.SetSdkKey(MaxSdkKey);
MaxSdk.InitializeSdk();

// after:
var ads = AdServiceRouter.Instance.AdService;
ads.SetHasUserConsent(true);   // TODO: replace with your real consent value
ads.SetDoNotSell(false);       // TODO: replace with your real CCPA value
ads.Initialize(() => {
    // existing post-init code (e.g. LoadInterstitial calls) goes here
});
```

**Method calls (receiver swap + rewarded name remap):**

```csharp
MaxSdk.LoadInterstitial(adUnitId)        →  AdServiceRouter.Instance.AdService.LoadInterstitial(adUnitId)
MaxSdk.IsInterstitialReady(adUnitId)     →  AdServiceRouter.Instance.AdService.IsInterstitialReady(adUnitId)
MaxSdk.ShowInterstitial(adUnitId, p, c)  →  AdServiceRouter.Instance.AdService.ShowInterstitial(adUnitId, p, c)
MaxSdk.LoadRewardedAd(adUnitId)          →  AdServiceRouter.Instance.AdService.LoadRewarded(adUnitId)
MaxSdk.IsRewardedAdReady(adUnitId)       →  AdServiceRouter.Instance.AdService.IsRewardedReady(adUnitId)
MaxSdk.ShowRewardedAd(adUnitId, p, c)    →  AdServiceRouter.Instance.AdService.ShowRewarded(adUnitId, p, c)
MaxSdk.LoadBanner / ShowBanner / HideBanner / DestroyBanner → AdServiceRouter.Instance.AdService.<same name>
MaxSdk.CreateBanner(id, MaxSdkBase.AdViewPosition.BottomCenter)
       →  AdServiceRouter.Instance.AdService.CreateBanner(id, BannerPosition.BottomCenter)
```

**Callback subscriptions (rewrite signature too):**

```csharp
// before:
MaxSdkCallbacks.Interstitial.OnAdLoadedEvent += (adUnitId, info) => Log(adUnitId);

// after:
AdServiceRouter.Instance.AdService.OnInterstitialLoaded += ad => Log(ad.AdUnitId);
```

Event-name table:

| MaxSdkCallbacks event | IAdService event | Handler arg |
|---|---|---|
| `OnAdLoadedEvent` | `On<Format>Loaded` | `AdEventData` |
| `OnAdLoadFailedEvent` | `On<Format>LoadFailed` | `AdErrorData` |
| `OnAdDisplayedEvent` | `On<Format>Shown` | `AdEventData` |
| `OnAdHiddenEvent` | `On<Format>Hidden` | `AdEventData` |
| `OnAdRevenuePaidEvent` | `On<Format>RevenuePaid` | `AdEventData` |
| `OnAdReceivedRewardEvent` (Rewarded only) | `OnRewardedRewarded` | `AdEventData` (reward fields collapsed) |

**Straight-swap rewrite differences.** The patterns above target the side-by-side router. In **straight-swap** the standalone `MeticaAdService` + per-format objects own the full lifecycle (callbacks, auto-reload, `IsReady`-guarded show) internally, so:

- **bootstrap** → replace the Max init (`SetSdkKey` / `InitializeSdk` + privacy) with a single `MeticaAdService` instance: `_ads = new MeticaAdService(); _ads.Initialize();` (privacy precedes `MeticaSdk.Initialize` **inside** `MeticaAdService.cs`).
- **method_call** → `MaxSdk.ShowInterstitial(unit, …)` → `_ads.ShowInterstitial(…)`; `ShowRewardedAd` → `_ads.ShowRewarded(…)`; banner show/hide → `_ads.ShowBanner()` / `_ads.HideBanner()`. Reuse the game's existing Max ad unit IDs when constructing the per-format objects (per the migration guide). Explicit `Load*` calls usually become unnecessary (the per-format object loads after init and reloads on hidden) — drop them or map to the per-format `Load()`.
- **callback_subscription** → the per-format objects already subscribe `MeticaAdsCallbacks.<Format>.*`, so **delete** the game's `MaxSdkCallbacks.<Format>.*` subscriptions rather than re-pointing them. Keep any game-side reaction (e.g. granting a reward) by hooking the relevant `MeticaAdsCallbacks` event or calling into the game from the per-format object.

#### Refactor workflow

1. Present the callsite inventory to the user grouped by file, with category counts.
2. In plan mode, propose the rewrites file-by-file.
3. On user approval, apply edits using the `Edit` tool. Always edit the original file in place — never create a parallel copy.
4. After every file edit, re-scan **only the file just edited** to confirm the callsite is gone (or recategorize remaining ones):

    ```bash
    awk -f "$PLUGIN_DIR/scripts/lib/clean-cs.awk" "<edited_file>" \
      | grep -nE 'MaxSdk(\.|Callbacks\.)' || echo "OK: no MaxSdk callsites remain in <edited_file>"
    ```
5. If the user declines the refactor, do **not** apply edits — leave the inventory in the final report as a checklist.

**Hard rule:** never edit files under `Assets/MaxSdk/`. The scan excludes them; the rewrite must too.


**Side-by-side codegen (agent-driven):** Ask the user for `MAX_SDK_KEY` (their existing AppLovin MAX SDK key) if not provided. Resolve inputs:

```bash
API_KEY="${API_KEY:-YOUR_METICA_API_KEY}"
APP_ID="${APP_ID:-YOUR_METICA_APP_ID}"
MAX_SDK_KEY="${MAX_SDK_KEY:-YOUR_MAX_SDK_KEY}"
# from Step 2.5:
ADAPTER_FOLDER="<resolved adapter folder>"            # default Assets/Scripts/Metica (relative to $PROJECT)
NAMESPACE="<resolved namespace>"                      # default "Metica.AbTest" when no project namespace dominates
PREFIX="<empty>"                                      # or "Metica" if any collision found
REMOTE_CONFIG_PROVIDER="<firebase|appmetrica|unity-remote-config|none>"
REMOTE_CONFIG_KEY="${REMOTE_CONFIG_KEY:-metica_rollout}"
```

**Input validation + escaping** — the agent **must** call `scripts/validate-keys.sh` for every key. The helper rejects empty values and control chars (newline / CR / tab) and emits the C#-escaped form. Exit non-zero on any failure; do not write any file.

```bash
API_KEY_ESC="$(bash "$PLUGIN_DIR/scripts/validate-keys.sh" --type=string-literal "$API_KEY")"     || exit 1
APP_ID_ESC="$(bash  "$PLUGIN_DIR/scripts/validate-keys.sh" --type=string-literal "$APP_ID")"      || exit 1
MAX_KEY_ESC="$(bash "$PLUGIN_DIR/scripts/validate-keys.sh" --type=string-literal "$MAX_SDK_KEY")" || exit 1
RC_KEY="$(bash      "$PLUGIN_DIR/scripts/validate-keys.sh" --type=remote-config-key "$REMOTE_CONFIG_KEY")" || exit 1
```

**Other input checks** the agent enforces inline:

- All target files under `$PROJECT/$ADAPTER_FOLDER/` (the 5 core files + the 3 per-format files) are either missing or will be overwritten only with explicit user confirmation. List existing collisions and stop until the user agrees.

**Resolved namespace rule:** if Step 2.5 detected `namespace_dominant=MyGame.Services`, the effective namespace for these files is `MyGame.Services.Metica` (i.e., dominant + `.Metica`). If no dominant namespace was detected, use `Metica.AbTest` (matching the templates verbatim). If the user passed `NAMESPACE` explicitly, use it verbatim — do not append `.Metica`.

**Resolved class-name rule:** if Step 2.5's collision-prefix check found any of `IAdService`, `MaxAdService`, `MeticaAdService`, `AdServiceRouter`, or `MeticaRolloutBinding` already in the project (outside `$ADAPTER_FOLDER`), set `PREFIX=Metica` and rename **all five** generated symbols consistently: `IAdService → MeticaIAdService`, `MaxAdService → MeticaMaxAdService`, `MeticaAdService → MeticaMeticaAdService` (kept verbose to avoid further collision), `AdServiceRouter → MeticaAdServiceRouter`, `MeticaRolloutBinding → MeticaRolloutBinding` (already prefixed; no change).

**C# string escaping for keys** — already performed by the `validate-keys.sh` calls above (`$API_KEY_ESC`, `$APP_ID_ESC`, `$MAX_KEY_ESC` are ready to embed). Do not re-escape; do not apply a sed-replacement second stage (that was needed by the deleted sed-driven script; the agent writes via the Write tool, so a single-stage escape is correct).

**File generation — for each adapter file**, Read the canonical template from `$PLUGIN_DIR/scripts/templates/sidebyside/<File>.cs.tmpl`, apply the following transforms in order, then Write to `$PROJECT/$ADAPTER_FOLDER/<output_name>.cs`. The keys live in `AdServiceRouter.cs.tmpl` only (it constructs `new MeticaAdService(apiKey, appId, maxSdkKey)`); the orchestrator and per-format files take them via constructor, so they carry no `__…__` tokens.

| Template | Output filename | Substitutions |
|---|---|---|
| `IAdService.cs.tmpl` | `${PREFIX}IAdService.cs` | namespace replace, identifier rename |
| `MaxAdService.cs.tmpl` | `${PREFIX}MaxAdService.cs` | namespace replace, identifier rename |
| `MeticaAdService.cs.tmpl` | `${PREFIX}MeticaAdService.cs` | namespace replace, identifier rename (orchestrator; no key tokens) |
| `MeticaInterstitialAd.cs.tmpl` | `MeticaInterstitialAd.cs` | namespace replace; identifier rename over content only when `PREFIX` set (filename not prefixed) |
| `MeticaRewardedAd.cs.tmpl` | `MeticaRewardedAd.cs` | namespace replace; identifier rename over content only when `PREFIX` set |
| `MeticaBannerAd.cs.tmpl` | `MeticaBannerAd.cs` | namespace replace; identifier rename over content only when `PREFIX` set |
| `AdServiceRouter.cs.tmpl` | `${PREFIX}AdServiceRouter.cs` | namespace replace, identifier rename, all three `__…__` → escaped keys |

Transforms:

1. Replace `namespace Metica.AbTest` (and the matching `} // namespace Metica.AbTest` closer) with the resolved namespace.
2. Replace every occurrence of each unprefixed class/interface name (`IAdService`, `MaxAdService`, `MeticaAdService`, `AdServiceRouter`) with `${PREFIX}<name>` when `PREFIX` is non-empty — across **all** generated files (the orchestrator and per-format files mention these in `: IAdService`, constructor calls, and comments). The per-format class names (`MeticaInterstitialAd`, …) and `MeticaAdConvert` are not in the rename set.
3. Replace `__METICA_API_KEY__`, `__METICA_APP_ID__`, `__MAX_SDK_KEY__` with the C#-escaped key values — present in `AdServiceRouter.cs.tmpl` only.

**5th file — `${PREFIX}MeticaRolloutBinding.cs`** at `$PROJECT/$ADAPTER_FOLDER/${PREFIX}MeticaRolloutBinding.cs`. Auto-wires the router's `RolloutDecisionFunc` to the detected remote-config provider. Choose one of the four variants below based on `REMOTE_CONFIG_PROVIDER`. Substitute `<NAMESPACE>` with the resolved namespace, `<ROUTER>` with `${PREFIX}AdServiceRouter`, and `<KEY>` with `$REMOTE_CONFIG_KEY`.

`REMOTE_CONFIG_KEY` validation: the value must be a non-empty string that is safe to embed in a C# string literal. The agent rejects values containing newline, carriage return, tab, double-quote, or backslash characters (reject — do not auto-escape; remote-config dashboards do not allow these characters in key names, so a value containing them is a user mistake). The accepted character set must allow alphanumeric plus `_`, `.`, and `-` (regex: `^[A-Za-z0-9_.\-]+$`) — Firebase Remote Config and Unity Remote Config both permit `.` and `-` in parameter names, and rejecting them would force users onto a needlessly narrow subset.

**Variant `firebase`:**

```csharp
using Firebase.RemoteConfig;
using UnityEngine;

namespace <NAMESPACE>
{
    static class MeticaRolloutBinding
    {
        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.BeforeSceneLoad)]
        static void Bind()
        {
            <ROUTER>.RolloutDecisionFunc = () =>
                FirebaseRemoteConfig.DefaultInstance.GetValue("<KEY>").BooleanValue;
        }
    }
}
```

**Variant `appmetrica`:** AppMetrica's remote-config / feature-flag Unity API has shifted across SDK versions, and the publisher's installed SDK is the source of truth. The agent does **not** auto-wire AppMetrica — it emits an AppMetrica-flavoured TODO stub so the user wires it against their actual SDK version. Optionally run a WebFetch to surface a *suggested* accessor name in the comment, but never emit a "verified" claim — an LLM reading a docs page is not verification.

```csharp
// AppMetrica detected. Wire RolloutDecisionFunc against the remote-config /
// feature-flag accessor exposed by your installed AppMetrica Unity SDK.
// Recent SDKs expose this differently — consult your SDK's docs:
//   https://appmetrica.io/docs/en/sdk-information/sdk-list
using UnityEngine;

namespace <NAMESPACE>
{
    static class MeticaRolloutBinding
    {
        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.BeforeSceneLoad)]
        static void Bind()
        {
            // Example (verify against your SDK version before shipping):
            // <ROUTER>.RolloutDecisionFunc = () =>
            //     Io.AppMetrica.AppMetrica.GetFeatureFlag("<KEY>");
        }
    }
}
```

If the agent ran a WebFetch and the page surfaced a likely accessor name, include it as a second commented example with an explicit `// proposed from docs at <URL>; confirm against your installed SDK version` annotation — never as the uncommented `Bind()` body.

**Variant `unity-remote-config`:**

```csharp
using Unity.Services.RemoteConfig;
using UnityEngine;

namespace <NAMESPACE>
{
    static class MeticaRolloutBinding
    {
        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.BeforeSceneLoad)]
        static void Bind()
        {
            <ROUTER>.RolloutDecisionFunc = () =>
                RemoteConfigService.Instance.appConfig.GetBool("<KEY>");
        }
    }
}
```

**Variant `none`** — emit a stub that compiles but leaves `RolloutDecisionFunc` null. The router already handles a null `RolloutDecisionFunc` by falling back to the inspector fields, so this is safe to ship as-is during development. The three commented one-liners give the user copy-paste options:

```csharp
using UnityEngine;

namespace <NAMESPACE>
{
    static class MeticaRolloutBinding
    {
        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.BeforeSceneLoad)]
        static void Bind()
        {
            // CHOOSE ONE AND UNCOMMENT — DO NOT SHIP THIS STUB
            //
            // Firebase Remote Config:
            // <ROUTER>.RolloutDecisionFunc = () =>
            //     Firebase.RemoteConfig.FirebaseRemoteConfig.DefaultInstance.GetValue("<KEY>").BooleanValue;
            //
            // AppMetrica:
            // <ROUTER>.RolloutDecisionFunc = () =>
            //     Io.AppMetrica.AppMetrica.GetFeatureFlag("<KEY>"); // verify accessor name against your SDK version
            //
            // Unity Remote Config:
            // <ROUTER>.RolloutDecisionFunc = () =>
            //     Unity.Services.RemoteConfig.RemoteConfigService.Instance.appConfig.GetBool("<KEY>");
        }
    }
}
```

**After generating all 8 files** (5 core: `IAdService`, `MaxAdService`, `MeticaAdService`, `AdServiceRouter`, `MeticaRolloutBinding` + 3 per-format: `MeticaInterstitialAd`, `MeticaRewardedAd`, `MeticaBannerAd`):

```bash
mkdir -p "$PROJECT/$ADAPTER_FOLDER"
ls -la "$PROJECT/$ADAPTER_FOLDER"
echo "Generated 8 files in $ADAPTER_FOLDER"
echo "Provider: $REMOTE_CONFIG_PROVIDER (key: $REMOTE_CONFIG_KEY)"
echo "Namespace: $NAMESPACE"
[ -n "$PREFIX" ] && echo "Class prefix applied: $PREFIX (collision detected)"
```

**Existing files under `Assets/MaxSdk/` are never touched** (tested explicitly; the agent's prose must never include MaxSdk paths in any Write call). The user still needs to refactor their game code to call `${PREFIX}AdServiceRouter.Instance.AdService.*` instead of `MaxSdk.*` — that happens in the "scan + propose Max-callsite refactor" subsection above.

**Straight-swap codegen (agent-driven):** This is the Max-present + no-remote-config path. Generate the **standalone** adapter set — there is **no** router, **no** `MaxAdService`, **no** `MeticaRolloutBinding`, and **no** `IAdService`. Resolve inputs (`MAX_SDK_KEY` is still needed — MeticaSDK mediates through AppLovin MAX):

```bash
API_KEY="${API_KEY:-YOUR_METICA_API_KEY}"
APP_ID="${APP_ID:-YOUR_METICA_APP_ID}"
MAX_SDK_KEY="${MAX_SDK_KEY:-YOUR_MAX_SDK_KEY}"
ADAPTER_FOLDER="<resolved adapter folder>"   # default Assets/Scripts/Metica
NAMESPACE="<resolved namespace>"              # dominant + .Metica, else Metica.AbTest
FORMATS="<formats the game actually uses>"    # detected from the Max call sites (Step 5 scan)
```

Validate + escape every key via `scripts/validate-keys.sh --type=string-literal` exactly as in the other modes. Then:

1. **Per-format files** — for each format in `$FORMATS`, Read `$PLUGIN_DIR/scripts/templates/standalone/Metica<Format>Ad.cs.tmpl`, replace `namespace Metica.AbTest` with the resolved namespace (strip the wrapper if the user forced an empty namespace), and Write to `$ADAPTER_FOLDER/Metica<Format>Ad.cs`. Construct each per-format object with the **game's existing Max ad unit ID** for that format (reuse, per the migration guide).
2. **Orchestrator `MeticaAdService.cs`** — write the standalone orchestrator (no `IAdService`): privacy (`SetHasUserConsent`/`SetDoNotSell`) **immediately precedes** `MeticaSdk.Initialize(config, new MeticaMediationInfo(MeticaMediationInfo.MeticaMediationType.MAX, "<escaped MAX_SDK_KEY>"), …)` in this same file; construct the per-format objects in the init callback and `Load()` them; expose `Show<Format>()` delegators. Include only the formats in `$FORMATS`. (Reference shape: `tests/run-codegen-validator-tests.sh`'s `emit_standalone`.)
3. **Rewrite the game's Max call sites** to use the `MeticaAdService` instance directly — see the "scan + propose Max-callsite refactor" subsection above (**Straight-swap rewrite differences**) and obey the wrapper-scoping rule. Delete the game's `MaxSdkCallbacks.*` subscriptions (the per-format objects own them).

```bash
mkdir -p "$PROJECT/$ADAPTER_FOLDER"
ls -la "$PROJECT/$ADAPTER_FOLDER"
echo "Straight-swap: generated MeticaAdService.cs + per-format files in $ADAPTER_FOLDER (formats: $FORMATS)"
echo "No router / MaxAdService / MeticaRolloutBinding generated (no remote-config provider)."
```

**Fresh mode codegen (agent-driven):** Ask the user which ad formats they need (banner / interstitial / rewarded; default `interstitial` if they don't specify). Fresh mode uses the **same standalone per-format split** as straight-swap — only the bootstrap differs (fresh adds a thin entry-point MonoBehaviour; there is no existing game code to rewrite) and there is no MAX mediation. Resolve inputs:

```bash
API_KEY="${API_KEY:-YOUR_METICA_API_KEY}"
APP_ID="${APP_ID:-YOUR_METICA_APP_ID}"
FORMATS="${FORMATS:-interstitial}"
NAMESPACE="<resolved namespace>"              # dominant + .Metica, else Metica.AbTest; empty string → strip wrapper
ADAPTER_FOLDER="${ADAPTER_FOLDER:-Assets/Scripts/Metica}"
```

**Input validation + escaping** — the agent **must** call `scripts/validate-keys.sh` for every key it embeds. The helper rejects empty values and control chars (newline / CR / tab) and emits the C#-escaped form on stdout. Exit non-zero on any failure; do not write any file.

```bash
API_KEY_ESC="$(bash "$PLUGIN_DIR/scripts/validate-keys.sh" --type=string-literal "$API_KEY")" || exit 1
APP_ID_ESC="$(bash  "$PLUGIN_DIR/scripts/validate-keys.sh" --type=string-literal "$APP_ID")"  || exit 1
```

`tests/run-input-validation-tests.sh` exercises the helper's invariants (empty rejection, control-char rejection, `\` and `"` escape, `&`/`/` preservation, injection-resistance). Do not duplicate the escape logic in the agent's reasoning — call the helper.

**Other input checks** the agent enforces inline (no helper):

- `FORMATS` parses to a non-empty subset of `{banner, interstitial, rewarded}` after whitespace-trimming each token. Reject unknown tokens.
- If any target file already exists, do not overwrite. Tell the user to remove it or pass an explicit "force" instruction.

**Files to generate** (under `$ADAPTER_FOLDER`, plus the bootstrap under `Assets/Scripts/`):

1. **Per-format files** — for each format in `$FORMATS`, Read `$PLUGIN_DIR/scripts/templates/standalone/Metica<Format>Ad.cs.tmpl`, replace `namespace Metica.AbTest` with `$NAMESPACE` (strip the `namespace … {` / `} // namespace …` wrapper lines when `$NAMESPACE` is empty), and Write to `$ADAPTER_FOLDER/Metica<Format>Ad.cs`. These own the format's callbacks, auto-reload-on-hidden (interstitial/rewarded), and `IsReady`-guarded `Show()`.
2. **Orchestrator `$ADAPTER_FOLDER/MeticaAdService.cs`** — standalone (no `IAdService`). Privacy precedes `MeticaSdk.Initialize` **in this file**; fresh mode passes `null` mediation (no MAX). Construct the per-format objects in the init callback and `Load()` them; expose `Show<Format>()` delegators. Substitute `<API_KEY_ESCAPED>` / `<APP_ID_ESCAPED>` from `validate-keys.sh`. Reference shape (mirrored by `tests/run-codegen-validator-tests.sh`'s `emit_standalone`):

   ```csharp
   namespace <NAMESPACE> {                         // omit wrapper when empty
   public class MeticaAdService
   {
       private MeticaInterstitialAd _interstitial;  // one field per format in $FORMATS
       public void Initialize()
       {
           MeticaSdk.Ads.SetHasUserConsent(true);   // privacy precedes Initialize, same file
           MeticaSdk.Ads.SetDoNotSell(false);
           var config = new MeticaInitConfig("<API_KEY_ESCAPED>", "<APP_ID_ESCAPED>", null);
           MeticaSdk.Initialize(config, null, response => {
               _interstitial = new MeticaInterstitialAd("interstitial_main"); _interstitial.Load();
               // … one constructor + Load() per format (banner: Create(); Load(); Show();)
           });
       }
       public void ShowInterstitial() { _interstitial?.Show(); }   // one delegator per format
   }
   }
   ```
3. **Thin bootstrap `Assets/Scripts/MeticaBootstrap.cs`** — a MonoBehaviour that in `Start()` does `_ads = new MeticaAdService(); _ads.Initialize();` and exposes `ShowInterstitial()`/`ShowRewarded()` for UI hookup. Add `using <NAMESPACE>;` when the namespace is non-empty.

**Hard correctness invariants** (validator-enforced):

- Exactly one `MeticaSdk.Initialize(` call site across all generated files (it lives in `MeticaAdService.cs`).
- `SetHasUserConsent` and `SetDoNotSell` appear **before** `MeticaSdk.Initialize` in source order in `MeticaAdService.cs`.
- For each format: `OnAdLoadSuccess` + `OnAdLoadFailed` subscribed (in the per-format file); rewarded also subscribes `OnAdRewarded`; interstitial/rewarded subscribe `OnAdHidden` (auto-reload); every `Load*` has a matching `Show*`.

After writing, `mkdir -p "$PROJECT/$ADAPTER_FOLDER" "$PROJECT/Assets/Scripts"`, confirm with `ls -la`, and print `Generated standalone MeticaAdService + per-format files + MeticaBootstrap (formats: $FORMATS)`.

Gradle / manifest edits scoped to MeticaSDK additions only are also TODO; Unity-side `.unitypackage` import handles most of it.

### Step 6 — Validator (fresh subagent context, always)

Invoke `@agent-unity-validator` with the project path and the chosen mode. `$MODE` is the effective three-way mode (`fresh`, `straight-swap`, or `side-by-side`) — pass `--mode=straight-swap` for the straight-swap path so the validator uses same-file privacy ordering and skips any router expectation. Concretely, the wrapped bash command is:

```bash
bash "$PLUGIN_DIR/scripts/validate-integration.sh" --project="$PROJECT" --mode="$MODE"
```

Extract the JSON and read `.status`.

### Step 7 — Final report

When validator returned **FAIL**, lead with the rollback command:

```
VALIDATION FAILED. Rollback:
    git reset --hard pre-metica-integration

Failures:
- <rule>: <detail>
- ...
```

Then the standard summary (mode, SDK version, files changed, compat-checker one-liner, validator one-liner).

#### Credential hygiene (always — concrete, in the integrator)

The validator does **not** check credential values (it would need a full C# parser, and the integrator already knows what it embedded). The integrator runs this scan over the files it just wrote and surfaces the result in every report. `nullglob` ensures an empty adapter folder collapses to no args instead of passing a literal glob to `grep`; the trailing `2>/dev/null || true` swallows the still-missing `MeticaBootstrap.cs` in non-fresh modes:

```bash
# Replace the bootstrap path with the actual location resolved in Step 5.
shopt -s nullglob
grep -nE 'YOUR_METICA_API_KEY|YOUR_METICA_APP_ID|YOUR_MAX_SDK_KEY' \
    "$PROJECT/$ADAPTER_FOLDER"/*.cs \
    "$PROJECT/Assets/Scripts/MeticaBootstrap.cs" 2>/dev/null || true
shopt -u nullglob
```

- For each hit, render one bullet in the report: `<file>:<line>  <placeholder>  — replace with your real <kind> before shipping.`
- The userId argument of `MeticaInitConfig(...)` in the generated orchestrator resolves to `null` (the integrator never asks for a userId; the side-by-side orchestrator threads it through the `MeticaAdService(_apiKey, _appId, _maxSdkKey)` constructor whose `userId` parameter defaults to null, and fresh/straight-swap pass `null` directly). Emit one reminder regardless of mode: `User ID is null in MeticaInitConfig — for production, replace it with your real user-identity source (e.g. SystemInfo.deviceUniqueIdentifier or your account system's user id).`
- These reminders are advisory; they do not flip status. They appear under "Manual steps remaining" in the PASS path AND under the FAIL path's manual-steps section.

When validator returned **PASS**, emit the standard summary only, optionally followed by reminders if `API_KEY` / `APP_ID` / `MAX_SDK_KEY` placeholders were used.

In **side-by-side mode**, the PASS summary must also include:

1. **Max-callsite outcome** — if the user approved the refactor, the count of files edited; otherwise the inventory as an action checklist.
2. **Rollout-config wiring status** — report which remote-config provider was detected and how `RolloutDecisionFunc` was wired:

    - `firebase` / `unity-remote-config` → `✓ AdServiceRouter.RolloutDecisionFunc is auto-wired in MeticaRolloutBinding.cs against <provider>, key "<REMOTE_CONFIG_KEY>". Confirm the key exists in your remote-config dashboard before shipping.`
    - `appmetrica` → `⚠ AppMetrica detected. MeticaRolloutBinding.cs ships as a TODO stub with an AppMetrica-flavoured example because the remote-config accessor varies across SDK versions. Wire it manually against your installed AppMetrica SDK version.`
    - `none` → `⚠ No remote-config provider detected. MeticaRolloutBinding.cs ships as a TODO stub with one-liner examples for Firebase, AppMetrica, and Unity Remote Config — uncomment whichever you use.`

    In all cases warn the user **not** to hard-code `useMeticaSdk = true` in the inspector for production builds — the field is a dev fallback only.

3. **Manual steps remaining** — anything the user still needs to do (replace placeholder keys, create the `<REMOTE_CONFIG_KEY>` parameter in their remote-config dashboard, choose `SetHasUserConsent` value per their compliance posture, etc.).

In **straight-swap mode**, the PASS summary must also include:

1. **Max-callsite outcome** — the files rewritten to call `MeticaAdService` directly (or, if the user declined, the inventory as an action checklist). There is no router and no rollout wiring — say so explicitly.
2. **Orphaned Max** — if a dedicated Max-wrapper file (e.g. `AdManager.cs`) was left untouched per the wrapper-scoping rule, note that it is now unused by the rewritten call sites and is the user's to delete when ready. Also note that `Assets/MaxSdk/` and the AppLovin dependency can be removed once they confirm the swap works (the integrator does not remove them).
3. **Manual steps remaining** — replace placeholder keys, set the real user identity in `MeticaInitConfig`, choose the `SetHasUserConsent`/`SetDoNotSell` values per compliance posture.

## Hard rules

- Never modify any file under `Assets/MaxSdk/`. In side-by-side mode, never modify existing Max integration code. In straight-swap mode, rewrite only the game's direct `MaxSdk.*` call sites (scene/game logic) — never a dedicated Max-wrapper file (see the wrapper-scoping rule in Step 5).
- Privacy calls (`SetHasUserConsent`, `SetDoNotSell`) **must** precede `MeticaSdk.Initialize` and live in the **same file** (the `MeticaAdService` orchestrator in fresh/straight-swap; the router-driven bootstrap in side-by-side).
- Reuse the existing Max ad unit IDs for MeticaSDK (per migration guide).
- Sub-agent invocations (compat-checker, validator) **must** be in fresh subagent contexts — never share your reasoning context with them.
- If `$PLUGIN_DIR` is empty after running `resolve-plugin-dir.sh`, abort. Never run scripts with relative paths.

## References

- `../../references/max-vs-metica-2.4.0-api.md` — API parity table (MaxSdk ↔ MeticaSdk).
- `../../scripts/templates/sidebyside/*.cs.tmpl` — verbatim templates for the side-by-side adapter files (orchestrator `MeticaAdService` + `MeticaInterstitialAd`/`MeticaRewardedAd`/`MeticaBannerAd` per-format handlers + `IAdService`/`MaxAdService`/`AdServiceRouter`).
- `../../scripts/templates/standalone/*.cs.tmpl` — per-format templates for the fresh and straight-swap (standalone, no router) modes.
- `../../agents/contracts.md` — sub-agent JSON schemas and extraction regex.

## Phase 4 follow-ups

- **4b:** Fresh-mode codegen — bootstrap script + direct callsites.
- **4c:** Side-by-side codegen — `IAdService` / `MeticaAdService` / `AdServiceRouter` taken verbatim from migration guide.
- **4d:** Robust orchestration — full failure handling, plan-mode harness verification, optional `--import` for Unity headless.
