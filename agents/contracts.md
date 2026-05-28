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

## `mode-detect/2.0.0`

Emitted by `scripts/detect-mode.sh`. Consumed by the integrator to choose between fresh-mode and straight-swap codegen.

**Allowed values:**
- `mode`: `fresh`, `straight-swap`
- `signals[<id>].present`: boolean
- `signals[<id>].location`: relative path (or `file:line`); empty when not present

**Decision rule:** two-of-three Max signals present → `straight-swap`, else `fresh`. The script emits the **final mode label** directly — no integrator-side prose interpretation step. When `straight-swap` is selected, Step 2.5's remote-config detection runs in the integrator to drive the Step 7 cohort-gating recipe; it does NOT branch the generated artifacts.

**Changes in 2.0.0** (major — removed an enum value):
- Renamed `side-by-side` → `straight-swap` (the router stack was retired in plugin v0.5.0; the only Max-present codegen path now is straight-swap, which is what the script emits directly).
- No new fields, no new flags. The integrator no longer has to combine `mode-detect` output with a separate provider judgment — the v0.3.x three-way matrix collapsed.

**Concrete example:**

```json
{
  "schema": "mode-detect/2.0.0",
  "mode": "straight-swap",
  "signals": {
    "maxsdk_folder":      { "present": true,  "location": "Assets/MaxSdk/" },
    "maxsdk_init_symbol": { "present": true,  "location": "Assets/Scripts/HomeScreen.cs:60" },
    "applovin_manifest":  { "present": true,  "location": "Assets/MaxSdk/AppLovin/Editor/Dependencies.xml" }
  },
  "decision": "3 of 3 signals present (>=2 → straight-swap)."
}
```

---

## Max-callsite inventory (no JSON contract)

The integrator scans for MaxSdk callsites directly via the Bash tool (using `grep` piped through `scripts/lib/clean-cs.awk` to ignore matches inside string literals and comments) and reasons over each hit inline. There is no JSON contract for this step — the inventory lives in the agent's reasoning, not in a structured artifact. See `agents/unity-integrator.md` (Step 5, straight-swap branch) for the canonical scan snippet.

---

## `validator/1.4.0`

**Allowed values:**
- `status`: `PASS`, `FAIL`
- `mode`: `fresh`, `straight-swap`, `unknown`
- `warnings`: array of human-readable deprecation/migration strings (currently emitted only by the `--mode=side-by-side` alias path).
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
- `legacy_router_files_present` *(added in 1.3.0)* — FAIL when any retired v0.4 router-stack artifact (`IAdService.cs` / `MaxAdService.cs` / `AdServiceRouter.cs` / `MeticaRolloutBinding.cs`) is still present in the project. Catches half-migrated upgrades that the integrator's codegen tripwire (`unity-integrator.md` Step 5) only checks at write-time. Mirrors the same filename list so the two stay in lockstep.
- `mrec_callbacks_subscribed` / `mrec_load_show_parity` *(added in 1.3.0)* — same shape as the banner/interstitial/rewarded rules. The new MRec template shipped without validator coverage in 1.2.0 (broken MRec integrations silently passed); 1.3.0 closes that gap. Note the SDK casing: `MeticaSdk.Ads.LoadMrec` / `MeticaAdsCallbacks.Mrec.*` (lowercase `r`).
- `interstitial_show_failed_subscribed` / `rewarded_show_failed_subscribed` *(added in 1.4.0)* — FAIL when the format is used but `OnAdShowFailed` is not subscribed. Per the docs.metica.com Unity SDK example, both Interstitial and Rewarded subscribe `OnAdShowFailed` (signature `Action<MeticaAd, MeticaAdError>`). Without it the canonical reload-on-hidden loop stalls on the first show-failure: `OnAdHidden` does NOT fire after a show-fail, so the next ad is never loaded.

**Changes in 1.4.0** (minor, backward-compatible):
- Added `interstitial_show_failed_subscribed` and `rewarded_show_failed_subscribed` rules. The previous templates were missing the `OnAdShowFailed` subscription that the docs.metica.com Unity SDK example shows for both formats.
- `check-init-userid.awk` now tolerates whitespace (space, tab) between the `MeticaInitConfig` identifier and its `(` — `new MeticaInitConfig ("k","a",null)` is valid C# and was previously bypassed by the parser's exact-substring match. The check is also stricter: `MeticaInitConfig.Default` and similar non-constructor references no longer start the accumulator.

**Changes in 1.3.0** (minor, backward-compatible):
- Added `legacy_router_files_present`, `mrec_callbacks_subscribed`, `mrec_load_show_parity` rules.
- Tightened the `user_id_not_test_value` regex to require delimiter boundaries around `test`/`debug`/`dummy`/`placeholder` (the old anywhere-substring regex flagged `contest-user-42`, `latest-build`, etc).
- Tightened the `placeholder_ids_replaced` pattern to require the YOUR_*/REPLACE_ME match be enclosed in `"..."` (the old loose pattern flagged identifier names too).
- The `check-init-userid.awk` outer scanner is now string-aware (matches the inner `parse_args`), so test-value userIds containing literal `(` / `)` no longer silently bypass the check. It also rejects identifier-prefix substring matches like `OtherMeticaInitConfig(`.
- `check-init-userid.awk` now emits TAB-separated records instead of colon-separated, so file paths containing `:` do not corrupt the parsed `<file>\t<line>\t<reason>\t<value>` tuple.
- `strip-comments.awk` now tracks `in_verbatim` across lines (matching `clean-cs.awk`) and recognises C# char literals (`'\"'`, `'\\''`, `'\\n'`, etc.) so a `"`-containing char literal doesn't put the parser into bogus string-mode.
- Final JSON emit no longer uses `printf '%b'` for the `checks` block — that printf flag interpreted JSON-escaped `\\\\` back into `\\` and produced invalid JSON whenever a field contained an odd-count of `\` chars. Switched to `%s` plus a real-newline separator.
- The validator now runs a startup self-test on `clean-cs.awk` / `strip-comments.awk`; if either is missing or broken, the script `die_json`s instead of silently reporting an all-PASS report (the prior `|| c=0` pattern swallowed awk failures).
- `--mode=side-by-side` now also emits a deprecation entry in `warnings[]` (previously coerced silently).
- `warnings` is a documented contract field (previously always emitted as `[]` but undocumented).

**Changes in 1.2.0** (minor, backward-compatible):
- Added `placeholder_ids_replaced` and `user_id_not_test_value` checks. These were briefly present in v0.2.x then removed in v0.3.0 (commit `e42d709`) on the rationale that the integrator already knew which placeholders it embedded. They are reinstated because the validator's role is to lint **any** MeticaSDK integration (hand-rolled code, post-edit drift, CI checks) — not just the integrator's fresh output — so the checks have to live in the validator regardless of what the integrator reports.
- The side-by-side validation branch (router-bootstrap ordering) was removed alongside the v0.5.0 retirement of the router stack. Same-file privacy ordering is the universal rule now.
- `--mode=side-by-side` is accepted as a deprecated alias for `--mode=straight-swap` for v0.3.x back-compat; the `mode` field in the output is `straight-swap` regardless of which alias was passed.

**Status rule:** `status = "FAIL"` if any check has `level: FAIL` OR top-level `error != null`. `ADVISORY` does not affect status.

**Concrete example:**

```json
{
  "schema": "validator/1.4.0",
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
- `validator.status == FAIL` → print the `FAIL` rows, print the rollback command, exit non-zero. Do not auto-rollback.

---

## Versioning policy

- Bump minor (`1.0.0` → `1.1.0`) when adding optional fields. Orchestrator must remain backward-compatible.
- Bump major (`1.0.0` → `2.0.0`) when removing or renaming required fields. Orchestrator and producers update in lockstep.
- The orchestrator declares accepted majors in its agent spec (currently `compat-checker/1.x`, `mode-detect/2.x`, `validator/1.x`).
