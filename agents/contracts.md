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

## `validator/1.0.0`-adjacent note: mode is self-detected

There is no mode-detection contract. Mode is derived inline — by the integrator during discovery (Step 2) and by the validator from `HAS_MAX` — using the same rule (any cleaned `MaxSdk.` reference → `straight-swap`, else `fresh`). See "Retired contracts" below.

---

## Max-callsite inventory (no JSON contract)

The integrator scans for MaxSdk callsites directly via the Bash tool (using `grep` piped through `scripts/lib/clean-cs.awk` to ignore matches inside string literals and comments) and reasons over each hit inline. There is no JSON contract for this step — the inventory lives in the agent's reasoning, not in a structured artifact. See `agents/unity-integrator.md` (Step 5, straight-swap branch) for the canonical scan snippet.

---

## `validator/1.0.0`

**Allowed values:**
- `status`: `PASS`, `FAIL`
- `mode`: `fresh`, `straight-swap`, `unknown`
- `warnings`: array of human-readable warning strings. Currently always emitted as `[]`; reserved for future non-blocking advisories.
- `checks[].level`: `PASS`, `FAIL`, `ADVISORY`
- `checks[].rule`: short snake_case identifier (e.g. `privacy_before_init`, `init_count`, `rewarded_callbacks_subscribed`).
- `checks[].location`: `<relative_path>:<line>` or `""` when scope-wide.
- `checks[].detail`: one-line message describing what was found.

**Rules emitted** (see `scripts/validate-integration.sh` for exact conditions):

- `init_count` — exactly one `MeticaSdk.Initialize(`.
- `privacy_before_init` — both privacy calls before `Initialize` (same-file ordering in both modes).
- `<format>_callbacks_subscribed` — for each used format (banner, interstitial, rewarded, mrec), `OnAdLoadSuccess` + `OnAdLoadFailed` subscribed.
- `rewarded_reward_callback` — when rewarded is used, `OnAdRewarded` subscribed.
- `<format>_load_show_parity` — every Load has a matching Show (banner, interstitial, rewarded, mrec).
- `interstitial_reload_on_hidden` / `rewarded_reload_on_hidden` — FAIL when the format is used but `OnAdHidden` is not subscribed.
- `interstitial_show_ready_guard` / `rewarded_show_ready_guard` — ADVISORY when `Show` is called without an `IsReady` check.
- `revenue_callback_subscribed` — ADVISORY.
- `placeholder_ids_replaced` — FAIL when `"YOUR_METICA_API_KEY"` / `"YOUR_METICA_APP_ID"` / `"YOUR_MAX_SDK_KEY"` / `"REPLACE_ME"` appears as a **string literal value** in source (comments stripped via `scripts/lib/strip-comments.awk`; the regex requires surrounding `"..."` so a user constant *named* `YOUR_METICA_API_KEY` holding a real value does not false-positive).
- `user_id_not_test_value` — FAIL when the 3rd positional arg of `MeticaInitConfig(api, app, userId)` is `null`, empty string, a test/debug/dummy/placeholder string (matched as a delimited word — `-`/`_` boundaries or quote anchors — so legitimate ids like `"contest-user-42"` or `"latest-build"` do not false-positive), or a digits-only string. Handles multi-line constructor calls via `scripts/lib/check-init-userid.awk`. The check's outer collector is string-aware, so a test value containing `(` or `)` (`"test)hacker"`) cannot bypass the check. Object-initializer form (`new MeticaInitConfig { UserId = … }`) is a known gap.
- `mrec_callbacks_subscribed` / `mrec_load_show_parity` — same shape as the banner/interstitial/rewarded rules. Note the SDK casing: `MeticaSdk.Ads.LoadMrec` / `MeticaAdsCallbacks.Mrec.*` (lowercase `r`).
- `interstitial_show_failed_subscribed` / `rewarded_show_failed_subscribed` — FAIL when the format is used but `OnAdShowFailed` is not subscribed. Per the docs.metica.com Unity SDK example, both Interstitial and Rewarded subscribe `OnAdShowFailed` (signature `Action<MeticaAd, MeticaAdError>`). Without it the canonical reload-on-hidden loop stalls on the first show-failure: `OnAdHidden` does NOT fire after a show-fail, so the next ad is never loaded.

**Status rule:** `status = "FAIL"` if any check has `level: FAIL` OR top-level `error != null`. `ADVISORY` does not affect status.

**Concrete example:**

```json
{
  "schema": "validator/1.0.0",
  "status": "FAIL",
  "mode": "straight-swap",
  "error": null,
  "warnings": [],
  "checks": [
    { "rule": "init_count",                     "location": "Assets/Scripts/Metica/MeticaAdService.cs:14",  "level": "PASS",     "detail": "MeticaSdk.Initialize called exactly once." },
    { "rule": "privacy_before_init",            "location": "Assets/Scripts/Metica/MeticaAdService.cs:14",  "level": "PASS",     "detail": "SetHasUserConsent and SetDoNotSell called before Initialize." },
    { "rule": "interstitial_callbacks_subscribed", "location": "",                                          "level": "PASS",     "detail": "" },
    { "rule": "placeholder_ids_replaced",       "location": "Assets/Scripts/Metica/MeticaAdService.cs:18",  "level": "FAIL",     "detail": "Placeholder credential leaked into source (YOUR_* / REPLACE_ME). Replace with real values before shipping." },
    { "rule": "user_id_not_test_value",         "location": "Assets/Scripts/Metica/MeticaAdService.cs:14",  "level": "FAIL",     "detail": "MeticaInitConfig userId argument is a null value (null). Replace with your real user-identity source before shipping." }
  ]
}
```

---

## `integrator` (no JSON contract)

The integrator does not emit JSON — it is the orchestrator. Its final message to the user includes:

1. Mode used (`fresh` | `straight-swap`).
2. SDK version installed.
3. Files created / edited (list).
4. Compat-checker summary (one line).
5. Validator summary (one line + `PASS`/`FAIL`).
6. Rollback command (`git reset --hard pre-metica-integration`) when validator returned `FAIL`.
7. (Straight-swap + remote-config provider detected) Cohort-gating recipe — see `agents/unity-integrator.md` Step 7.

The `pre-metica-integration` git tag is created by the integrator before any file change (see integrator.md, workflow step 4).

### Integrator's reaction to sub-agent results

- `compat-checker.status == BLOCK` → abort, print the `FAIL` rows, exit. Do not prompt to override.
- `compat-checker.status == PASS` with any `WARN` → continue, surface warnings.
- `validator.status == FAIL` → run the **integrator-owned autofix loop** (classify each FAIL as `autofix` / `prompt` / `surface`, apply edits with an anchor re-check, log to `.metica-integration.log`, re-validate; **max 3 iterations**). Only when the loop cannot clear all FAILs (a `surface`-class FAIL remains, or 3 iterations are exhausted) print the rollback command and exit non-zero. Never auto-rollback — rollback stays a *hint*. The validator itself remains **read-only**; the integrator owns all edits and prompts. See `agents/unity-integrator.md` Step 6.5.

---

## Retired contracts

- **`mode-detect/2.x`** — retired in plugin v1.0. `scripts/detect-mode.sh` was deleted and the explicit mode-detect step removed; mode is now a *property* derived inline (integrator discovery Step 2; validator from `HAS_MAX`), not a sub-agent contract. No deprecation alias — the script and its `run-mode-tests.sh` / `mode-fixtures/` are gone. The validator still emits a `mode` field (`fresh`/`straight-swap`/`unknown`) as a property of its result, but nothing branches on a mode *contract* anymore.

## Versioning policy

- Bump minor (`1.0.0` → `1.1.0`) when adding optional fields. Orchestrator must remain backward-compatible.
- Bump major (`1.0.0` → `2.0.0`) when removing or renaming required fields. Orchestrator and producers update in lockstep.
- The orchestrator declares accepted majors in its agent spec (currently `compat-checker/1.x`, `validator/1.x`).
