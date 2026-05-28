# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is **not application code** — it is a Claude Code *plugin* that ships three Unity sub-agents. The "source" is:

- **Agent definitions** — markdown-with-frontmatter directly under `agents/` (`unity-integrator.md`, `unity-validator.md`, `unity-compat-checker.md`). The frontmatter (`name`, `description`, `tools`, `model`) is the agent's contract; the body is its prompt. They live in `agents/` itself, **not** a subfolder, on purpose: a plugin subfolder becomes a scope segment in the mention token, so `agents/unity/unity-integrator.md` would register as `@agent-metica-sdk-agents:unity:unity-integrator`. Keeping them flat preserves the documented `@agent-metica-sdk-agents:unity-integrator`.
- **Scripts** — `scripts/*.sh` hold all deterministic logic. Agents are thin: they run a script and relay its output. Editing behavior almost always means editing a script, not prose.
- **Reference docs** — `agents/contracts.md` (the inter-agent JSON contracts) and `references/` (MaxSdk↔MeticaSdk API parity).

There is no build step and no compiled artifact. Changing an agent = editing its `.md`; changing logic = editing a `.sh` and its tests.

## Commands

```bash
bash tests/run-all.sh                      # full suite; prints "ALL GREEN" or "FAILURES"
bash tests/run-<suite>-tests.sh            # a single suite (compat, format, download,
                                           # validator, mode, input-validation,
                                           # codegen-validator)
```

Tests are plain bash assertions against fixtures (`tests/fixtures/`, `tests/mode-fixtures/`, `tests/validator-fixtures/`) and goldens (`tests/goldens/`). No framework, no install. Suites that probe a sibling `../max-agent-test/DemoApp` skip silently when it's absent — a clean clone runs the synthetic-fixture suites only.

## Architecture

**Orchestrator + two thin wrappers.** `unity-integrator` (model: sonnet) is the only agent users invoke directly. It calls `unity-compat-checker` (haiku) and `unity-validator` (sonnet) as sub-agents. The compat-checker and validator do nothing but run a script and print its stdout verbatim — never paraphrase or summarize their output when editing them.

**Agents talk to the orchestrator in versioned JSON.** Each sub-agent's final message ends with a fenced ` ```json ` block. The orchestrator parses **the last** such block (regex in `agents/contracts.md`), never the prose. Schemas are versioned `<name>/<major>.<minor>.<patch>`; the orchestrator accepts any minor/patch within an accepted major. **If you add a field to a script's JSON output, bump the minor and update `agents/contracts.md` — these three move together.** Contracts: `compat-checker/1.x`, `mode-detect/2.x`, `validator/1.x`. The integrator itself emits no JSON.

**`PLUGIN_DIR` resolution is mandatory.** Every agent's first bash command is a loop that locates `scripts/resolve-plugin-dir.sh` across known install locations (incl. the marketplace cache `~/.claude/plugins/cache/*/metica-sdk-agents/*`) and runs it. `$CLAUDE_PLUGIN_ROOT` is **not** reliably exported into an agent's bash tool environment — verified empirically — so it is only the first candidate, never the sole path. `resolve-plugin-dir.sh`'s load-bearing fallback is **self-location** from its own script path (`<root>/scripts/resolve-plugin-dir.sh` → root is two levels up); after env vars and self-location it tries agent-symlink targets and known install paths (incl. the version-sorted cache glob). The resolver and the agents' bootstrap loop are covered by `tests/run-resolver-tests.sh`. Scripts are always invoked as `"$PLUGIN_DIR/scripts/..."` — never with relative paths. `resolve-plugin-dir.sh`'s `is_root()` identifies the root by the presence of **`.claude-plugin/plugin.json`** and an `agents/` directory; if you move the manifest, that check (and marketplace install) breaks.

**The integrator's two modes** are the central branch. `scripts/detect-mode.sh` looks for three MaxSDK signals (`Assets/MaxSdk/` folder, `MaxSdk.Initialize(` symbol, AppLovin manifest); two-of-three → **straight-swap**, else **fresh**. The script emits the final mode label directly (no prose interpretation step); the v0.3.x three-way matrix collapsed when the side-by-side router stack was retired in v0.5.0. When Max is present, the integrator's Step 2.5 also detects the project's remote-config provider — but the result is **report-only**, driving the Step 7 cohort-gating recipe (a copy-paste pattern the user wires themselves). It does **not** change the generated artifacts: both Max-present cases produce the same `MeticaAdService` + per-format files, and the integrator rewrites the game's *direct* `MaxSdk.*` call sites to use them. Dedicated Max-wrapper files (e.g. an `AdManager.cs` that wraps MaxSDK behind a non-Max API) are left untouched — see the wrapper-scoping rule in integrator.md Step 5. **Generated Metica code is split per ad format**: a `MeticaAdService` orchestrator (init + privacy, in one file) plus per-format objects (`MeticaInterstitialAd`/`MeticaRewardedAd`/`MeticaBannerAd`/`MeticaMRecAd`) that own their callbacks (named methods, not lambdas — game extends by adding lines), auto-reload-on-hidden + `OnAdShowFailed`-recovery (interstitial/rewarded), `IsReady`-guarded show, and **docs-verbatim exponential-backoff retry on load failure** (`Math.Pow(2, Math.Min(6, attempt))` → 2→4→8…→64s, interstitial/rewarded only — banner/MRec have no app-side retry, the SDK refreshes them internally; banner/MRec instead carry `OnApplicationFocus` pause/resume + an `_isShowing` state flag). All four per-format adapters are `MonoBehaviour`s so Interstitial/Rewarded can host `Invoke(nameof(Load), …)`; the orchestrator `AddComponent`s each onto the bootstrap MonoBehaviour's GameObject and calls `Initialize(adUnitId)`. All four formats live in `scripts/templates/standalone/`. The namespace defaults to `<dominant>.Metica` when the project has a dominant namespace, no wrapper at all when the project doesn't use namespaces, and the neutral `MeticaIntegration` when namespaces exist but none dominate — **never** `Metica.AbTest` (that label is reserved for the plugin templates' placeholder). Adapters land under `Assets/Scripts/Metica/` by default.

**MeticaSDK install is enforced, never performed.** The integrator does not download or import the SDK. The compat-checker's `metica_sdk` row BLOCKs if it's missing; the user imports it once, then re-runs. `scripts/download-metica-sdk.sh` exists only as a helper the integrator may *offer*.

## Design principles

Two principles drive most decisions here — preserve both when extending the plugin.

**Balance prose against scripting.** Deterministic, repeatable logic goes in a `scripts/*.sh` with a test (and a golden where the output is fixed) — that's why compat detection, validation, and report formatting are scripts fronted by thin agents. Logic that is a one-off judgment the user reviews anyway stays in the agent prose, intentionally unscripted: the integrator's namespace and remote-config detection (integrator.md Step 2.5) runs inline in the agent — not as a tested script — *because* "perfect precision isn't required; the user approves the detected value in the plan." When adding behavior, place it on the correct side: don't script a judgment call, and don't bury testable logic in a prompt where it can't be covered by a golden.

**Generated code conforms to the host game, not to us.** Codegen adapts to the project it lands in — it wraps files in the project's dominant namespace (+ `.Metica`), or omits the namespace wrapper entirely when the project doesn't use namespaces; uses the detected adapter folder; reuses existing Max ad unit IDs; and (when a remote-config provider is detected) tailors the Step 7 cohort-gating recipe to that provider rather than emitting a router/binding. The canonical *shape* of the per-format adapters lives in `scripts/templates/standalone/*.cs.tmpl`: edit the template, never hand-write C# in the agent prompt. The conform-to-project mechanics live in integrator.md (Steps 2.5 and 5) — keep this file pointing there rather than restating them, so the two can't drift.

## Key conventions

- **`metica-versions.yaml` is the single source of truth** for the compatibility matrix. The compat-checker reads it. Add a new SDK by adding an entry and bumping `latest:`. `metica-versions.dev.yaml` is a gitignored local override.
- **String-literal-aware grepping.** Source scans pipe `grep` through `scripts/lib/clean-cs.awk` to ignore matches inside C# comments and string literals. Reuse it rather than raw `grep` when scanning `.cs`.
- **The integrator git-tags `pre-metica-integration`** before any file write (`scripts/git-snapshot.sh`); the documented rollback is `git reset --hard pre-metica-integration`.
- **Bump the plugin version (semver) on every pushed update.** The release version lives in **two** files that must stay in lockstep: `.claude-plugin/plugin.json` (`version`) and `.claude-plugin/marketplace.json` (`metadata.version`) — never let them drift. Every change you push bumps at least the patch; pick the level by user-visible impact: **major** = a break for users or integrators (renaming/removing an agent, changing how agents are invoked or installed, or a breaking JSON-contract *major* bump like `compat-checker/2.x`); **minor** = backward-compatible new capability (a new agent, new script behavior/flag, or a new JSON-contract field — which already triggers a contract *minor* bump, see Architecture); **patch** = bug fixes, refactors, or prose/doc tweaks with no behavior change. This plugin release version is **distinct** from the per-contract schema versions in `agents/contracts.md` — the two move independently.
