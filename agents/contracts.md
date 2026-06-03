# Sub-agent output contracts

Every sub-agent in this plugin emits a final fenced JSON block. The orchestrator parses the JSON, never the surrounding prose.

## Parsing rules

- Wrap the JSON in a fenced ```` ```json ```` block.
- The block must be the **last** ```` ```json ```` block in the message. The orchestrator extracts via regex: `(?s)```json\s*(.*?)\s*```(?![\s\S]*```json)`.
- Schemas carry a version string `<name>/<major>.<minor>.<patch>`. The orchestrator accepts any minor/patch within an accepted major. Reject unknown majors.
- Unknown fields are ignored. Missing required fields fail parsing.
- All string fields may be empty (`""`); use `null` only where explicitly allowed.

## Vocabulary (consistent across all contracts)

- `status` — one of `PASS`, `WARN`, `BLOCK`, `FAIL` (per-contract subset documented below).
- `level` — one of `PASS`, `WARN`, `FAIL`, `UNKNOWN`, `ADVISORY` (per-contract subset documented below).
- Top-level `error` is set when the agent could not complete (broken project, missing inputs). When `error` is non-null, `status` must be `FAIL` (validator) or `BLOCK` (compat-checker), and `checks` may be empty.

---

## `compat-checker/1.0.0`

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
  "schema": "compat-checker/1.0.0",
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

The integrator scans for MaxSdk callsites directly via the Bash tool (using `grep` piped through `scripts/lib/clean-cs.awk` to ignore matches inside string literals and comments) and reasons over each hit inline. There is no JSON contract for this step — the inventory lives in the agent's reasoning, not in a structured artifact. See `agents/unity-integrator.md` (Step 5) for the canonical scan snippet.

---

## `validator/1.2.0`

The validator is a **two-phase** producer (see `agents/unity-validator.md`): a deterministic floor (`scripts/validate-integration.sh`, `engine: "grep"`) plus an in-context **semantic-adjudication** pass (`engine: "llm-adjudicator"`) that reasons over the project's code for the behavioral rules grep gets wrong. Both phases merge into one JSON object. 1.2.0 adds only **optional** fields (additive, backward-compatible) on top of 1.1.0 — consumers pinning `validator/1.x` need no change.

**Allowed values:**
- `status`: `PASS`, `FAIL`
- `warnings`: array of human-readable warning strings. Currently always emitted as `[]`; reserved for future non-blocking advisories.
- `checks[].level`: `PASS`, `FAIL`, `ADVISORY`, `WARN` (`WARN` is a non-blocking signal — "could not verify" for `compiles_cleanly` when the compile is skipped, or "potential risk" for `trial_holdout_integrity`; like `ADVISORY` it does not affect `status`).
- `checks[].rule`: short snake_case identifier (e.g. `privacy_before_init`, `init_count`, `rewarded_callbacks_subscribed`).
- `checks[].location`: `<relative_path>:<line>` or `""` when scope-wide.
- `checks[].detail`: one-line message describing what was found.
- `checks[].engine` *(1.2.0, optional)*: `"grep"` (deterministic floor) or `"llm-adjudicator"` (semantic pass). Absent ⇒ treat as `"grep"`.
- `checks[].evidence` *(1.2.0, optional)*: array of `{ "file", "line", "snippet", "role" }` where `role` ∈ `entry` | `hop` | `terminal`. **Required on `llm-adjudicator` checks; a PASS on a behavioral rule needs ≥2 entries forming an entry→terminal chain.** Every citation is verified by `scripts/check-citation.sh` (opens the file at the cited line, confirms the snippet); a citation that does not resolve forces the rule to `FAIL`.
- `checks[].confidence` *(1.2.0, optional)*: `"high"` | `"low"`.
- `checks[].reasoning` *(1.2.0, optional)*: one short paragraph (≤4 sentences) on `llm-adjudicator` checks.
- `checks[].unresolved` *(1.2.0, optional)*: array of edge descriptions the adjudicator could not follow (DI, reflection, `SendMessage`, missing subscriber). When non-empty, the check is `ADVISORY`, not a blind `FAIL`.
- `engine_version` *(1.2.0, optional, top-level)*: string identifying the adjudicator prompt/model revision (e.g. `"semantic-2026-06-03"`), so reruns are diffable.

**Shadow phase (current, 1.2.0):** the deterministic floor + the Phase 1 grep verdicts for the behavioral rules (`*_reload_on_hidden`, `*_show_ready_guard`) **remain authoritative for `status`**. The `llm-adjudicator` checks are surfaced and disagreements with grep are logged (`tests/semantic-fixtures/`), but do not yet flip `status`. This is the calibration phase before promoting the semantic verdicts to canonical (see *Promotion* below).

**Rules emitted** (see `scripts/validate-integration.sh` for the floor; `agents/unity-validator.md` Phase 2 for the adjudicated set):

- `init_count` — exactly one `MeticaSdk.Initialize(`.
- `privacy_before_init` — both privacy calls before `Initialize` (same-file ordering; uniform regardless of MaxSDK presence).
- `<format>_callbacks_subscribed` — for each used format (banner, interstitial, rewarded, mrec), `OnAdLoadSuccess` + `OnAdLoadFailed` subscribed.
- `rewarded_reward_callback` — when rewarded is used, `OnAdRewarded` subscribed.
- `<format>_load_show_parity` — every Load has a matching Show (banner, interstitial, rewarded, mrec).
- `interstitial_reload_on_hidden` / `rewarded_reload_on_hidden` — **adjudicated (1.2.0)**: reload reachable from the `OnAdHidden` subscriber, *following indirection* (named helpers, flag-driven `Update`/coroutine, events, async continuations) — not just textual presence of `OnAdHidden`. Phase 1 still emits the grep version (`engine: "grep"`) during shadow.
- `interstitial_show_ready_guard` / `rewarded_show_ready_guard` — **adjudicated (1.2.0)**: every call path reaching `Show<Format>` first observes `IsReady` for the same id (ADVISORY if not). Phase 1 still emits the grep version during shadow.
- `placement_ids_match` *(1.2.0, adjudicated)* — per format, the placement/ad-unit id passed to `Load*` is provably the same value as the one passed to `Show*` across all call paths.
- `trial_holdout_integrity` *(1.2.0, adjudicated)* — judges whether the ad logic could bias or break Metica's SmartFloors Trial/Holdout measurement (mediation bypass on a shared path, ad serving that branches on cohort/`IsForcedHoldout`, hardcoded floor overrides, a userId that rotates per launch, re-init that reassigns the cohort, missing revenue attribution). **Emission is conditional: the check appears in `checks[]` only when its `level` is `WARN` or `FAIL` — when the ad logic is clean it is omitted entirely (no PASS entry).** `FAIL` for clear corruption, `WARN` for potential/untraceable risk. Like all `llm-adjudicator` checks it carries `evidence`/`reasoning` and does not affect `status` during shadow.
- `revenue_callback_subscribed` — ADVISORY.
- `placeholder_ids_replaced` — FAIL when `"YOUR_METICA_API_KEY"` / `"YOUR_METICA_APP_ID"` / `"YOUR_MAX_SDK_KEY"` / `"REPLACE_ME"` appears as a **string literal value** in source (comments stripped via `scripts/lib/strip-comments.awk`; the regex requires surrounding `"..."` so a user constant *named* `YOUR_METICA_API_KEY` holding a real value does not false-positive).
- `user_id_not_test_value` — FAIL when the 3rd positional arg of `MeticaInitConfig(api, app, userId)` is a test/debug/dummy/placeholder string (matched as a delimited word — `-`/`_` boundaries or quote anchors — so legitimate ids like `"contest-user-42"` or `"latest-build"` do not false-positive) or a digits-only string. **`null` and `""` (empty) are NOT flagged** — the SDK treats empty the same as null and substitutes its own stable id (anonymous mode), so neither is a bug; only values that collapse many users into one identity (corrupting analytics/SmartFloors cohorts) fail. Handles multi-line constructor calls via `scripts/lib/check-init-userid.awk`. The check's outer collector is string-aware, so a test value containing `(` or `)` (`"test)hacker"`) cannot bypass the check. Object-initializer form (`new MeticaInitConfig { UserId = … }`) is a known gap.
- `mrec_callbacks_subscribed` / `mrec_load_show_parity` — same shape as the banner/interstitial/rewarded rules. Note the SDK casing: `MeticaSdk.Ads.LoadMrec` / `MeticaAdsCallbacks.Mrec.*` (lowercase `r`).
- `interstitial_show_failed_subscribed` / `rewarded_show_failed_subscribed` — FAIL when the format is used but `OnAdShowFailed` is not subscribed. Per the docs.metica.com Unity SDK example, both Interstitial and Rewarded subscribe `OnAdShowFailed` (signature `Action<MeticaAd, MeticaAdError>`). Without it the canonical reload-on-hidden loop stalls on the first show-failure: `OnAdHidden` does NOT fire after a show-fail, so the next ad is never loaded.
- `compiles_cleanly` *(added in 1.1.0)* — the authoritative "does this integration actually build" check, delegated to `scripts/compile-check.sh` (Unity batch-mode — the only compiler that sees Unity's assemblies, asmdefs and scripting defines; a raw `csc`/`dotnet` pass would bury real errors in missing-`UnityEngine` noise, so we never fall back to it). **PASS** when the project compiles with no `error CS####`; **one FAIL per compile error** with `location` = `<file>:<line>` and `detail` carrying the `CS####: message` (this is what catches the docs-transcription class from issue #8 — unqualified nested enum, wrong property casing — without bespoke per-bug rules); **WARN** (non-blocking) when the check is skipped because no Unity editor could be located or `METICA_SKIP_COMPILE=1`, or when Unity ran but could not complete (license/timeout/crash). On by default; the plugin's own test suites export `METICA_SKIP_COMPILE=1` so synthetic fixtures never launch Unity.

**Status rule (shadow-aware, 1.2.0):** `status = "FAIL"` if top-level `error != null`, **or** if any check **whose `engine` is not `"llm-adjudicator"`** has `level: FAIL`. During the shadow phase `engine: "llm-adjudicator"` checks **never affect `status`** — even at `level: "FAIL"` — so a run may carry a semantic `FAIL` and still be `status: "PASS"` from the floor; that is intended (the semantic verdict is surfaced for calibration, not gating). `ADVISORY` and `WARN` never affect status. (At promotion to `validator/2.0.0` the qualifier is dropped and the semantic verdicts gate status like any floor check: `status = "FAIL"` if any check is `FAIL`.)

**Concrete example:**

```json
{
  "schema": "validator/1.2.0",
  "status": "FAIL",
  "error": null,
  "engine_version": "semantic-2026-06-03",
  "warnings": [],
  "checks": [
    { "rule": "init_count",                     "location": "Assets/Scripts/Metica/MeticaAdService.cs:14",  "level": "PASS",     "engine": "grep", "detail": "MeticaSdk.Initialize called exactly once." },
    { "rule": "privacy_before_init",            "location": "Assets/Scripts/Metica/MeticaAdService.cs:14",  "level": "PASS",     "engine": "grep", "detail": "SetHasUserConsent and SetDoNotSell called before Initialize." },
    { "rule": "placeholder_ids_replaced",       "location": "Assets/Scripts/Metica/MeticaAdService.cs:18",  "level": "FAIL",     "engine": "grep", "detail": "Placeholder credential leaked into source (YOUR_* / REPLACE_ME). Replace with real values before shipping." },
    {
      "rule": "rewarded_reload_on_hidden",
      "location": "Assets/Scripts/Metica/MeticaModule.cs:833",
      "level": "PASS",
      "engine": "llm-adjudicator",
      "confidence": "high",
      "evidence": [
        { "file": "Assets/Scripts/Metica/MeticaModule.cs", "line": 833, "snippet": "void RewardedAdsView_OnAdClosed(MeticaAd ad)", "role": "entry" },
        { "file": "Assets/Scripts/Metica/MeticaModule.cs", "line": 838, "snippet": "if (m_IsAutoReload) RestartRewardedCycle();",          "role": "hop" },
        { "file": "Assets/Scripts/Metica/MeticaModule.cs", "line": 712, "snippet": "MeticaSdk.Ads.LoadRewarded(m_Config.rewardedID);",      "role": "terminal" }
      ],
      "reasoning": "OnAdClosed → RestartRewardedCycle → LoadRewarded, guarded by the auto-reload flag set on init. Grep shadow FAILed (no Load textually inside the handler); the call chain proves reload is reachable.",
      "unresolved": []
    }
  ]
}
```

**Promotion (planned `validator/2.0.0`):** once the shadow corpus shows the `llm-adjudicator` verdicts are right on grep/LLM disagreements above the agreed bar, the **grep behavioral rules (`*_reload_on_hidden`, `*_show_ready_guard`) are removed** from `scripts/validate-integration.sh` and the semantic verdicts become canonical for `status`. Removing those rules is the breaking change that bumps the **major** (`2.0.0`) — and the orchestrator's accepted-majors set widens to `validator/2.x` in the same release.

---

## `integrator` (no JSON contract)

The integrator does not emit JSON — it is the orchestrator. Its final message to the user includes:

1. Whether MaxSDK was present.
2. SDK version installed.
3. Files created / edited (list).
4. Compat-checker summary (one line).
5. Validator summary (one line + `PASS`/`FAIL`).
6. Rollback command (`git reset --hard pre-metica-integration`) when validator returned `FAIL`.
7. (MaxSDK present + remote-config provider detected) Cohort-gating recipe — see `agents/unity-integrator.md` Step 7.

The `pre-metica-integration` git tag is created by the integrator before any file change (see integrator.md, workflow step 4).

### Integrator's reaction to sub-agent results

- `compat-checker.status == BLOCK` → abort, print the `FAIL` rows, exit. Do not prompt to override.
- `compat-checker.status == PASS` with any `WARN` → continue, surface warnings.
- `validator.status == FAIL` → run the **integrator-owned autofix loop** (classify each FAIL as `autofix` / `prompt` / `surface`, apply edits with an anchor re-check, log to `.metica-integration.log`, re-validate; **max 3 iterations**). A `compiles_cleanly` FAIL is `surface`-class (a real `CS####` compile error — printed verbatim with `file:line`, not auto-edited). Only when the loop cannot clear all FAILs (a `surface`-class FAIL remains, or 3 iterations are exhausted) print the rollback command and exit non-zero. Never auto-rollback — rollback stays a *hint*. The validator itself remains **read-only**; the integrator owns all edits and prompts. See `agents/unity-integrator.md` Step 6.5.
- A `compiles_cleanly` **WARN** (compile skipped — no Unity located / `METICA_SKIP_COMPILE=1` — or could not complete) is non-blocking: surface it in the final report so the user knows the build was not verified, but it does not trigger the autofix loop or affect status.
- **`engine: "llm-adjudicator"` checks (1.2.0, shadow):** do not drive `status` during the shadow phase — `status` follows the deterministic floor + grep behavioral verdicts. Surface the semantic verdict + its `evidence`/`reasoning` in the report, and log grep/LLM disagreements to the calibration corpus. A semantic FAIL with non-empty `unresolved` is **`surface`-class** — never fed to the autofix loop (the model is unsure; a human decides). Tuning how the loop consumes confident semantic FAILs is deferred to a later patch.

---

## Retired contracts

- **`mode-detect/2.x`** — retired in plugin v1.0. `scripts/detect-mode.sh` was deleted along with its `run-mode-tests.sh` / `mode-fixtures/`. There is no "mode" concept anymore: the integrator discovers MaxSDK presence inline (discovery Step 2) and adapts codegen to it; the validator runs uniform checks and emits no mode field.

## Versioning policy

- Bump minor (`1.0.0` → `1.1.0`) when adding optional fields. Orchestrator must remain backward-compatible.
- Bump major (`1.0.0` → `2.0.0`) when removing or renaming required fields. Orchestrator and producers update in lockstep.
- The orchestrator declares accepted majors in its agent spec (currently `compat-checker/1.x`, `validator/1.x`).
