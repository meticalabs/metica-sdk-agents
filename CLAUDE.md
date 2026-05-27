# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is **not application code** — it is a Claude Code *plugin* that ships three Unity sub-agents. The "source" is:

- **Agent definitions** — markdown-with-frontmatter under `agents/unity/`. The frontmatter (`name`, `description`, `tools`, `model`) is the agent's contract; the body is its prompt.
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

**Orchestrator + two thin wrappers.** `metica-unity-integrator` (model: sonnet) is the only agent users invoke directly. It calls `metica-unity-compat-checker` (haiku) and `metica-unity-validator` (sonnet) as sub-agents. The compat-checker and validator do nothing but run a script and print its stdout verbatim — never paraphrase or summarize their output when editing them.

**Agents talk to the orchestrator in versioned JSON.** Each sub-agent's final message ends with a fenced ` ```json ` block. The orchestrator parses **the last** such block (regex in `agents/contracts.md`), never the prose. Schemas are versioned `<name>/<major>.<minor>.<patch>`; the orchestrator accepts any minor/patch within an accepted major. **If you add a field to a script's JSON output, bump the minor and update `agents/contracts.md` — these three move together.** Contracts: `compat-checker/1.x`, `mode-detect/1.x`, `validator/1.x`. The integrator itself emits no JSON.

**`PLUGIN_DIR` resolution is mandatory.** Every agent's first bash command resolves the plugin root via `scripts/resolve-plugin-dir.sh` (checks `$CLAUDE_PLUGIN_ROOT`, `$METICA_SDK_AGENTS_DIR`, agent-symlink targets, known install paths). Scripts are always invoked as `"$PLUGIN_DIR/scripts/..."` — never with relative paths. `resolve-plugin-dir.sh`'s `is_root()` identifies the root by the presence of **`.claude-plugin/plugin.json`** and `agents/unity/`; if you move the manifest, that check (and marketplace install) breaks.

**The integrator's two modes** are the central branch. `scripts/detect-mode.sh` looks for three MaxSDK signals (`Assets/MaxSdk/` folder, `MaxSdk.Initialize(` symbol, AppLovin manifest); two-of-three → **side-by-side**, else **fresh**. Fresh writes a single `MeticaBootstrap.cs`. Side-by-side writes an `IAdService`-based adapter set under `Assets/Scripts/Metica/` (`namespace Metica.AbTest`) and **never touches existing `Assets/MaxSdk/` or game code** — call-site rewrites are only ever *proposed* in the final report, never applied automatically.

**MeticaSDK install is enforced, never performed.** The integrator does not download or import the SDK. The compat-checker's `metica_sdk` row BLOCKs if it's missing; the user imports it once, then re-runs. `scripts/download-metica-sdk.sh` exists only as a helper the integrator may *offer*.

## Design principles

Two principles drive most decisions here — preserve both when extending the plugin.

**Balance prose against scripting.** Deterministic, repeatable logic goes in a `scripts/*.sh` with a test (and a golden where the output is fixed) — that's why compat detection, validation, and report formatting are scripts fronted by thin agents. Logic that is a one-off judgment the user reviews anyway stays in the agent prose, intentionally unscripted: the integrator's namespace and remote-config detection (integrator.md Step 2.5) runs inline in the agent — not as a tested script — *because* "perfect precision isn't required; the user approves the detected value in the plan." When adding behavior, place it on the correct side: don't script a judgment call, and don't bury testable logic in a prompt where it can't be covered by a golden.

**Generated code conforms to the host game, not to us.** Side-by-side codegen adapts to the project it lands in — it wraps files in the project's dominant namespace (+ `.Metica`), uses the detected adapter folder, and matches the existing remote-config provider. The canonical *shape* of that code lives in `scripts/templates/sidebyside/*.cs.tmpl`: edit the template, never hand-write C# in the agent prompt. The conform-to-project mechanics live in integrator.md (Steps 2.5 and 5) — keep this file pointing there rather than restating them, so the two can't drift.

## Key conventions

- **`metica-versions.yaml` is the single source of truth** for the compatibility matrix. The compat-checker reads it. Add a new SDK by adding an entry and bumping `latest:`. `metica-versions.dev.yaml` is a gitignored local override.
- **String-literal-aware grepping.** Source scans pipe `grep` through `scripts/lib/clean-cs.awk` to ignore matches inside C# comments and string literals. Reuse it rather than raw `grep` when scanning `.cs`.
- **The integrator git-tags `pre-metica-integration`** before any file write (`scripts/git-snapshot.sh`); the documented rollback is `git reset --hard pre-metica-integration`.
