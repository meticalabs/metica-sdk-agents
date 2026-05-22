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
    { "id": "scripting_backend", "detected": "Mono",        "required": "IL2CPP|Mono", "level": "PASS", "hint": "" }
  ]
}
```

---

## `validator/1.0.0`

**Allowed values:**
- `status`: `PASS`, `FAIL`
- `mode`: `fresh`, `side-by-side`, `unknown`
- `checks[].level`: `PASS`, `FAIL`, `ADVISORY`
- `checks[].rule`: short snake_case identifier (e.g. `privacy_before_init`, `init_count`, `rewarded_callback_subscribed`).
- `checks[].location`: `<relative_path>:<line>` or `""` when scope-wide.
- `checks[].detail`: one-line message describing what was found.

**Status rule:** `status = "FAIL"` if any check has `level: FAIL` OR top-level `error != null`. `ADVISORY` does not affect status.

**Concrete example:**

```json
{
  "schema": "validator/1.0.0",
  "status": "FAIL",
  "mode": "side-by-side",
  "error": null,
  "warnings": [],
  "checks": [
    { "rule": "init_count",                     "location": "",                                      "level": "PASS",     "detail": "MeticaSdk.Initialize called exactly once." },
    { "rule": "privacy_before_init",            "location": "Assets/Scripts/MeticaBootstrap.cs:42",  "level": "FAIL",     "detail": "SetHasUserConsent called after Initialize." },
    { "rule": "rewarded_callbacks_subscribed",  "location": "Assets/Scripts/MeticaAdapter.cs",       "level": "PASS",     "detail": "" },
    { "rule": "rewarded_reward_callback",       "location": "",                                      "level": "PASS",     "detail": "" },
    { "rule": "revenue_callback_subscribed",    "location": "",                                      "level": "ADVISORY", "detail": "OnAdRevenuePaid not subscribed; attribution will be incomplete." }
  ]
}
```

---

## `integrator` (no JSON contract)

The integrator does not emit JSON — it is the orchestrator. Its final message to the user includes:

1. Mode used (`fresh` | `side-by-side`).
2. SDK version installed.
3. Files created / edited (list).
4. Compat-checker summary (one line).
5. Validator summary (one line + `PASS`/`FAIL`).
6. Rollback command (`git reset --hard pre-metica-integration`) when validator returned `FAIL`.

The `pre-metica-integration` git tag is created by the integrator before any file change (see integrator.md, workflow step 4).

### Integrator's reaction to sub-agent results

- `compat-checker.status == BLOCK` → abort, print the `FAIL` rows, exit. Do not prompt to override.
- `compat-checker.status == PASS` with any `WARN` → continue, surface warnings.
- `validator.status == FAIL` → print the `FAIL` rows, print the rollback command, exit non-zero. Do not auto-rollback.

---

## Versioning policy

- Bump minor (`1.0.0` → `1.1.0`) when adding optional fields. Orchestrator must remain backward-compatible.
- Bump major (`1.0.0` → `2.0.0`) when removing or renaming required fields. Orchestrator and producers update in lockstep.
- The orchestrator declares accepted majors in its agent spec (currently `compat-checker/1.x`, `validator/1.x`).
