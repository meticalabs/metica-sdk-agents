# RFC: v1.0 — discover-adapt-validate-autofix

**Status:** Draft
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
- **Not removing the validator's deterministic rule set.** The validator stays exactly as it is at `validator/1.4.0`. What changes is the integrator's *reaction* to FAILs — autofix vs. rollback.
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
| Wrapper class (a class with non-Max public API that wraps `MaxSdk.*`) | `grep -l 'MaxSdk\.' Assets/Scripts/`, then `Read` candidates and look for `public ... Show/Load` methods that don't take a Max-style adUnitId | `Max wrapper detected` |
| Placement strings (2nd arg to `ShowInterstitial`/`ShowRewarded`) | `grep -oE 'ShowInterstitial\("[^"]*", "[^"]*"' \| awk -F'"' '{print $4}'` | `Placement strings observed` |
| Custom-data strings (3rd arg) | same, 6th field | `Custom data observed` |
| Trigger pattern (who calls `*.Show*` from the wrapper) | `grep -rn '$WrapperClass\.Show' Assets/Scripts/` | `Trigger pattern` |
| Remote-config provider (Firebase / Unity Remote Config / AppMetrica) | existing Step 2.5 logic | `Remote-config provider` |
| Remote-config gate around ad calls | `grep` for `RemoteConfig.Get` / `FirebaseRemoteConfig` keys near MaxSdk call sites | `Remote-config gate` |

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

Patch passes are **explicit, named, and pure**: each one takes a file path + a discovery field and produces an edit. They're easier to test than a parameterized template DSL.

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
| `user_id_not_test_value` | prompt | Ask for real expression (offer common substitutions: `SystemInfo.deviceUniqueIdentifier`, `PlayerProfile.PlayerId`, …) |
| `legacy_router_files_present` | surface | Cannot infer how the user wants the stale router code removed; surface and offer `git rm` |

**Bounds on the autofix loop**:

- **Maximum 3 iterations.** After 3 validator runs that still produce new FAILs, the loop halts and falls back to the rollback hint. Prevents infinite loops if a fix introduces a new failure.
- **No autofix produces a NET-NEW file.** Autofixes only edit existing files. (Codegen produces files; autofix patches them.) This is a hard invariant — it means a missing file is always `surface`, never `autofix`.
- **Each autofix records what it did** in a `.metica-integration.log` next to the adapter folder, so the user can audit the loop after the fact.
- **Prompt-class fixes are interactive.** They pause the run and ask. They never silently substitute.

## 8. Migration from v0.9.x

This is a **major version bump** — workflow change, retired contract (`mode-detect/2.x`), template added (`MeticaAdService.cs.tmpl`), validator behavior unchanged but integrator's reaction to it changed.

Migration steps:

1. **`mode-detect/2.x` → retired.** No deprecation alias — the script disappears, the contract entry in `agents/contracts.md` moves to a "Retired contracts" section. The integrator's accepted-majors line drops `mode-detect`.
2. **Tests:** delete `tests/run-mode-tests.sh` and `tests/mode-fixtures/`. The codegen-validator suite expands to cover discovery + patch outputs (see §9).
3. **Plugin version:** `0.9.x → 1.0.0`.
4. **CLAUDE.md & README**: rewrite the "two modes" section into "discover → adapt → validate → autofix". The mode labels still appear in the validator's `mode` field, but the integrator stops branching on them — they become a property of the result, not a control-flow input.
5. **Validator schema:** unchanged at `validator/1.4.0`. No new rules. The mode field's allowed values remain `fresh`, `straight-swap`, `unknown` — the validator still auto-detects from `HAS_MAX` and labels the result. (Removing the label from the validator output would break consumers; not worth it.)
6. **`--mode=side-by-side` alias:** removed. v0.3.x callers have had two major versions to migrate; the alias was always a transition tool.

## 9. Testing

The shape of the codegen-validator suite changes from "assert byte-shape of generated files" to "assert correct response to a realistic input fixture".

New fixture categories under `tests/discovery-fixtures/`:

- `discovery-fixtures/clean-fresh/` — Unity project, no Max, no Metica. Expected discovery: `fresh, no wrapper, no remote-config`. Expected codegen: standalone adapters in `Assets/Scripts/Metica/`, namespace `Metica.AbTest` (or none, if project has no namespaces).
- `discovery-fixtures/max-direct-calls/` — Unity project with `MaxSdk.*` called directly from game scripts (no wrapper). Expected discovery: `straight-swap, no wrapper, direct call sites at X file:line`. Expected codegen: standalone adapters in `Assets/Scripts/Metica/`, rewrites of direct call sites.
- `discovery-fixtures/max-with-wrapper/` — Unity project with `AdManager.cs` wrapper around Max. Expected discovery: `straight-swap, wrapper at Assets/Scripts/Ads/AdManager.cs, public API: AdManager.ShowInterstitial(string)`. Expected codegen: adapters in `Assets/Scripts/Ads/Metica/` (next to wrapper), orchestrator API matches wrapper.
- `discovery-fixtures/max-with-firebase-gate/` — Max + Firebase Remote Config with an `ads_enabled` key gating Max calls. Expected discovery includes the gate. Expected final report includes the cohort-gating recipe with the existing `ads_enabled` key.

Each fixture asserts on:
1. Discovery output (regex against the structured Markdown block the agent emits)
2. Codegen output (existing byte-shape assertions on the generated files)
3. Validator result (PASS, with autofix log if applicable)

The autofix loop itself is tested via `tests/run-autofix-tests.sh`:
- Per autofix-classified rule, a fixture that triggers the failure, asserts the loop applies the right patch, and asserts the second validator run PASSes.
- Per surface-classified rule, a fixture that triggers the failure, asserts the loop does NOT patch, and asserts the rollback hint is emitted.

## 10. Risks & open questions

1. **Wrapper detection is fuzzy.** What counts as a "Max wrapper"? Heuristic: a class with at least one `public` method whose body calls `MaxSdk.*` AND does NOT take an adUnitId-shaped string parameter. Edge case: a wrapper that DOES take an adUnitId is more of a routing layer than a wrapper; we'd treat it as direct call sites. **OQ:** does this heuristic match the May 28 repro project's actual wrapper shape? Worth a manual check before v1.0 lands.

2. **Multiple wrappers.** What if the project has `AdManager.cs` AND `IronSourceAdapter.cs` (mediation layer)? Discovery would surface both; the user picks which one to adapt to. **OQ:** is this likely enough to warrant explicit handling, or rare enough that the plan-mode override path is sufficient?

3. **Autofix and merge conflicts.** If the user's editor or another tool has the file open when autofix runs, the patch might fail. **OQ:** retry or surface? Probably surface — autofix should be cautious.

4. **Discovery cost.** Each discovery signal is a Bash call. For a 1000-file project, that's ~10 calls, each running awk over the full source tree. The validator already does the same in its rule loop (see the angle-H review findings — ~18,000 awk subprocesses on a 500-file project). v1.0 could amortise by materialising a cleaned-source cache once, then having both discovery AND the validator read from it. **OQ:** worth doing as part of v1.0, or as a follow-up perf pass?

5. **Plan-mode size.** The discovery block + codegen plan is ~30–50 lines. Some users may skim. Mitigation: a one-line summary at the top ("Detected: Max + wrapper, no remote-config gate. Will write 4 files, rewrite 3 call sites, no autofix expected.") then the full block below for scrutiny.

## 11. Out-of-scope (for v1.0)

- App Open Ads codegen (still a MeticaSDK gap per `references/max-vs-metica-2.4.0-api.md`)
- Object-initializer form support for `user_id_not_test_value` (`new MeticaInitConfig { UserId = … }`)
- Auto-generated cohort-gating wiring (still report-only — user copy-pastes the recipe)
- Multi-mediator detection (IronSource, AdMob) — Max only for v1.0

## 12. Recommendation

Land v0.9.1 first (the current branch state — all review threads resolved). Then promote this RFC to a tracked issue, gather concrete feedback (especially on §10 OQs), and build v1.0 as a fresh branch. Estimated scope: 2 weeks of work given the test-fixture build-out, not a one-PR refactor.
