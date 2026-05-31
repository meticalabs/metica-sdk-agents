# RFC: v1.0 — discover-adapt-validate-autofix

**Status:** Implemented in plugin v1.0.0 (open questions resolved 2026-05-29, see §10; built in five staged commits — see §12)
**Author:** Drafted via Claude Code in session `01CdEYfGRcqm2pMfzcn4ikTv`
**Supersedes:** the explicit mode-detect step (`mode-detect/2.x`) and the rollback-first failure mode of v0.9.x

This RFC proposes restructuring the integrator's workflow from **deterministic mode-branch + fixed codegen** to **discover → adapt → validate → autofix**. The change is bigger than removing `scripts/detect-mode.sh` — that script disappears, but the larger shift is that the integrator stops *branching on a mode label* and starts *generating code that conforms to the host project*.

---

## 1. Motivation

The v0.9.x flow has three rough edges that have come up in review and in the May 28 repro:

1. **Mode-detect is over-engineered for what it does now.** The 2-of-3 multi-signal logic in `detect-mode.sh` (plus its JSON contract, plus 6 fixtures, plus `run-mode-tests.sh`) drives exactly two things downstream: the mediation argument to `MeticaSdk.Initialize` (`null` vs. `MAX`) and whether the call-site-rewrite step runs. Both decisions can be made from inline checks against signals the integrator already has.
2. **Codegen is host-blind in places where it shouldn't be.** Today the templates substitute namespace and ad-unit IDs, then stop. The game's existing placement strings, custom-data values, wrapper-API surface, trigger pattern (level-end, button click, timer), and remote-config gate are all visible in the source but are not threaded into the generated code. The result is that integration produces functionally-correct code that looks foreign to the host project.
3. **First-run validator FAIL → rollback is bad UX.** Default `USER_ID_EXPR=null` reliably trips `user_id_not_test_value`. Step 7 leads with `git reset --hard pre-metica-integration`. The user reverts a working integration because they hit the *expected* first-run state.

The proposal is a single workflow that addresses all three.

## 2. Goals

- **One path, no mode branching.** No `mode-detect/2.x`, no `if mode == "straight-swap"` in the agent prose. Replaced by a single discover-then-adapt step.
- **Conform to the host project's ad pattern, not just its namespace.** Placement strings, wrapper-API method names, trigger style, and gate location are inferred and threaded through codegen.
- **Validator becomes a self-test, not a wall.** Unambiguous failures are autofixed in place; ambiguous failures surface to the user with the offending file:line and a suggested patch. Rollback is the last resort, not the default.
- **Plan mode stays the audit checkpoint.** Discovery findings + the codegen plan are presented to the user before any file write. The user can correct misreads before they happen.

## 3. Non-goals

- **Not a rewrite of the templates' structural shape.** Per the user's directive ("don't change the structure of placeholder files, just add logic"): the `Metica<Format>Ad.cs.tmpl` and `MeticaAdService.cs.tmpl` retain their current shape. Adaptive codegen happens via **post-template patch passes**, not via template parameterization or a DSL.
- **Not removing the validator's deterministic rule set.** The validator's rules are unchanged by the discover→adapt→validate→autofix restructure (it ships as `validator/1.0.0`); what changes is the integrator's *reaction* to FAILs — autofix vs. rollback. (The one exception, the half-migration guard `legacy_router_files_present`, was dropped separately in the brand-new-project simplification — see §13.)
- **Not adding inference for completely-new features.** If the game uses App Open Ads (which `references/max-vs-metica-2.4.0-api.md:243` flags as a MeticaSDK gap), v1.0 still surfaces that as out-of-scope — discovery records the gap, codegen doesn't paper over it.
- **Not changing `compat-checker` or `validator` agent contracts.** The orchestrator's surface stays the same.

## 4. Workflow walkthrough

The integrator's high-level flow becomes:

```
1. Compat-check                (unchanged)
2. Discovery                   (NEW — replaces mode-detect + parts of Step 2.5 + Step 5 inventory)
3. Plan mode preview           (presents discovery findings + codegen plan)
4. Git snapshot                (unchanged)
5. Adaptive codegen            (templates + per-file patch passes from discovery)
6. Call-site rewrites          (only when Max usage was discovered)
7. Validate + autofix loop     (NEW — replaces "validate + rollback")
8. Final report                (mostly unchanged; rollback hint only when autofix gave up)
```

Concretely, here's how a real Max-using project moves through it:

**Discovery output** (presented in plan mode):

```
== Discovery ==
Max integration:
  - MaxSdk.Initialize called in: Assets/Scripts/AppBootstrap.cs:42
  - Max wrapper detected: Assets/Scripts/Ads/AdManager.cs
      Public API:  AdManager.Init(), AdManager.ShowInterstitial(string placement),
                   AdManager.ShowRewarded(string placement, Action onReward)
      Wraps:       MaxSdk.LoadInterstitial, MaxSdk.ShowInterstitial,
                   MaxSdk.LoadRewardedAd, MaxSdk.ShowRewardedAd
  - Direct (non-wrapper) Max call sites: 0
  - Formats used: interstitial, rewarded
  - Placement strings observed: "level_complete", "shop_continue", "death_revive"
  - Custom data observed: none
  - Trigger pattern: AdManager method called from LevelEndController.OnLevelEnd,
                     ShopUI.OnContinueClicked, DeathUI.OnReviveClicked
  - Remote-config gate: Firebase Remote Config key "ads_enabled" (bool) at
                        Assets/Scripts/Ads/AdManager.cs:24

Remote-config provider: firebase   (drives the Step 7 cohort-gating recipe)

== Codegen plan ==
Adapter folder:  Assets/Scripts/Ads/Metica/   (next to AdManager.cs, not the default Assets/Scripts/Metica/)
Namespace:       Game.Ads.Metica              (inferred from AdManager.cs's namespace + .Metica)
Files to write:
  - Assets/Scripts/Ads/Metica/MeticaAdService.cs
  - Assets/Scripts/Ads/Metica/MeticaInterstitialAd.cs
  - Assets/Scripts/Ads/Metica/MeticaRewardedAd.cs
  - Assets/Scripts/MeticaBootstrap.cs
Patch passes:
  - MeticaAdService: expose ShowInterstitial(string placement) and ShowRewarded(string
    placement, Action onReward) — match AdManager's public API
  - Per-format adapter Show(): default placement parameter wired through (no hardcoded null)
Call-site rewrites:
  - AdManager.cs methods become thin shims that delegate to MeticaAdService (preserves
    LevelEndController/ShopUI/DeathUI call sites unchanged)
Cohort-gating recipe (in final report only):
  - Firebase template: `if (RemoteConfig.GetBool("metica_rollout")) { _ads.Show... }`
    else fall back to AdManager.Show... (preserves the existing "ads_enabled" gate)

Proceed?
```

The user approves or says "no, the wrapper is `AdsService.cs`, not `AdManager.cs`" → integrator re-discovers and re-plans. **This is the audit checkpoint**: any inference error is caught before files are written.

**Codegen** then runs templates + patches:

1. Render `MeticaInterstitialAd.cs.tmpl` → `Assets/Scripts/Ads/Metica/MeticaInterstitialAd.cs` with namespace substitution (current behavior, unchanged).
2. Render `MeticaAdService.cs.tmpl` (NEW — currently this lives in the codegen test only; see §6.3) → same folder.
3. Apply discovery-derived patches:
   - Append wrapper-API delegators to `MeticaAdService.cs` (`ShowInterstitial(string placement)`, `ShowRewarded(string placement, Action onReward)`).
   - The per-format `Show()` already takes optional `placement`/`customData`; no patch needed.
4. Rewrite `AdManager.cs`: replace each `MaxSdk.*` call with the equivalent `_meticaAds.*` call inside the existing public method bodies. Public API of `AdManager` is preserved, callers don't change.

**Validate + autofix:**

```
Validator run 1 → FAIL: user_id_not_test_value at MeticaAdService.cs:14
                  (USER_ID_EXPR defaulted to null)
                  → AUTOFIXABLE: prompt the user inline:
                    "userId is currently `null`. Replace with:
                       1) SystemInfo.deviceUniqueIdentifier
                       2) PlayerProfile.PlayerId
                       3) something else (type expression)"
                  → user picks (1) → integrator patches the file → re-validate
Validator run 2 → PASS
```

vs. the v0.9.x flow which would have terminated with "VALIDATION FAILED. Rollback: git reset --hard pre-metica-integration".

## 5. Discovery — what gets inferred, output format

Discovery is one step in the integrator's prose, executed via `Bash` tool calls. The findings are accumulated into a structured Markdown block that the agent then presents in plan mode AND uses as input to codegen patches. It is **not** a JSON contract — it's prose with anchors the codegen step references.

The discovery checklist (in order, each line is a single Bash invocation or `Grep`/`Read`):

| Signal | Tool | Anchor in output |
|---|---|---|
| MaxSDK install (folder, manifest) | `find` + `grep` | `Max integration` |
| Direct `MaxSdk.*` call sites (file:line + method + args) | `grep` through `clean-cs.awk` | `Direct Max call sites` |
| Wrapper class (a class with non-Max public API that wraps `MaxSdk.*`) | `grep -l 'MaxSdk\.' Assets/Scripts/`, then `Read` candidates. **Flow-based test, not name-based** (OQ1): a method is a wrapper method when the ad-unit id reaching `MaxSdk.*` comes from a *field/const* inside the class; if the method's own `string` parameter is forwarded straight into Max's ad-unit slot, the class is a routing layer → treat its call sites as direct. | `Max wrapper detected` |
| Placement strings (2nd arg to `ShowInterstitial`/`ShowRewarded`) | `grep -oE 'ShowInterstitial\("[^"]*", "[^"]*"' \| awk -F'"' '{print $4}'` | `Placement strings observed` |
| Custom-data strings (3rd arg) | same, 6th field | `Custom data observed` |
| Trigger pattern (who calls `*.Show*` from the wrapper) | `grep -rn '$WrapperClass\.Show' Assets/Scripts/` | `Trigger pattern` |
| Remote-config provider (Firebase / Unity Remote Config / AppMetrica) | existing Step 2.5 logic | `Remote-config provider` |
| Remote-config gate around ad calls | `grep` for `RemoteConfig.Get` / `FirebaseRemoteConfig` keys near MaxSdk call sites | `Remote-config gate` |

**Wrapper detection stays a prose judgment confirmed in plan mode** (OQ1) — it is *not* promoted to a precise scripted rule. When discovery finds **more than one** wrapper candidate, it lists them all and the plan-mode preview requires an explicit pick; a single candidate is auto-selected and shown for confirmation, never silently chosen (OQ2).

**Shared cleaned-source seam** (OQ4): discovery and the validator both read C# source through a single `clean_source(path)` accessor. In v1.0 its body still shells `clean-cs.awk` / `strip-comments.awk` inline (current behavior); the materialized cleaned-source cache that amortises the awk passes is a later, localized drop-in behind this seam — no fixture churn when it lands.

**Why not JSON?** Two reasons:

1. The agent already reasons in prose. The discovery output is read by the same agent that produced it (and by the user in plan mode). A structured JSON contract would force prose→JSON→prose round-trips with no gain.
2. Some signals are inherently fuzzy (wrapper detection, trigger pattern). Forcing them into JSON makes the fuzziness LOOK precise, which is worse than admitting it in prose.

The exception: if/when discovery feeds an autofix decision (e.g., "auto-pick placement string `level_complete` for the rewritten `ShowInterstitial` call at file X line Y"), that single decision becomes a structured patch-spec — see §7.

## 6. Adaptive codegen

### 6.1 Templates stay static

`scripts/templates/standalone/Metica<Format>Ad.cs.tmpl` are unchanged structurally. Same MonoBehaviour, same callbacks, same docs-verbatim retry, same `OnApplicationFocus` (banner/MRec). The integrator does not write new templates for v1.0.

### 6.2 Post-template patch passes

After rendering a template, the integrator may apply a small set of **deterministic edits** parameterized by discovery. The patch operations are:

| Operation | When applied | Discovery input |
|---|---|---|
| Insert delegator method | wrapper detected → `MeticaAdService` mirrors wrapper API | wrapper's public method signatures |
| Default placement on `Show()` call | placement strings observed → orchestrator's `ShowX()` passes the dominant placement instead of `null` | most-frequent placement string |
| Rename `MeticaAdService` | wrapper detected with neutral name (e.g. `AdsManager`) → orchestrator class renamed to e.g. `MeticaAdsManager` so it sits next to the wrapper visually | wrapper class name |
| Adapter-folder placement | wrapper detected → place adapters next to the wrapper file | wrapper's parent directory |

Patch passes are **explicit, named, and pure**: each one takes a file path + a discovery field and produces an edit. They're easier to reason about than a parameterized template DSL.

Per the testing decision (§9, §10/Review-OQ C), the patch passes remain **agent-applied prose**, not standalone scripts with per-patch goldens. They are validated *indirectly*: a fixture's correctly-integrated output must PASS the validator, so a botched patch surfaces as a validator FAIL. The accepted gap — no direct regression test of the patch mechanism itself — is documented in §9.

### 6.3 `MeticaAdService.cs.tmpl` finally exists

A blocker for v1.0: the orchestrator's shape currently lives only in `tests/run-codegen-validator-tests.sh`'s `emit_standalone` shell function and in integrator prose. v1.0 promotes it to a real template at `scripts/templates/standalone/MeticaAdService.cs.tmpl`. The test reference becomes `sed`-substitution like `emit_standalone_perfile` does today.

This was deferred in the v0.6.0 review pass as "larger refactor"; v1.0 is the natural moment to land it.

## 7. Autofix — partition and bounds

The validator emits 11–13 rules. Each is classified as `autofix`, `prompt`, or `surface`.

| Rule | Class | Autofix action |
|---|---|---|
| `init_count` (count > 1) | surface | Cannot infer which call to delete; surface file:line and ask |
| `init_count` (count == 0) | surface | Adapter file missing; this is a codegen bug, not a user fix |
| `privacy_before_init` | autofix | Reorder lines in the offending file (privacy calls precede `Initialize`) |
| `<fmt>_callbacks_subscribed` | autofix | Append missing subscription line to the per-format adapter |
| `rewarded_reward_callback` | autofix | Append `OnAdRewarded` subscription |
| `<fmt>_load_show_parity` | surface | Cannot infer missing call site; surface file:line |
| `<fmt>_reload_on_hidden` | autofix | Append `OnAdHidden += ad => Load();` |
| `<fmt>_show_failed_subscribed` | autofix | Append `OnAdShowFailed += (ad, err) => Load();` |
| `<fmt>_show_ready_guard` (ADVISORY) | — | No action — advisory only |
| `revenue_callback_subscribed` (ADVISORY) | — | No action — advisory only |
| `placeholder_ids_replaced` | prompt | Ask for real value, substitute in source |
| `user_id_not_test_value` | prompt | **For the integrator's own output: collected at plan time** (Review-OQ A) — the real expression is gathered in the plan-mode preview so run-1 validation PASSes. The reactive prompt (offer `SystemInfo.deviceUniqueIdentifier`, `PlayerProfile.PlayerId`, …) remains only as the fallback for hand-rolled code linted outside the integrator flow. |

**Ownership** (Review-OQ B): the **validator stays purely read-only** — it lints and emits `validator/1.0.0` JSON, unchanged. The **integrator (orchestrator) owns the entire autofix loop**: it reads the validator's FAIL rows, classifies each via the table above, applies edits, writes the log, prompts the user where needed, and re-invokes the validator. The validator never edits and never prompts. `agents/contracts.md`'s "do not auto-rollback" line is updated accordingly: rollback stays a last-resort *hint*, never automatic — but the integrator now *reacts* to FAILs with autofix before falling back to that hint.

**Bounds on the autofix loop**:

- **Maximum 3 iterations.** After 3 validator runs that still produce new FAILs, the loop halts and falls back to the rollback hint. Prevents infinite loops if a fix introduces a new failure.
- **No autofix produces a NET-NEW file.** Autofixes only edit existing files. (Codegen produces files; autofix patches them.) This is a hard invariant — it means a missing file is always `surface`, never `autofix`.
- **Anchor re-check before every edit** (OQ3). Immediately before applying a patch, the integrator re-reads the target and confirms the line it intends to change still matches what the validator reported. On a mismatch (file changed on disk / open in an editor), it does **not** retry the write — it surfaces the suggested patch + `file:line` for manual application and logs the refusal. Surface, never retry.
- **Each autofix records what it did** in a `.metica-integration.log` next to the adapter folder, so the user can audit the loop after the fact.
- **Prompt-class fixes are interactive.** They pause the run and ask. They never silently substitute. (The most common one, `user_id_not_test_value`, is collected proactively at plan time — see §7 table — so the loop rarely needs to prompt for the integrator's own output.)

## 8. Migration from v0.9.x

This is a **major version bump** — workflow change, retired contract (`mode-detect/2.x`), template added (`MeticaAdService.cs.tmpl`), validator behavior unchanged but integrator's reaction to it changed.

Migration steps:

1. **`mode-detect/2.x` → retired.** No deprecation alias — the script disappears, the contract entry in `agents/contracts.md` moves to a "Retired contracts" section. The integrator's accepted-majors line drops `mode-detect`.
2. **Tests:** delete `tests/run-mode-tests.sh` and `tests/mode-fixtures/`. The codegen-validator suite expands to cover discovery + patch outputs (see §9).
3. **Plugin version:** `0.9.x → 1.0.0`.
4. **CLAUDE.md & README**: rewrite the "two modes" section into "discover → adapt → validate → autofix". The mode labels still appear in the validator's `mode` field, but the integrator stops branching on them — they become a property of the result, not a control-flow input.
5. **Validator schema:** ships as `validator/1.0.0`. The mode field's allowed values are `fresh`, `straight-swap`, `unknown` — the validator auto-detects from `HAS_MAX` and labels the result as a property.
6. **`--mode=side-by-side` alias:** removed. v0.3.x callers have had two major versions to migrate; the alias was always a transition tool.
7. **Integrator reaction (`agents/contracts.md`):** update the "Integrator's reaction to sub-agent results" subsection — `validator.status == FAIL` now drives the autofix loop (classify, patch with anchor re-check, re-validate, max 3 iterations) before falling back to the rollback hint. The validator contract itself is unchanged; only the integrator's documented reaction changes.

## 9. Testing

**Decision (Review-OQ C): prose-heavy, shrink the testing surface.** Discovery and the patch passes stay as agent prose (§5, §6.2); only the *deterministic, scriptable* output — template rendering and the validator's verdict — is golden-tested in bash. The suite does **not** regex-assert the discovery Markdown block or the patch mechanism (a pure-bash harness can't observe what the agent emits or edits). Those are verified at the agent/manual level plus the plan-mode audit checkpoint. **Accepted, documented gap:** there is no direct regression test of discovery inference or patch application; the safety net is that every fixture's correctly-integrated output must PASS the validator, so a broken result surfaces as a FAIL.

What the suite asserts:

1. **Codegen byte-shape** — existing assertions on the rendered template files (template rendering is scripted via `emit_standalone` / `sed`; this is unchanged and now exercises the new `MeticaAdService.cs.tmpl`, §6.3).
2. **Validator-on-output** — for each representative integration scenario, a hand-built *post-codegen* fixture that the validator must PASS.
3. **Validator-on-defect** — for each `FAIL`-producing rule, a fixture that triggers it and asserts the validator reports that rule with the expected `file:line`. This confirms the autofix loop will always have a correct, located target to act on (and that `surface`-class rules are reported, not silently swallowed).

Fixture scenarios (correctly-integrated, must PASS the validator):

- `clean-fresh/` — Unity project, no Max, no Metica. Expected codegen: standalone adapters in `Assets/Scripts/Metica/`. **Namespace: none when the project has no `namespace` declarations; `MeticaIntegration` when namespaces exist but none dominate; `<dominant>.Metica` when one dominates — never `Metica.AbTest`** (that token is the plugin templates' placeholder, never emitted into game-owner code; see `CLAUDE.md` and `unity-integrator.md` Step 2.5/Step 5). Include a no-namespace fixture and a dominant-namespace fixture.
- `max-direct-calls/` — `MaxSdk.*` called directly from game scripts, no wrapper. Expected codegen: standalone adapters in `Assets/Scripts/Metica/` + rewritten direct call sites.
- `max-with-wrapper/` — `AdManager.cs` wrapper around Max. Expected codegen: adapters in `Assets/Scripts/Ads/Metica/` (next to the wrapper), orchestrator API mirrors the wrapper, wrapper body rewritten to delegate.
- `max-with-firebase-gate/` — Max + Firebase Remote Config with an `ads_enabled` key. Expected final report includes the cohort-gating recipe keyed on the existing `ads_enabled`.

`tests/run-autofix-tests.sh` (validator-driven, not agent-driven):
- Per `autofix`-classified rule: a pre-fix fixture asserting the validator FAILs with that rule + `file:line`, paired with a post-fix fixture asserting the validator PASSes. (Tests that the loop's target and exit condition are correct; the agent's application of the patch is verified manually.)
- Per `surface`-classified rule: a fixture asserting the validator FAILs with that rule, and that the rule is one the partition (§7) marks `surface` (so the integrator emits the rollback hint rather than patching).

## 10. Resolved decisions (was: risks & open questions)

All five original open questions were resolved in the 2026-05-29 review, along with three follow-ups the review surfaced. Decisions are folded into the relevant sections above; recorded here for traceability.

| # | Question | Decision | Folded into |
|---|---|---|---|
| OQ1 | Wrapper-detection precision | **Prose judgment confirmed in plan mode**; the adUnitId-vs-placement ambiguity is resolved by *data flow* (Max unit-id from a field/const = wrapper; from the public param = routing → direct), not by parameter name. Not promoted to a scripted rule. | §5 table |
| OQ2 | Multiple wrapper candidates | **List + explicit pick**: one candidate auto-selected and shown for confirmation; >1 requires an explicit choice in plan mode, never a silent default. | §5 |
| OQ3 | Autofix write races | **Surface via anchor re-check**: re-read the target before each edit, confirm the anchor line; on mismatch emit the patch + `file:line` and log it. Never retry the write. | §7 bounds |
| OQ4 | Discovery scan cost | **Seam now, cache later**: discovery + validator read through one `clean_source()` accessor in v1.0 (awk still inline); the materialized cache is a later localized drop-in with no fixture churn. | §5 |
| OQ5 | Plan-mode skimming | **Two-tier preview**: one-line summary + a focused "confirm these inferences" list (wrapper / namespace / adapter folder / user-id, each with its source anchor) + the full mechanical plan below. | §4; detail at end of §10 |
| Review-OQ A | User-id collection timing | **Collect at plan time** (on the OQ5 inferences list) so run-1 validation PASSes; the reactive autofix prompt remains only as the fallback for hand-rolled code linted outside the integrator. | §7 table |
| Review-OQ B | Autofix ownership | **Integrator owns the loop; validator stays purely read-only.** `agents/contracts.md` updated; rollback stays a last-resort hint. | §7 ownership |
| Review-OQ C | Scripted vs. prose boundary | **Prose-heavy, shrink §9** to template byte-shape + validator-on-output/-defect fixtures; the discovery/patch coverage gap is accepted and documented. | §6.2, §9 |

**Residual risk (carried into implementation, not blocking):**

- **OQ1 verification** — confirm the flow-based wrapper test matches the May 28 repro project's actual wrapper shape. Requires the sibling `../max-agent-test/DemoApp`, which is absent from a clean clone; this is a **local manual check** for whoever has the repro, before v1.0 lands.
- **Review-OQ C coverage gap** — discovery inference and patch application have no direct bash-golden regression test (verified via plan-mode review + validator-on-output). Deliberate, per §9.

**Plan-mode preview structure** (OQ5): the integrator's Step 3 emits, in order — (1) a one-line summary (`Detected: Max + wrapper, no remote-config gate. Will write 4 files, rewrite 3 call sites.`), (2) a **"Confirm these inferences"** list naming only the fuzzy/inferred decisions with their source anchors (`wrapper = AdManager.cs`, `namespace = Game.Ads.Metica (from AdManager.cs)`, `adapter folder = Assets/Scripts/Ads/Metica/`, `userId = <to collect>`), then (3) the full codegen plan. Scrutiny is directed at the decisions that, if wrong, silently produce foreign code — and that are only correctable before the write.

## 11. Out-of-scope (for v1.0)

- App Open Ads codegen (still a MeticaSDK gap per `references/max-vs-metica-2.4.0-api.md`)
- Object-initializer form support for `user_id_not_test_value` (`new MeticaInitConfig { UserId = … }`)
- Auto-generated cohort-gating wiring (still report-only — user copy-pastes the recipe)
- Multi-mediator detection (IronSource, AdMob) — Max only for v1.0

## 12. Outcome

Implemented in plugin **v1.0.0** in five staged commits, each independently reviewed and verified:

1. Promote `MeticaAdService.cs.tmpl` (orchestrator template; §6.3).
2. Shared `clean_source()` accessor seam (OQ4 — the cleaned-source cache drops in behind it later).
3. Discovery-first integrator: mode as a property, flow-based wrapper detection, multi-wrapper pick, two-tier plan preview with plan-time user-id (Steps 2, 2.5, 3).
4. Adaptive codegen via named post-template patch passes (§6.2).
5. Integrator-owned validate + autofix loop (§7); retire `mode-detect/2.x`, the `--mode=side-by-side` alias, and the mode test suite; rewrite docs; bump to 1.0.0 (§8).

Carried-forward manual check (non-blocking): validate the flow-based wrapper heuristic (§10/OQ1) against the May 28 repro project, which is absent from a clean clone.

## 13. Addendum: brand-new-project simplification (post-1.0)

After v1.0 landed, the maintainer confirmed this is a **brand-new project — no prior public releases and no users**. With no installed base, backward-compatibility shims and half-migration guards protect nobody, so they were removed and the contracts now present as a clean first release. This supersedes the parts of §3/§7/§8 that assumed an existing v0.x user base.

**Removed:**

- **`legacy_router_files_present` validator rule** + the integrator's codegen self-check tripwire and the "never emit `IAdService`/`MaxAdService`/`AdServiceRouter`/`MeticaRolloutBinding`" hard rule. These guarded against a retired *internal* codegen path (the v0.4 router stack) that no shipped project ever used. The `bad-legacy-router-files` and `good-user-owned-iadservice` fixtures and their validator/autofix test cases went with it. (This narrows the §7 autofix partition — the `surface`-class `legacy_router_files_present` row no longer exists.)
- **`--mode=side-by-side` back-compat.** The alias was already removed in §8; the dedicated rejection test is now a generic invalid-mode test.
- **Validator schema version history.** Reset `validator/1.4.0 → validator/1.0.0` everywhere; deleted the "Changes in 1.2.0/1.3.0/1.4.0" changelogs and the `(added in X)` per-rule annotations. The validator ships as `validator/1.0.0` — a true first release.
- **Retired-version framing** ("retired in v0.5.0", "v0.4 router stack", "v0.3.x back-compat") scrubbed from the README, CLAUDE.md, the agents, and the validator script.

**Kept** — these are about *user* code, not the retired internal stack, and remain load-bearing:

- The **wrapper-scoping rule** (never edit a dedicated Max-wrapper file; rewrite only the game's direct call sites).
- The **`never modify Assets/MaxSdk/`** hard rule.

This addendum's framing about migrating *from* v0.9.x (§1, §8) is retained only as the genuine design record of how the v1.0 architecture was reached — it does not imply a shipped v0.x that anyone must migrate.
