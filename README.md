# metica-sdk-agents

Claude Code subagents that integrate [MeticaSDK](https://github.com/meticalabs/metica-unity-package) into Unity projects in one pass — including projects that already use AppLovin MAX.

The plugin ships three subagents:

| Agent | Role |
|---|---|
| `@agent-metica-unity-compat-checker` | Detects Unity / Java / MaxSDK / Android API / MeticaSDK install. PASS or BLOCK with a precise remediation hint. |
| `@agent-metica-unity-integrator` | Orchestrator. Mode-detects (fresh vs side-by-side), presents a plan, snapshots git, generates code, invokes the validator. |
| `@agent-metica-unity-validator` | Independent verification of any integration. Runs rule-based grep checks for init-count, privacy-before-init, callback parity, etc. |

## Install

The repo is currently private; you'll need access to `meticalabs/metica-sdk-agents` on GitHub. Claude Code discovers subagents from `.claude/agents/`. Most Claude Code versions also recurse into subdirectories, but the safest portable pattern is per-file symlinks. Pick one:

**Project-local** (recommended for first try):

```bash
git clone https://github.com/meticalabs/metica-sdk-agents.git ~/dev/metica-sdk-agents
cd /path/to/your/unity/project
mkdir -p .claude/agents
for f in ~/dev/metica-sdk-agents/agents/unity/*.md; do
    ln -s "$f" .claude/agents/
done
```

**Global** (every project sees the agents):

```bash
git clone https://github.com/meticalabs/metica-sdk-agents.git ~/dev/metica-sdk-agents
mkdir -p ~/.claude/agents
for f in ~/dev/metica-sdk-agents/agents/unity/*.md; do
    ln -s "$f" ~/.claude/agents/
done
```

Verify by launching Claude Code from the project directory and typing `/agents` — you should see `metica-unity-compat-checker`, `metica-unity-integrator`, and `metica-unity-validator`.

## Quick start

In Claude Code, from your Unity project's root:

```
@agent-metica-unity-integrator

PROJECT=/absolute/path/to/your/unity/project
PLUGIN_DIR=/absolute/path/to/metica-sdk-agents
```

Optional inputs:

| Name | Default | Notes |
|---|---|---|
| `API_KEY` | `YOUR_METICA_API_KEY` | Metica API key |
| `APP_ID` | `YOUR_METICA_APP_ID` | Metica App ID |
| `MAX_SDK_KEY` | `YOUR_MAX_SDK_KEY` | Existing AppLovin MAX SDK key (side-by-side only) |
| `FORMATS` | `interstitial` | Comma-sep: `banner,interstitial,rewarded` (fresh mode only) |
| `VERSION` | `latest:` in `metica-versions.yaml` | Target MeticaSDK version |

The integrator runs in 7 steps:

1. **Compat-check** — Unity ≥ 2021.3, Java ≥ 11, MaxSDK ≥ 8.2.0 (when present), Android API ≥ 23, MeticaSDK installed. Any FAIL → BLOCK with a specific remediation (e.g. the GitHub Releases URL if MeticaSDK isn't imported yet).
2. **Mode detection** — multi-signal: `Assets/MaxSdk/` folder, `MaxSdk.Initialize(` symbol, AppLovin manifest entry. Two-of-three → side-by-side; else fresh.
3. **Plan presentation** — Claude Code plan mode (or plain-text fallback) lists files to create / edit. You approve.
4. **Git snapshot** — tags `pre-metica-integration` for one-command rollback.
5. **Codegen** — fresh mode writes `Assets/Scripts/MeticaBootstrap.cs`; side-by-side writes 4 files under `Assets/Scripts/Metica/` (`IAdService`, `MaxAdService`, `MeticaAdService`, `AdServiceRouter`, all in `namespace Metica.AbTest`). Existing `Assets/MaxSdk/` is **never** modified.
6. **Validator** — runs independent grep checks: `init_count`, `privacy_before_init`, per-format callbacks subscribed, load/show parity, `ad_service_router_present` (side-by-side), etc.
7. **Final report** — mode, SDK version, files changed, validator summary, rollback command (if anything failed), placeholder reminders, and (side-by-side only) a Max-callsite inventory with proposed rewrites you can ask the agent to apply.

## What the side-by-side codegen does *not* do automatically

It deliberately stops short of touching your game code. The integrator's final report lists:

- **Max callsites** — every `MaxSdk.*` and `MaxSdkCallbacks.*` location, categorized as `bootstrap` / `method_call` / `callback_subscription`. You can ask the integrator to refactor them via the `IAdService` interface; it does this file-by-file in plan mode.
- **Bootstrap rewrite** — the existing `MaxSdk.SetSdkKey + MaxSdk.InitializeSdk()` pair becomes `ads.SetHasUserConsent + ads.SetDoNotSell + ads.Initialize(callback)` in the same file. The integrator will propose the edit.
- **Rollout source** — `AdServiceRouter` ships with a `static Func<bool> RolloutDecisionFunc` you wire to Firebase Remote Config (or your equivalent). Don't hardcode the rollout in production builds. Example wiring is in the generated `AdServiceRouter.cs`.

## Compatibility matrix

Defined in `metica-versions.yaml` (single source of truth):

| MeticaSDK | Unity | Java | MAX | Android API |
|---|---|---|---|---|
| 2.4.0 (latest) | ≥ 2021.3 | ≥ 11 | ≥ 8.2.0 | ≥ 23 |
| 2.2.7 | ≥ 2021.3 | ≥ 11 | ≥ 8.0.0 | ≥ 23 |

The compat-checker reads this file. To add a new SDK version, add an entry and bump `latest:`.

## Running the tests

```bash
cd ~/dev/metica-sdk-agents
bash tests/run-all.sh
```

Eight independent suites: `compat`, `format`, `download`, `validator`, `mode`, `codegen-fresh`, `codegen-sidebyside`, `scan-max-callsites`. 106 assertions total.

A few suites probe a sibling project under `../max-agent-test/DemoApp` for "real-world" assertions and silently skip when absent. On a fresh clone those rows skip cleanly; the synthetic-fixture suites all run.

## Repo layout

```
metica-sdk-agents/
├── plugin.json
├── metica-versions.yaml             # compat matrix
├── agents/
│   ├── contracts.md                 # JSON schemas for sub-agent outputs
│   └── unity/
│       ├── metica-unity-compat-checker.md
│       ├── metica-unity-integrator.md
│       └── metica-unity-validator.md
├── scripts/
│   ├── detect-compat.sh
│   ├── detect-mode.sh
│   ├── format-compat-report.sh
│   ├── validate-integration.sh
│   ├── scan-max-callsites.sh
│   ├── codegen-fresh.sh
│   ├── codegen-sidebyside.sh
│   ├── download-metica-sdk.sh       # opt-in; not used by the default flow
│   ├── git-snapshot.sh
│   ├── lib/clean-cs.awk
│   └── templates/sidebyside/        # the 4 .cs.tmpl files
├── references/
│   ├── migrate-ab-testing.md        # the side-by-side codegen's source-of-truth
│   ├── max-vs-metica-2.4.0-api.md
│   └── unity-sdk-api.md
└── tests/                           # 7 test scripts + fixtures + goldens
```

## Rollback

The integrator tags `pre-metica-integration` before any change. If anything looks wrong:

```bash
git reset --hard pre-metica-integration
```

This removes all generated files but does **not** delete the downloaded `.unitypackage` (it's gitignored). To clean that too: `rm -f Assets/MeticaSDK-*.unitypackage`.

## License

Apache License 2.0 — see [LICENSE](./LICENSE).

## Support

Issues and feedback: https://github.com/meticalabs/metica-sdk-agents/issues — `dev@metica.com`.
