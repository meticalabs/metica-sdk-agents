# Sub-agent output contracts

Every sub-agent in this plugin emits a final fenced JSON block. The orchestrator parses the JSON, never the surrounding prose.

## Parsing rules

- Wrap the JSON in a fenced ```` ```json ```` block.
- The block must be the **last** ```` ```json ```` block in the message. The orchestrator extracts via regex: `(?s)```json\s*(.*?)\s*```(?![\s\S]*```json)`.
- Each object carries a `"schema"` field with a plain stable name (`compat-checker`, `validator`). When a contract's JSON changes, update this doc in the same commit.
- Unknown fields are ignored. Missing required fields fail parsing.
- All string fields may be empty (`""`); use `null` only where explicitly allowed.

## Vocabulary (consistent across all contracts)

- `status` — one of `PASS`, `WARN`, `BLOCK`, `FAIL` (per-contract subset documented below).
- `level` — one of `PASS`, `WARN`, `FAIL`, `UNKNOWN`, `ADVISORY` (per-contract subset documented below).
- Top-level `error` is set when the agent could not complete (broken project, missing inputs). When `error` is non-null, `status` must be `FAIL` (validator) or `BLOCK` (compat-checker), and `checks` may be empty.

---

## `compat-checker`

The producer is now **agent prose** (`agents/unity-compat-checker.md`) — the agent reads the
project's marker files and `metica-versions.yaml` and reasons about each check. The JSON
shape below is unchanged, so the orchestrator's parsing is unaffected.

**Allowed values:**
- `status`: `PASS`, `BLOCK`
- `checks[].id`: `unity`, `java`, `max`, `android_api`, `gradle`, `scripting_backend`, `metica_sdk`
- `checks[].level`: `PASS`, `WARN`, `FAIL`, `UNKNOWN`
- `target_sdk`: SDK version string from `metica-versions.yaml`
- `detected`: detected version/value string, or `null` if detection failed (then `level: UNKNOWN`).
- `required`: human-readable constraint, e.g. `>=2021.3`.
- `hint`: required when `level` is `WARN` or `FAIL`; one-line remediation. Empty otherwise.

**Status rule:** `status = "BLOCK"` if any check has `level: FAIL` OR top-level `error != null`. Otherwise `status = "PASS"`. `WARN` and `UNKNOWN` do not block but surface to the user.

**Concrete example:**

```json
{
  "schema": "compat-checker",
  "status": "BLOCK",
  "target_sdk": "2.4.0",
  "error": null,
  "warnings": [],
  "checks": [
    { "id": "unity",             "detected": "2020.3.24f1", "required": ">=2021.3", "level": "FAIL",    "hint": "Upgrade Unity to 2021.3 LTS or later." },
    { "id": "java",              "detected": "11.0.21",     "required": ">=11",     "level": "PASS",    "hint": "" },
    { "id": "max",               "detected": "8.6.3",       "required": ">=8.2.0",  "level": "PASS",    "hint": "" },
    { "id": "android_api",       "detected": "23",          "required": ">=23",     "level": "PASS",    "hint": "" },
    { "id": "gradle",            "detected": null,          "required": ">=7.0",    "level": "UNKNOWN", "hint": "Custom Gradle template not present; using Unity default." },
    { "id": "scripting_backend", "detected": "Mono",        "required": "IL2CPP|Mono", "level": "PASS", "hint": "" },
    { "id": "metica_sdk",        "detected": "2.4.0",       "required": ">=2.4.0",  "level": "PASS",    "hint": "" }
  ]
}
```

---

## Max-callsite inventory (no JSON contract)

The integrator scans for MaxSdk callsites directly via the Bash tool (`grep` to locate, then `Read` each hit's context to drop comment/string matches) and reasons over each hit inline; the inventory lives in the agent's reasoning. See `agents/unity-integrator.md` (Step 5) for the canonical scan snippet.

---

## `validator`

The producer is **agent prose** (`agents/unity-validator.md`): a single pass in which the
validator reads the project's code, reasons about every rule, and cites the lines that prove
each verdict. The one thing it shells out for is the Unity batch compile
(`scripts/compile-check.sh`) behind `compiles_cleanly`. Its semantic verdicts gate `status`
like any other check.

**Allowed values:**
- `status`: `PASS`, `FAIL`
- `warnings`: array of human-readable warning strings. Currently always emitted as `[]`.
- `checks[].level`: `PASS`, `FAIL`, `ADVISORY`, `WARN` (`WARN` is a non-blocking "could not verify" signal, used by `compiles_cleanly` when the compile is skipped; like `ADVISORY` it does not affect `status`).
- `checks[].rule`: short snake_case identifier (e.g. `privacy_before_init`, `init_count`, `rewarded_callbacks_subscribed`).
- `checks[].location`: `<path>:<line>` (or `""` when scope-wide). The path component is **opaque** — pass it through to the user verbatim; do not parse or join against it. To separate the line number, split on the **last** `:` (the path itself may contain a colon — e.g. a Windows drive letter `C:\...` — but the line number never does, so the last `:` is the right boundary).
- `checks[].detail`: one-line message describing what was found.
- `checks[].evidence` *(optional)*: array of `{ "file", "line", "snippet", "role" }` where `role` ∈ `entry` | `hop` | `terminal`. **Required on the behavioral rules; a PASS on one needs ≥2 entries forming an entry→terminal chain.** The validator confirms each citation by reading the file at the cited line before trusting it; a citation that does not resolve forces the rule off PASS.
- `checks[].confidence` *(optional)*: `"high"` | `"low"`.
- `checks[].reasoning` *(optional)*: one short paragraph (≤4 sentences) on the behavioral checks.
- `checks[].unresolved` *(optional)*: array of edge descriptions the validator could not follow (DI, reflection, `SendMessage`, missing subscriber). When non-empty, the check is `ADVISORY`, not a blind `FAIL`.

**Rules emitted** (full descriptions in `agents/unity-validator.md`):

- `init_count` — exactly one `MeticaSdk.Initialize(`.
- `privacy_before_init` — privacy calls before `Initialize` (same-file ordering). FAIL when present-but-after-`Initialize`; **ADVISORY** (not FAIL) when absent and a CMP/UMP is detected (consent may be CMP-managed — confirm it reaches both paths before init); FAIL when absent with no CMP.
- `sdk_calls_on_main_thread` — **behavioral, FAIL-capable**. Every `MeticaSdk` `Initialize`/`Load*`/`Show*`/`Create*` must run on the Unity main thread (the SDK captures the `SynchronizationContext` at the call site). **FAIL** a call provably reachable only from an off-main context (CMP/consent callback, AppLovin/Amazon callback, `Task`/`ThreadPool`/`new Thread`, `async` after `ConfigureAwait(false)`) with no marshal to the main thread; **ADVISORY** when the calling thread can't be proven. Validator reads the vendored callback proxies to cite the mechanism. `Initialize` specifically: the init-completion callback (`OnInitialized`) marshals back to the `SynchronizationContext` captured **at the `Initialize` call site**, so kicking init off from a consent/UMP callback or a `Task` continuation can make it run off-main or never fire (no ads / forced-holdout); game code must also not consume a callback's payload from a background thread.
- `<format>_callbacks_subscribed` — for each used format (banner, interstitial, rewarded, mrec), `OnAdLoadSuccess` + `OnAdLoadFailed` subscribed.
- `rewarded_reward_callback` — when rewarded is used, `OnAdRewarded` subscribed.
- `<format>_load_show_parity` — every Load has a matching Show (banner, interstitial, rewarded, mrec).
- `interstitial_reload_on_hidden` / `rewarded_reload_on_hidden` — **behavioral**: reload reachable from the `OnAdHidden` subscriber, *following indirection* (named helpers, flag-driven `Update`/coroutine, events, async continuations) — not just textual presence of `OnAdHidden`.
- `interstitial_show_ready_guard` / `rewarded_show_ready_guard` — **behavioral**: every call path reaching `Show<Format>` first observes `IsReady` for the same id (ADVISORY if not).
- `<format>_show_after_init` (banner, interstitial, rewarded, mrec) — **behavioral**: every call path reaching `Show<Format>` (incl. `ShowBanner`/`ShowMrec`) is only reachable **after** MeticaSDK init has *completed* (the `OnInitialized` callback fired — not when `MeticaSdk.Initialize` was merely *called*). Accepted gates: the show is downstream of `OnInitialized`, guarded by an init-complete flag set inside it, or — interstitial/rewarded only — guarded by `IsReady` (banner/MRec have no `IsReady`). ADVISORY when a show can run before init completes or no gate is provable; never affects `status`.
- `<format>_load_after_init` (banner, interstitial, rewarded, mrec) — **behavioral**: every call path reaching `Load<Format>` (and `Create<Format>` for banner/mrec) is only reachable **after** init has *completed*. Accepted proof: the load originates from the `OnInitialized` path — directly (the canonical `Init<Format>` is called inside `OnInitialized`) or via a reload/backoff-retry chain rooted in a post-init load. ADVISORY when a load can run before init completes (e.g. issued from `Awake()` / `Start()`) or no gate is provable; never affects `status`.
- `placement_ids_match` — **behavioral**: per format, the placement/ad-unit id passed to `Load*` is provably the same value as the one passed to `Show*` across all call paths.
- `smartfloors_analytics_only` — **behavioral, FAIL-capable** (project-wide). The Smart Floors user group / `IsForcedHoldout` is analytics-only; trial and holdout must behave identically. **FAIL** when a read of `response.SmartFloors.UserGroup` / `.IsForcedHoldout` (or a stored copy) gates an ad-control decision (ad-unit selection/branch, a `Load*`/`Show*` gate, or an ad-lifecycle state switch), and when a guard branches on a returned `ad.adUnitId == / != <configured>`. PASS when the group is only logged/synced to an analytics property or never read; `ADVISORY` (with `unresolved`) when the flow can't be traced — never a blind FAIL. Encodes a real production regression (group-aware ad logic dropped trial-group impressions in two shipped games).
- `load_dedup_flag_wedge` — **behavioral, ADVISORY** (project-wide). Flags a self-managed ad state flag (`isLoading` / `isShow`) gating `Load`/`Show` that isn't cleared on every terminal event (load fail, show fail, hidden): redundant (the SDK dedups) and wedge-prone (a missed terminal callback leaves it stuck, blocking all later load/show/reload/retry). Recommendation only; never FAIL, never gates `status`.
- `banner_setter_after_create` / `mrec_setter_after_create` — **behavioral, FAIL-capable**. Every `MeticaSdk.Ads.SetBanner*` / `SetMrec*` for an `adUnitId` must be preceded on every path by `CreateBanner`/`CreateMrec` for the same id; a pre-create setter silently no-ops (wrapper warns `BANNER not found for adUnitId`), the bug that disabled `adaptive_banner=true` in a shipped game. FAIL when a setter precedes its create; ADVISORY (with `unresolved`) when ordering can't be traced. On **SDK ≥ 2.4.2 (Android)** banner/MRec creation and display are separate steps (canonical lifecycle `Create` → `Show`; the SDK loads/auto-refreshes, so an explicit `Load` is only for manual refresh), so the same create-precedence covers a banner/MRec `Show`/`Load`: FAIL when one isn't preceded on every path by a `Create` for the same id.
- `interstitial_setter_after_create` / `rewarded_setter_after_create` — **behavioral**. Same shape for `SetInterstitial*` / `SetRewardedAd*` extra-parameter setters; the validator **reads the vendored SDK** to confirm cache-vs-drop semantics — **FAIL** a pre-load setter when the source shows the param is dropped, PASS when cached, `ADVISORY` (`confidence: low`, "verify with the team") when unconfirmable.
- `threepa_forwarder_in_revenue_paid` — **behavioral, FAIL-capable**. When a 3PA SDK (Adjust, Firebase Analytics, AppsFlyer, AppMetrica) is present, its ad-revenue forwarding call must live inside a `MeticaAdsCallbacks.<Format>.OnAdRevenuePaid` handler. **FAIL** when found inside `OnAdHidden` / a dismissal hook / any other lifecycle hook (revenue then reports only on dismissal — click-through users lose every event). **ADVISORY** when correctly inside `OnAdRevenuePaid` (dispatch still rides Unity's main thread via `SynchronizationContext.Post`, so click-through-no-return may still lose events).
- `format_path_symmetry` — **behavioral, ADVISORY**. Interstitial vs rewarded should be structurally symmetric (load-failure retry, already-loaded fast path, reload-on-hidden, callback parity); an unexplained asymmetry is surfaced as a suspect.
- `callbacks_fire_on_every_path` — **behavioral, FAIL-capable**. Every stored ad callback must fire exactly once on every terminal path (already-loaded fast path, load fail, show fail, hidden-without-reward). **FAIL** a callback provably parked-and-never-fired on a reachable path (UI hangs → "looks slow") or leaking stale into the next show; `ADVISORY` when flow is untraceable.
- `init_callback_all_paths` — **behavioral, FAIL-capable**. `OnInitialized` must fire on every init path incl. early-return / empty-config (first loads run inside it), and auction-affecting extra params must be set before it fires. **FAIL** an init path that returns without invoking the callback; `ADVISORY` if untraceable.
- `retry_ownership` — **behavioral**. **FAIL** when `disable_auto_retries` (or equivalent) is set and no client retry path exists; **ADVISORY** for dead retry logic (a counter declared/reset but never incremented or read).
- `dead_code_signal` — **behavioral, ADVISORY**. A field/list carefully populated but never read (or a method never called) likely marks a call lost in a rewrite — surfaced to flag, not delete.
- `revenue_callback_subscribed` — ADVISORY.
- `placeholder_ids_replaced` — FAIL when `"YOUR_METICA_API_KEY"` / `"YOUR_METICA_APP_ID"` / `"YOUR_MAX_SDK_KEY"` / `"REPLACE_ME"` appears as a **string-literal value** in source. A constant merely *named* `YOUR_METICA_API_KEY` holding a real value does not false-positive.
- `user_id_not_test_value` — the 3rd positional arg of `MeticaInitConfig(api, app, userId)`. **PASS** `null` / empty string (MeticaSDK auto-generates a stable per-device userId — a valid production setting) and real ids; **FAIL** a hardcoded test literal (`"test"` / `"test-user"` / `"debug"` / `"dummy"` / a digits-only string / any value containing `test`/`debug`/`dummy`, matched at delimiter boundaries so `"contest-user-42"` doesn't false-positive); **ADVISORY** for the Metica debug overrides `metica-force-holdout` / `metica-force-test` / `metica-force-trial`. Handles multi-line constructor calls.
- `mrec_callbacks_subscribed` / `mrec_load_show_parity` — same shape as the banner/interstitial/rewarded rules. Note the SDK casing: `MeticaSdk.Ads.LoadMrec` / `MeticaAdsCallbacks.Mrec.*` (lowercase `r`).
- `interstitial_show_failed_subscribed` / `rewarded_show_failed_subscribed` — FAIL when the format is used but `OnAdShowFailed` is not subscribed. Without it the canonical reload-on-hidden loop stalls on the first show-failure: `OnAdHidden` does NOT fire after a show-fail, so the next ad is never loaded.
- `compiles_cleanly` — the authoritative "does this integration actually build" check, delegated to `scripts/compile-check.sh` (Unity batch-mode — the only compiler that sees Unity's assemblies, asmdefs and scripting defines). **PASS** when the project compiles with no `error CS####`; **one FAIL per compile error** with `location` = `<file>:<line>` and `detail` carrying the `CS####: message` (catches the docs-transcription class — unqualified nested enum, wrong property casing — without bespoke per-bug rules); **WARN** (non-blocking) when the check is skipped (no Unity located / `METICA_SKIP_COMPILE=1`) or Unity could not complete (license/timeout/crash). On by default; the plugin's own test suites export `METICA_SKIP_COMPILE=1` so synthetic fixtures never launch Unity.
- `max_api_use_metica` — emits **one row per match** for every Max-API call site whose replacement is documented in `references/max-metica-api-map.tsv` with `kind=rename` or `kind=signature-change`. The scan covers all non-exempt namespaces — `MaxSdk.`, `MaxSdkBase.`, `MaxSdkCallbacks.`, `MaxCmpService.` (not just `MaxSdk.`; `MaxSdkUtils.*` is exempt). `level` is **FAIL** in any file that also references `MeticaSdk.` (Metica owns the live `AppLovinSdk` instance, so the direct `MaxSdk.*` call is dead) and **ADVISORY** in a pure-Max file (e.g. a side-by-side `AdManager.cs` wrapper). `detail` carries the suggested replacement. Single **PASS** row when no matches anywhere.
- `max_api_unsupported` — companion rule for `kind=drop` rows (no MeticaSdk equivalent — App Open Ads, segment targeting, expanded/collapsed banner callbacks, etc.). Same FAIL/ADVISORY/PASS model. `detail` advises removing the call or isolating it behind a Max-only code path. `MaxSdkUtils.*` is exempt (stateless helpers, mix-safe).

**Status rule:** `status = "FAIL"` if top-level `error != null` or any check has `level: "FAIL"`. `ADVISORY` and `WARN` never affect status.

**Concrete example:**

```json
{
  "schema": "validator",
  "status": "FAIL",
  "error": null,
  "warnings": [],
  "checks": [
    { "rule": "init_count",               "location": "Assets/Scripts/Metica/MeticaAdService.cs:14", "level": "PASS", "detail": "MeticaSdk.Initialize called exactly once." },
    { "rule": "privacy_before_init",       "location": "Assets/Scripts/Metica/MeticaAdService.cs:14", "level": "PASS", "detail": "SetHasUserConsent and SetDoNotSell called before Initialize." },
    { "rule": "placeholder_ids_replaced",  "location": "Assets/Scripts/Metica/MeticaAdService.cs:18", "level": "FAIL", "detail": "Placeholder credential leaked into source (YOUR_* / REPLACE_ME). Replace with real values before shipping." },
    {
      "rule": "rewarded_reload_on_hidden",
      "location": "Assets/Scripts/Metica/MeticaModule.cs:833",
      "level": "PASS",
      "confidence": "high",
      "evidence": [
        { "file": "Assets/Scripts/Metica/MeticaModule.cs", "line": 833, "snippet": "void RewardedAdsView_OnAdClosed(MeticaAd ad)", "role": "entry" },
        { "file": "Assets/Scripts/Metica/MeticaModule.cs", "line": 838, "snippet": "if (m_IsAutoReload) RestartRewardedCycle();",          "role": "hop" },
        { "file": "Assets/Scripts/Metica/MeticaModule.cs", "line": 712, "snippet": "MeticaSdk.Ads.LoadRewarded(m_Config.rewardedID);",      "role": "terminal" }
      ],
      "reasoning": "OnAdClosed → RestartRewardedCycle → LoadRewarded, guarded by the auto-reload flag set on init. The call chain proves reload is reachable even though no Load appears textually inside the handler.",
      "unresolved": []
    }
  ]
}
```

---

## `integrator` (no JSON contract)

The integrator does not emit JSON — it is the orchestrator. Its final message to the user includes:

1. Whether MaxSDK was present.
2. SDK version installed.
3. Files created / edited (list).
4. Compat-checker summary (one line).
5. Validator summary (one line + `PASS`/`FAIL`).
6. Rollback command (`git reset --hard pre-metica-integration`) **only when the autofix loop cannot clear all FAILs** (a `surface`-class FAIL remains, or 3 iterations are exhausted) — never on a FAIL the loop fixes. See the reaction section below.
7. (MaxSDK present + remote-config provider detected) Cohort-gating recipe — see `agents/unity-integrator.md` Step 7.

The `pre-metica-integration` git tag is created by the integrator before any file change (see integrator.md, workflow step 4).

### Integrator's reaction to sub-agent results

- `compat-checker.status == BLOCK` → abort, print the `FAIL` rows, exit. Do not prompt to override.
- `compat-checker.status == PASS` with any `WARN` → continue, surface warnings.
- `validator.status == FAIL` → run the **integrator-owned autofix loop** (classify each FAIL as `autofix` / `prompt` / `surface`, apply edits with an anchor re-check, log to `.metica-integration.log`, re-validate; **max 3 iterations**). A `compiles_cleanly` FAIL is `surface`-class (a real `CS####` compile error — printed verbatim with `file:line`, not auto-edited). Only when the loop cannot clear all FAILs (a `surface`-class FAIL remains, or 3 iterations are exhausted) print the rollback command and exit non-zero. Never auto-rollback — rollback stays a *hint*. The validator itself remains **read-only**; the integrator owns all edits and prompts. See `agents/unity-integrator.md` Step 6.5.
- A `compiles_cleanly` **WARN** (compile skipped — no Unity located / `METICA_SKIP_COMPILE=1` — or could not complete) is non-blocking: surface it in the final report so the user knows the build was not verified, but it does not trigger the autofix loop or affect status.
- **Behavioral checks** split into two groups by the level they emit:
  - **Gating** (`*_reload_on_hidden`, `placement_ids_match`, `smartfloors_analytics_only`, `banner_setter_after_create` / `mrec_setter_after_create`, `interstitial_setter_after_create` / `rewarded_setter_after_create`, `threepa_forwarder_in_revenue_paid`, `callbacks_fire_on_every_path`, `init_callback_all_paths`, `retry_ownership`, `sdk_calls_on_main_thread`): emit `PASS`/`FAIL`, so they gate `status` like any other check — a `FAIL` triggers the autofix loop, a `PASS` is trusted. **Exception:** `smartfloors_analytics_only`, `threepa_forwarder_in_revenue_paid`, `callbacks_fire_on_every_path`, `init_callback_all_paths`, `retry_ownership`, and `sdk_calls_on_main_thread` FAILs are **`surface`-class** (removing group-aware ad logic, relocating a 3PA forwarder, or fixing a missed-callback / init / retry / off-main-thread path is game-logic redesign, not a line edit — surfaced for a human); the setter-ordering FAILs are autofix-eligible only when create and setter sit in the same method (else `surface`). A behavioral FAIL with non-empty `unresolved` (the validator was unsure) is also **`surface`-class** — never fed to the autofix loop; a human decides.
  - **ADVISORY-only** (`*_show_ready_guard`, `*_show_after_init`, `*_load_after_init`, `load_dedup_flag_wedge`, `format_path_symmetry`, `dead_code_signal`): always emit `level: ADVISORY`, so per the Status rule above they surface in the report but never affect `status` and never trigger the autofix loop. (`retry_ownership` is ADVISORY for the dead-counter case, FAIL only when auto-retry is disabled with no client retry.)

  Surface each verdict's `evidence`/`reasoning` in the report regardless of group.

---

## Changing a contract

To change a contract, edit the producing sub-agent's prose and this doc **in the same commit**, keeping the two in lockstep. The plugin release version (`.claude-plugin/plugin.json` + `marketplace.json`) is the only semver in the repo — see the version-bump convention in `CLAUDE.md`.
