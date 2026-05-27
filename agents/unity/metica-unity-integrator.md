---
name: metica-unity-integrator
description: Integrate MeticaSDK into a Unity project. Auto-detects whether MaxSDK is present and chooses Fresh mode (no existing ad SDK → standalone install) or Side-by-side adapter mode (MaxSDK present → add a separate MeticaAdapter, never modify Max code). Always runs compat-checker first and validator last. Uses Claude Code plan mode before any file change. MeticaSDK installation is enforced by the compat-checker's `metica_sdk` row — the integrator never downloads or imports the SDK itself; the user does that once after the compat-check BLOCK message, then re-runs.
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
- `FORMATS` — comma-separated ad formats used by the project (`banner`, `interstitial`, `rewarded`). Default: `interstitial`. **Both modes.** Only the per-format provider files for the listed formats are generated (see Step 5). In side-by-side mode, when omitted, formats are auto-detected from the project's existing `MaxSdk.Load*` callsites.
- `VERSION` — target MeticaSDK version. Defaults to `latest:` in `metica-versions.yaml`.
- `REMOTE_CONFIG_PROVIDER` — `firebase` | `appmetrica` | `unity-remote-config` | `gameanalytics` | `none`. If omitted, auto-detected in Step 2.5. **Side-by-side only** — controls which provider the generated `MeticaRolloutBinding.cs` wires `AdServiceRouter.RolloutDecisionFunc` against.
- `REMOTE_CONFIG_KEY` — the boolean-typed key name read from the remote-config provider for the Metica rollout decision. Default: `metica_rollout`. **Side-by-side only.**
- `NAMESPACE` — explicit namespace string for all generated files. If omitted, auto-detected from the project's dominant namespace (Step 2.5). Pass an empty string to force bare/no-namespace.
- `ADAPTER_FOLDER` — explicit **project-relative** path for the side-by-side adapter folder (must start with `Assets/`; do not pass an absolute path or a parent-relative path like `../foo`). If omitted, auto-picked in Step 2.5 (default `Assets/Scripts/Metica`). **Side-by-side only.**

## Setup — establish `PLUGIN_DIR`

Resolve the plugin root automatically; do **not** ask the user for it. The first bash command of every run is:

```bash
PLUGIN_DIR="$(bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/metica-sdk-agents}/scripts/resolve-plugin-dir.sh" 2>/dev/null \
    || bash "$HOME/.metica-sdk-agents/scripts/resolve-plugin-dir.sh" 2>/dev/null \
    || bash "$(pwd)/.claude/agents/../../scripts/resolve-plugin-dir.sh" 2>/dev/null)"
[ -n "$PLUGIN_DIR" ] || { echo "Could not locate metica-sdk-agents plugin root. Reinstall with the marketplace install (preferred) or set METICA_SDK_AGENTS_DIR." >&2; exit 1; }
```

`scripts/resolve-plugin-dir.sh` checks `$CLAUDE_PLUGIN_ROOT` (set by Claude Code for marketplace-installed plugins), `$METICA_SDK_AGENTS_DIR`, symlink targets under `.claude/agents/`, and known install paths. If it fails, abort — do not run scripts with relative paths.

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

## Workflow (in order — do not skip steps)

### Step 1 — Compat preflight (fresh subagent context)

Invoke `@agent-metica-unity-compat-checker` with the project path. Extract the JSON.

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

The script verifies the SHA-256 checksum from `metica-versions.yaml`, places the `.unitypackage` at `$PROJECT/Assets/MeticaSDK-<version>.unitypackage`, and (with `--import`) launches Unity headless to import it. After it succeeds, re-invoke `@agent-metica-unity-compat-checker` from a fresh subagent context. If compat-check is now PASS, continue with step 2. If it still BLOCKs, render the remediation block (auto-install isn't infinite-retry; the second failure is real).

If Unity headless is not available (no `UNITY_PATH` set, no Hub-installed Unity matching the project version), the download script will fall back to placing the `.unitypackage` in `Assets/` and printing "double-click to import in the Editor". Surface that to the user with one extra step: "Unity isn't on PATH for headless import — open the project and double-click `Assets/MeticaSDK-<version>.unitypackage`, then re-run me."

On `n`, render the standard BLOCK remediation block (which already contains the URL) and exit.

#### BLOCK remediation template

For each `check` where `level == "FAIL"`, emit one bullet using `id`, `detected`, `required`, and `hint`. Example for the DemoApp's Android-API failure:

```
Compat-check found 1 blocking issue:

  • Android API min: 19 (need >=23)
    Fix: Set AndroidMinSdkVersion: 23 in ProjectSettings/ProjectSettings.asset,
         or Edit > Project Settings > Player > Android > Minimum API Level.

After applying the fix, re-run @agent-metica-unity-integrator.
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

Parse the JSON:

- `mode: "fresh"` → no existing AppLovin MAX detected; standalone MeticaSDK install.
- `mode: "side-by-side"` → MaxSDK present. **Do not modify any existing Max code.** Add the Metica adapter family next to the user's existing Max integration: `MeticaAdProvider` (init/lifecycle, implements `IAdService`) plus a per-format provider class for each ad format the game uses (`MeticaBannerProvider`, `MeticaInterstitialProvider`, `MeticaRewardedProvider`), plus the `IAdService` interface and `AdServiceRouter`. The `.cs.tmpl` files under `scripts/templates/sidebyside/` are the verbatim source of truth. `MaxAdService.cs` is **not** split — only the Metica side is per-format.

Show the user the detected mode + the three signals + the decision string. **Ask for explicit confirmation** before proceeding. The user may override by saying "force fresh" or "force side-by-side"; honor the override and continue.

### Step 2.5 — Detect project patterns

Before codegen, learn two facts about the game's codebase: which remote-config provider already exists (used to auto-wire `AdServiceRouter.RolloutDecisionFunc` in side-by-side mode), and which namespace the generated files should live in. All detection is done via Bash + Grep + Read — no script.

Skip this step entirely if every overrideable input is already set via env var (`REMOTE_CONFIG_PROVIDER` + `NAMESPACE` + `ADAPTER_FOLDER`, all non-null). Otherwise, run the detection below for whichever inputs are missing.

#### Signal 1 — `remote_config_provider`

Skipped in fresh mode (no `AdServiceRouter` exists). In side-by-side mode, check each provider's signals; if multiple are present, pick the one with the most `using` imports across `Assets/Scripts/`:

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
- **`gameanalytics`** — any of:
  - `[ -d "$PROJECT/Assets/GameAnalytics" ]`
  - `grep -q '"com.gameanalytics.sdk"' "$PROJECT/Packages/manifest.json" 2>/dev/null`
  - Any `.cs` file matches `^using GameAnalyticsSDK`, or references `GameAnalytics\.GetABTestingId` / `OnABTestingDataReceived` (GameAnalytics A/B testing surfaces a variant ID rather than a boolean flag — see the rollout-binding variant)
- **`none`** — no provider above detected.

To pick a dominant provider when multiple are present, count `using` imports for each (`grep -rcE '^using (Firebase\.RemoteConfig|Io\.AppMetrica|Unity\.RemoteConfig|GameAnalyticsSDK)' "$PROJECT/Assets/Scripts/" 2>/dev/null | awk -F: '$2>0'`) and choose the highest. **Floor each detected provider's count at 1**: several providers are detected purely by folder or manifest signals (Firebase via `Assets/Firebase`, Unity RC and GameAnalytics via `manifest.json`, GameAnalytics also via `GetABTestingId` references) and may have zero `^using` lines under `Assets/Scripts/` (referenced fully-qualified, or from a non-`Scripts` folder). A provider detected by any Signal-1 check but with a 0 import count must still participate in the tiebreak — never let an import count of 0 silently drop a provider that Signal 1 found. Surface all detected providers (with counts) in the detection report so the user can override.

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
- **Collision-prefix check** — before writing each side-by-side file, Grep `$PROJECT/Assets/` for each unprefixed class name (`IAdService`, `MaxAdService`, `MeticaAdProvider`, `AdServiceRouter`, `MeticaRolloutBinding`). If any pre-existing definition is found (`interface\s+IAdService`, `class\s+\w*Ad(Service|Provider|Manager|Router)`), prefix all generated names with `Metica` consistently (`IAdService` → `MeticaIAdService`, `AdServiceRouter` → `MeticaAdServiceRouter`, etc.). The per-format provider classes (`MeticaBannerProvider`, `MeticaInterstitialProvider`, `MeticaRewardedProvider`) are already `Metica`-prefixed; leave them unchanged.

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

#### Side-by-side: scan + propose Max-callsite refactor

After codegen, scan the user's game code for MaxSdk callsites that need to be rewritten to go through `AdServiceRouter`. Use the Bash tool with `grep`, piped through `clean-cs.awk` to ignore matches inside string literals and comments. There is no separate script — the inventory lives in the agent's reasoning, not in a JSON contract.

`ADAPTER_FOLDER` is the side-by-side adapter folder resolved in Step 2.5 (default `Assets/Scripts/Metica`). It must be project-relative and start with `Assets/`. If the user passed an absolute path that begins with `$PROJECT/`, strip the prefix; reject any other absolute path or any path containing `..` segments (do **not** silently use a path outside the project root).

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
REMOTE_CONFIG_PROVIDER="<firebase|appmetrica|unity-remote-config|gameanalytics|none>"
REMOTE_CONFIG_KEY="${REMOTE_CONFIG_KEY:-metica_rollout}"
```

**Resolve `FORMATS`** — the Metica adapter is split per ad format: only the per-format provider files for formats the game actually uses are generated. When `FORMATS` is passed, use it verbatim. Otherwise derive it from the Max-callsite inventory you already gathered in the "scan + propose Max-callsite refactor" subsection above:

- `MaxSdk.LoadBanner` / `CreateBanner` / `ShowBanner` present → include `banner`
- `MaxSdk.LoadInterstitial` / `ShowInterstitial` / `IsInterstitialReady` present → include `interstitial`
- `MaxSdk.LoadRewardedAd` / `ShowRewardedAd` / `IsRewardedAdReady` present → include `rewarded`

If the scan surfaced no ad-format callsites at all, default to all three (the game may not have wired ads yet). Methods on `IAdService` for formats **not** in `FORMATS` are still present in `MeticaAdProvider` (the interface demands the full surface for A/B parity with `MaxAdService`) but emit a NO-OP stub body — see the format-block step below.

**Input validation + escaping** — the agent **must** call `scripts/validate-keys.sh` for every key. The helper rejects empty values and control chars (newline / CR / tab) and emits the C#-escaped form. Exit non-zero on any failure; do not write any file.

```bash
API_KEY_ESC="$(bash "$PLUGIN_DIR/scripts/validate-keys.sh" --type=string-literal "$API_KEY")"     || exit 1
APP_ID_ESC="$(bash  "$PLUGIN_DIR/scripts/validate-keys.sh" --type=string-literal "$APP_ID")"      || exit 1
MAX_KEY_ESC="$(bash "$PLUGIN_DIR/scripts/validate-keys.sh" --type=string-literal "$MAX_SDK_KEY")" || exit 1
RC_KEY="$(bash      "$PLUGIN_DIR/scripts/validate-keys.sh" --type=remote-config-key "$REMOTE_CONFIG_KEY")" || exit 1
```

**Other input checks** the agent enforces inline:

- All five target files under `$PROJECT/$ADAPTER_FOLDER/` are either missing or will be overwritten only with explicit user confirmation. List existing collisions and stop until the user agrees.

**Resolved namespace rule:** if Step 2.5 detected `namespace_dominant=MyGame.Services`, the effective namespace for these files is `MyGame.Services.Metica` (i.e., dominant + `.Metica`). If no dominant namespace was detected, use `Metica.AbTest` (matching the templates verbatim). If the user passed `NAMESPACE` explicitly, use it verbatim — do not append `.Metica`.

**Resolved class-name rule:** if Step 2.5's collision-prefix check found any of `IAdService`, `MaxAdService`, `MeticaAdProvider`, `AdServiceRouter`, or `MeticaRolloutBinding` already in the project (outside `$ADAPTER_FOLDER`), set `PREFIX=Metica` and rename those generated symbols consistently: `IAdService → MeticaIAdService`, `MaxAdService → MeticaMaxAdService`, `MeticaAdProvider → MeticaMeticaAdProvider` (kept verbose to avoid further collision), `AdServiceRouter → MeticaAdServiceRouter`, `MeticaRolloutBinding → MeticaRolloutBinding` (already prefixed; no change). The per-format provider classes (`MeticaBannerProvider`, `MeticaInterstitialProvider`, `MeticaRewardedProvider`) are already `Metica`-prefixed — leave their names unchanged in all cases.

**C# string escaping for keys** — already performed by the `validate-keys.sh` calls above (`$API_KEY_ESC`, `$APP_ID_ESC`, `$MAX_KEY_ESC` are ready to embed). Do not re-escape; do not apply a sed-replacement second stage (that was needed by the deleted sed-driven script; the agent writes via the Write tool, so a single-stage escape is correct).

**File generation** — Read the canonical template from `$PLUGIN_DIR/scripts/templates/sidebyside/<File>.cs.tmpl`, apply the transforms below, then Write to `$PROJECT/$ADAPTER_FOLDER/<output_name>.cs`. The unconditional files are generated every run; per-format provider files are generated **only** for formats in `FORMATS`:

| Template | Output filename | When | Substitutions |
|---|---|---|---|
| `IAdService.cs.tmpl` | `${PREFIX}IAdService.cs` | always | namespace replace, identifier rename |
| `MaxAdService.cs.tmpl` | `${PREFIX}MaxAdService.cs` | always | namespace replace, identifier rename (takes `maxSdkKey` via constructor — no key placeholder) |
| `MeticaAdProvider.cs.tmpl` | `${PREFIX}MeticaAdProvider.cs` | always | namespace replace, identifier rename, **format-block stripping** |
| `AdServiceRouter.cs.tmpl` | `${PREFIX}AdServiceRouter.cs` | always | namespace replace, identifier rename, all three `__…__` → escaped keys |
| `MeticaBannerProvider.cs.tmpl` | `MeticaBannerProvider.cs` | `banner` in `FORMATS` | namespace replace |
| `MeticaInterstitialProvider.cs.tmpl` | `MeticaInterstitialProvider.cs` | `interstitial` in `FORMATS` | namespace replace |
| `MeticaRewardedProvider.cs.tmpl` | `MeticaRewardedProvider.cs` | `rewarded` in `FORMATS` | namespace replace |

Note: the `__METICA_API_KEY__` / `__METICA_APP_ID__` placeholders live in `AdServiceRouter.cs.tmpl` (it constructs `MeticaAdProvider` with the keys); `MeticaAdProvider.cs.tmpl` itself takes them via constructor and has no key placeholders.

Transforms:

1. Replace `namespace Metica.AbTest` (and the matching `} // namespace Metica.AbTest` closer) with the resolved namespace.
2. Replace every occurrence of each unprefixed class/interface name (`IAdService`, `MaxAdService`, `MeticaAdProvider`, `AdServiceRouter`) with `${PREFIX}<name>` when `PREFIX` is non-empty. Including type references in other generated files (e.g. `AdServiceRouter`'s field declarations referencing `IAdService`). Do **not** prefix the per-format provider class names.
3. Replace `__METICA_API_KEY__`, `__METICA_APP_ID__`, `__MAX_SDK_KEY__` with the C#-escaped key values. All three placeholders live **only** in `AdServiceRouter.cs.tmpl` (it constructs `MeticaAdProvider` and `MaxAdService` with the keys); no other template carries a key placeholder.

**Format-block stripping (`MeticaAdProvider.cs.tmpl` only):** the template carries paired marker comments so the agent can keep only the wiring + method bodies for formats in `FORMATS`. Markers come in three families per format `<F>` (`BANNER` / `INTERSTITIAL` / `REWARDED`):

- `// __FMT_<F>_BEGIN__` … `// __FMT_<F>_END__` — field declaration + `Initialize()` wiring for that format's provider.
- `// __FMT_<F>_BODY_BEGIN__` … `// __FMT_<F>_BODY_END__` — the real `IAdService` method body that delegates to the provider.
- `// __FMT_<F>_STUB_BEGIN__` … `// __FMT_<F>_STUB_END__` — the NO-OP stub body used when the format is unused.

Apply this transform with `sed` (run it via Bash on the substituted file). For each format **in** `FORMATS`, delete the STUB blocks and unwrap (remove only the marker lines of) the outer + BODY blocks. For each format **not** in `FORMATS`, delete the outer + BODY blocks entirely and unwrap the STUB blocks. The EOL anchor tolerates trailing whitespace so a stray space never leaks a marker into the output:

```bash
# $USED is the space-separated uppercase format list, e.g. "INTERSTITIAL REWARDED"
strip_format_blocks() {
    local infile="$1" outfile="$2" used="$3" f script=""
    for f in BANNER INTERSTITIAL REWARDED; do
        if printf '%s\n' $used | grep -qx "$f"; then
            script="$script
/__FMT_${f}_STUB_BEGIN__/,/__FMT_${f}_STUB_END__/d
/__FMT_${f}_BEGIN__[[:space:]]*\$/d
/__FMT_${f}_END__[[:space:]]*\$/d
/__FMT_${f}_BODY_BEGIN__[[:space:]]*\$/d
/__FMT_${f}_BODY_END__[[:space:]]*\$/d"
        else
            script="$script
/__FMT_${f}_BEGIN__/,/__FMT_${f}_END__/d
/__FMT_${f}_BODY_BEGIN__/,/__FMT_${f}_BODY_END__/d
/__FMT_${f}_STUB_BEGIN__[[:space:]]*\$/d
/__FMT_${f}_STUB_END__[[:space:]]*\$/d"
        fi
    done
    sed "$script" "$infile" > "$outfile"
}
```

After stripping, the generated `MeticaAdProvider.cs` must contain no `__FMT_` residue (verify with `grep -L __FMT_`).

**5th file — `${PREFIX}MeticaRolloutBinding.cs`** at `$PROJECT/$ADAPTER_FOLDER/${PREFIX}MeticaRolloutBinding.cs`. Auto-wires the router's `RolloutDecisionFunc` to the detected remote-config provider. Choose one of the five variants below based on `REMOTE_CONFIG_PROVIDER`. Substitute `<NAMESPACE>` with the resolved namespace, `<ROUTER>` with `${PREFIX}AdServiceRouter`, and `<KEY>` with `$REMOTE_CONFIG_KEY`.

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

**Variant `gameanalytics`:** GameAnalytics A/B testing surfaces a **variant ID string** (not a boolean), so `<KEY>` here is the variant ID that should route users to MeticaSdk. The default `REMOTE_CONFIG_KEY` (`metica_rollout`) is a boolean key name and will **never** match a real GA variant ID — when `REMOTE_CONFIG_PROVIDER` resolves to `gameanalytics` and `REMOTE_CONFIG_KEY` was not explicitly set, **stop and ask the user for the GA variant ID** rather than emitting a binding that silently never selects the Metica cohort. The variant ID must satisfy `validate-keys.sh --type=remote-config-key` (`^[A-Za-z0-9_.\-]+$`); GA dashboard variant names containing spaces or other characters must be renamed to that charset (the agent rejects them rather than embedding an invalid literal). `GetABTestingId()` returns the empty string until A/B data has been received, so cold-start users fall into the MaxSdk cohort until the value is cached.

```csharp
using GameAnalyticsSDK;
using UnityEngine;

namespace <NAMESPACE>
{
    static class MeticaRolloutBinding
    {
        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.BeforeSceneLoad)]
        static void Bind()
        {
            <ROUTER>.RolloutDecisionFunc = () =>
                GameAnalytics.GetABTestingId() == "<KEY>";
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
            //
            // GameAnalytics A/B (compare against the variant ID for the Metica cohort):
            // <ROUTER>.RolloutDecisionFunc = () =>
            //     GameAnalyticsSDK.GameAnalytics.GetABTestingId() == "<KEY>";
        }
    }
}
```

**After generating all files** (4 unconditional + one per format in `FORMATS` + `MeticaRolloutBinding.cs`):

```bash
mkdir -p "$PROJECT/$ADAPTER_FOLDER"
ls -la "$PROJECT/$ADAPTER_FOLDER"
echo "Generated adapter files in $ADAPTER_FOLDER (formats: $FORMATS)"
echo "Provider: $REMOTE_CONFIG_PROVIDER (key: $REMOTE_CONFIG_KEY)"
echo "Namespace: $NAMESPACE"
[ -n "$PREFIX" ] && echo "Class prefix applied: $PREFIX (collision detected)"
```

**Existing files under `Assets/MaxSdk/` are never touched** (tested explicitly; the agent's prose must never include MaxSdk paths in any Write call). The user still needs to refactor their game code to call `${PREFIX}AdServiceRouter.Instance.AdService.*` instead of `MaxSdk.*` — that happens in the "scan + propose Max-callsite refactor" subsection above.

**Fresh mode codegen (agent-driven):** Ask the user which ad formats they need (banner / interstitial / rewarded; default `interstitial` if they don't specify). Like side-by-side, the Metica adapter is split per ad format: a `MeticaAdProvider` MonoBehaviour bootstrap plus one `Metica<Format>Provider` helper class per format in `FORMATS`. Resolve inputs:

```bash
API_KEY="${API_KEY:-YOUR_METICA_API_KEY}"
APP_ID="${APP_ID:-YOUR_METICA_APP_ID}"
FORMATS="${FORMATS:-interstitial}"
NAMESPACE="${NAMESPACE-<value_from_step_2.5>}"  # default empty (bare namespace)
OUT_DIR="$PROJECT/Assets/Scripts/Metica"
```

**Input validation + escaping** — the agent **must** call `scripts/validate-keys.sh` for every key it embeds. The helper rejects empty values and control chars (newline / CR / tab) and emits the C#-escaped form on stdout. Exit non-zero on any failure; do not write any file.

```bash
API_KEY_ESC="$(bash "$PLUGIN_DIR/scripts/validate-keys.sh" --type=string-literal "$API_KEY")" || exit 1
APP_ID_ESC="$(bash  "$PLUGIN_DIR/scripts/validate-keys.sh" --type=string-literal "$APP_ID")"  || exit 1
```

`tests/run-input-validation-tests.sh` exercises the helper's invariants (empty rejection, control-char rejection, `\` and `"` escape, `&`/`/` preservation, injection-resistance) so they stay testable from bash even though codegen itself is agent-driven. Do not duplicate the escape logic in the agent's reasoning — call the helper.

**Other input checks** the agent enforces inline (no helper):

- `FORMATS` parses to a non-empty subset of `{banner, interstitial, rewarded}` after whitespace-trimming each token. Reject unknown tokens.
- If any target file under `$OUT_DIR/` already exists, do not overwrite. Tell the user to remove the existing files or pass an explicit "force" instruction.

**File generation** — Read the canonical template from `$PLUGIN_DIR/scripts/templates/fresh/<File>.cs.tmpl`, apply the transforms below, then Write to `$OUT_DIR/<output_name>.cs`. `MeticaAdProvider.cs` is generated every run; per-format provider files only for formats in `FORMATS`:

| Template | Output filename | When | Substitutions |
|---|---|---|---|
| `MeticaAdProvider.cs.tmpl` | `MeticaAdProvider.cs` | always | `__METICA_API_KEY__` / `__METICA_APP_ID__` → escaped keys, **format-block stripping**, optional namespace wrap |
| `MeticaBannerProvider.cs.tmpl` | `MeticaBannerProvider.cs` | `banner` in `FORMATS` | optional namespace wrap |
| `MeticaInterstitialProvider.cs.tmpl` | `MeticaInterstitialProvider.cs` | `interstitial` in `FORMATS` | optional namespace wrap |
| `MeticaRewardedProvider.cs.tmpl` | `MeticaRewardedProvider.cs` | `rewarded` in `FORMATS` | optional namespace wrap |

Transforms:

1. Replace `__METICA_API_KEY__`, `__METICA_APP_ID__` with `$API_KEY_ESC` / `$APP_ID_ESC` (`MeticaAdProvider.cs` only).
2. **Format-block stripping (`MeticaAdProvider.cs.tmpl` only):** the fresh template carries `// __FMT_<F>_BEGIN__` … `// __FMT_<F>_END__` markers around each format's field declaration, `Start()` wiring, and `Show<Format>()` method. For each format in `FORMATS`, remove only the marker lines (unwrap); for each format not in `FORMATS`, delete the whole block. Use the same EOL-anchored `sed` recipe as side-by-side (the fresh template has only the outer `BEGIN/END` family — no BODY/STUB pair):

   ```bash
   strip_fresh_blocks() {
       local infile="$1" outfile="$2" used="$3" f script=""
       for f in BANNER INTERSTITIAL REWARDED; do
           if printf '%s\n' $used | grep -qx "$f"; then
               script="$script
/__FMT_${f}_BEGIN__[[:space:]]*\$/d
/__FMT_${f}_END__[[:space:]]*\$/d"
           else
               script="$script
/__FMT_${f}_BEGIN__/,/__FMT_${f}_END__/d"
           fi
       done
       sed "$script" "$infile" > "$outfile"
   }
   ```

3. **Optional namespace wrap:** the fresh templates are bare (no namespace). When `NAMESPACE` is non-empty, wrap every generated file's body in `namespace <NAMESPACE>\n{\n … \n}` so the per-format providers and the bootstrap resolve each other within one namespace. When `NAMESPACE` is empty, write the files as-is.

After stripping, `MeticaAdProvider.cs` must contain no `__FMT_` residue (verify with `grep -L __FMT_`).

**Hard correctness invariants** (validator-enforced, restated here for clarity):

- Exactly one `MeticaSdk.Initialize(` call site across the generated files (it lives in `MeticaAdProvider.cs`; per-format providers never call `Initialize`).
- Both `MeticaSdk.Ads.SetHasUserConsent` and `MeticaSdk.Ads.SetDoNotSell` appear **before** `MeticaSdk.Initialize` in source order **in `MeticaAdProvider.cs`** (same file — the per-format helpers carry no privacy/init calls).
- For each format in `$FORMATS`: the per-format provider subscribes at minimum `OnAdLoadSuccess` and `OnAdLoadFailed` (the templates subscribe the full set with a comment per callback).
- If `$FORMATS` contains `rewarded`: `MeticaRewardedProvider` subscribes `OnAdRewarded`.
- Every `Load*("…")` call has a matching `Show*("…")` in the same per-format provider file (each provider exposes both `Load` and `Show`).

After writing, run `mkdir -p "$OUT_DIR"` first (the agent uses the Bash tool — Write does not auto-create directories). Confirm the files exist with `ls -la "$OUT_DIR"` and print `Generated: $OUT_DIR (formats: $FORMATS)`.

Gradle / manifest edits scoped to MeticaSDK additions only are also TODO; Unity-side `.unitypackage` import handles most of it.

### Step 6 — Validator (fresh subagent context, always)

Invoke `@agent-metica-unity-validator` with the project path and the chosen mode. Concretely, the wrapped bash command is:

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

When validator returned **PASS**, emit the standard summary only, optionally followed by reminders if `API_KEY` / `APP_ID` / `MAX_SDK_KEY` placeholders were used.

In **side-by-side mode**, the PASS summary must also include:

1. **Max-callsite outcome** — if the user approved the refactor, the count of files edited; otherwise the inventory as an action checklist.
2. **Format coverage** — the set of per-format provider files generated (`MeticaBannerProvider.cs` / `MeticaInterstitialProvider.cs` / `MeticaRewardedProvider.cs`). For formats not generated, the matching `IAdService` methods on `MeticaAdProvider` are NO-OP stubs — re-run with `FORMATS=…` to add a format later.
3. **Rollout-config wiring status** — report which remote-config provider was detected and how `RolloutDecisionFunc` was wired:

    - `firebase` / `unity-remote-config` → `✓ AdServiceRouter.RolloutDecisionFunc is auto-wired in MeticaRolloutBinding.cs against <provider>, key "<REMOTE_CONFIG_KEY>". Confirm the key exists in your remote-config dashboard before shipping.`
    - `gameanalytics` → `✓ AdServiceRouter.RolloutDecisionFunc is auto-wired in MeticaRolloutBinding.cs against GameAnalytics A/B, matching variant ID "<REMOTE_CONFIG_KEY>". Confirm that variant ID exists in your GameAnalytics A/B test, and note that GetABTestingId() is empty until A/B data is received (cold-start users fall into the MaxSdk cohort).`
    - `appmetrica` → `⚠ AppMetrica detected. MeticaRolloutBinding.cs ships as a TODO stub with an AppMetrica-flavoured example because the remote-config accessor varies across SDK versions. Wire it manually against your installed AppMetrica SDK version.`
    - `none` → `⚠ No remote-config provider detected. MeticaRolloutBinding.cs ships as a TODO stub with one-liner examples for Firebase, AppMetrica, Unity Remote Config, and GameAnalytics — uncomment whichever you use.`

    In all cases warn the user **not** to hard-code `useMeticaSdk = true` in the inspector for production builds — the field is a dev fallback only.

4. **Manual steps remaining** — anything the user still needs to do (replace placeholder keys, create the `<REMOTE_CONFIG_KEY>` parameter / variant in their remote-config dashboard, choose `SetHasUserConsent` value per their compliance posture, etc.).

## Hard rules

- Never modify any file under `Assets/MaxSdk/` or any existing Max integration code in side-by-side mode.
- Privacy calls (`SetHasUserConsent`, `SetDoNotSell`) **must** precede `MeticaSdk.Initialize` and live in the **same file**.
- Reuse the existing Max ad unit IDs for MeticaSDK (per migration guide).
- Sub-agent invocations (compat-checker, validator) **must** be in fresh subagent contexts — never share your reasoning context with them.
- If `$PLUGIN_DIR` is empty after running `resolve-plugin-dir.sh`, abort. Never run scripts with relative paths.

## References

- `../../references/max-vs-metica-2.4.0-api.md` — API parity table (MaxSdk ↔ MeticaSdk).
- `../../scripts/templates/sidebyside/*.cs.tmpl` — verbatim templates for the side-by-side adapter files.
- `../../agents/contracts.md` — sub-agent JSON schemas and extraction regex.

## Phase 4 follow-ups

- **4b:** Fresh-mode codegen — bootstrap script + direct callsites.
- **4c:** Side-by-side codegen — `IAdService` / `MeticaAdProvider` (+ per-format providers) / `AdServiceRouter` taken verbatim from migration guide.
- **4d:** Robust orchestration — full failure handling, plan-mode harness verification, optional `--import` for Unity headless.
