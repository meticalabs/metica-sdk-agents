# metica-sdk-agents

Claude Code subagents that integrate [MeticaSDK](https://github.com/meticalabs/metica-unity-package) into Unity projects in one pass — including projects that already use AppLovin MAX.

## Install

**Via Claude Code marketplace (recommended):**

```
/plugin marketplace add meticalabs/metica-sdk-agents
/plugin install metica-sdk-agents@metica-sdk-agents
```

That's it. Claude Code clones the repo, registers the three agents, and sets `$CLAUDE_PLUGIN_ROOT` for you.

**Verify:** launch Claude Code in your project and type `/agents` — you should see the three agents (listed under the `metica-sdk-agents` plugin if you installed via the marketplace, or as bare `unity-compat-checker` / `unity-integrator` / `unity-validator` if you used the one-line installer).

## Use it

From your Unity project's root in Claude Code, mention the integrator. The name depends on how you installed:

```
# Marketplace install (recommended):
@metica-sdk-agents:unity-integrator
```

That's the whole invocation. The integrator auto-detects the Unity project (walks up from `$(pwd)` looking for `ProjectSettings/`) and fills missing API keys with placeholders you swap in later. You'll be shown a plan and asked to approve before any file is written.

> **Tip:** unsure which form your install registered? Type `@metica-sdk-agent` and let autocomplete show it.

If you're outside the project, or you have several Unity projects in one workspace, pass it explicitly:

```
@agent-metica-sdk-agents:unity-integrator
PROJECT=/absolute/path/to/your/unity/project
```

## The three agents

| Agent                                     | Role                                                                                                                                |
| ----------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `@metica-sdk-agents:unity-compat-checker` | Detects Unity / Java / MaxSDK / Android API / MeticaSDK install. PASS or BLOCK with a precise remediation hint.                     |
| `@metica-sdk-agents:unity-integrator`     | Orchestrator. Discovers whether MaxSDK is present, presents a plan, snapshots git, generates code, invokes the validator.           |
| `@metica-sdk-agents:unity-validator`      | Independent verification of any integration. Runs rule-based grep checks for init-count, privacy-before-init, callback parity, etc. |

Most users only ever invoke the integrator. The compat-checker and validator are called by the integrator automatically (and are available standalone if you want to spot-check an existing integration).

## Compatibility matrix

Defined in `metica-versions.yaml` (single source of truth):

| MeticaSDK      | Unity    | Java | MAX     | Android API |
| -------------- | -------- | ---- | ------- | ----------- |
| 2.4.0 (latest) | ≥ 2021.3 | ≥ 11 | ≥ 8.2.0 | ≥ 23        |
| 2.2.7          | ≥ 2021.3 | ≥ 11 | ≥ 8.0.0 | ≥ 23        |

The compat-checker reads this file. To add a new SDK version, add an entry and bump `latest:`.

## Running the tests

```bash
cd ~/.metica-sdk-agents   # or wherever you cloned
bash tests/run-all.sh
```

Test suites cover: `compat`, `format`, `download`, `validator`, `compile` (compile-check arg/parse/skip paths driven by a fake Unity binary), `codegen` (no-Max and Max-present), `autofix`, `input-validation`, and `resolver`.

A few suites probe a sibling project under `../max-agent-test/DemoApp` for "real-world" assertions and silently skip when absent. On a fresh clone those rows skip cleanly; the synthetic-fixture suites all run.

## Repo layout

```
metica-sdk-agents/
├── .claude-plugin/
│   ├── marketplace.json               # Claude Code marketplace manifest
│   └── plugin.json                    # plugin manifest
├── install.sh                         # one-line installer
├── metica-versions.yaml               # compat matrix
├── agents/
│   ├── contracts.md                   # JSON schemas for sub-agent outputs
│   ├── unity-compat-checker.md
│   ├── unity-integrator.md
│   └── unity-validator.md
├── scripts/
│   ├── resolve-plugin-dir.sh          # auto-detects plugin root for the agents
│   ├── detect-compat.sh
│   ├── format-compat-report.sh
│   ├── validate-integration.sh
│   ├── compile-check.sh               # batch-mode Unity build behind the validator's compiles_cleanly rule
│   ├── validate-keys.sh               # input-validation + escaping helper called by the integrator at codegen time
│   ├── download-metica-sdk.sh         # offered by integrator when compat-check finds MeticaSDK missing
│   ├── git-snapshot.sh
│   ├── lib/                           # shared helpers: clean-source.sh + awk (clean-cs, strip-comments, check-init-userid)
│   └── templates/standalone/          # MeticaAdService.cs.tmpl — one MonoBehaviour, per-format @fmt regions
├── references/
│   └── max-vs-metica-2.4.0-api.md     # MaxSdk ↔ MeticaSdk parity table
└── tests/                             # 9 suite scripts (+ run-all.sh) + fixtures + goldens
```

## License

Apache License 2.0 — see [LICENSE](./LICENSE).

## Support

Issues and feedback: https://github.com/meticalabs/metica-sdk-agents/issues — `dev@metica.com`.
