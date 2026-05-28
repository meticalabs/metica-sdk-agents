# metica-sdk-agents

Claude Code subagents that integrate [MeticaSDK](https://github.com/meticalabs/metica-unity-package) into Unity projects in one pass — including projects that already use AppLovin MAX.

## Install

**Via Claude Code marketplace (recommended):**

```
/plugin marketplace add meticalabs/metica-sdk-agents
/plugin install metica-sdk-agents@metica-sdk-agents
```

That's it. Claude Code clones the repo, registers the three agents, and sets `$CLAUDE_PLUGIN_ROOT` for you.

**Via one-line installer** (no marketplace needed):

```bash
# Project-local (only the current Unity project sees the agents):
curl -fsSL https://raw.githubusercontent.com/meticalabs/metica-sdk-agents/main/install.sh | bash

# User-wide (every project sees the agents):
curl -fsSL https://raw.githubusercontent.com/meticalabs/metica-sdk-agents/main/install.sh | bash -s -- --global
```

The script clones into `~/.metica-sdk-agents` and symlinks each agent into `.claude/agents/`.

**Verify:** launch Claude Code in your project and type `/agents` — you should see the three agents (listed under the `metica-sdk-agents` plugin if you installed via the marketplace, or as bare `unity-compat-checker` / `unity-integrator` / `unity-validator` if you used the one-line installer).

## Use it

From your Unity project's root in Claude Code, mention the integrator. The name depends on how you installed:

```
# Marketplace install (recommended):
@agent-metica-sdk-agents:unity-integrator

# One-line installer (symlinks, un-namespaced):
@agent-unity-integrator
```

That's the whole invocation. The integrator auto-detects the Unity project (walks up from `$(pwd)` looking for `ProjectSettings/`) and fills missing API keys with placeholders you swap in later. You'll be shown a plan and asked to approve before any file is written.

> **Tip:** unsure which form your install registered? Type `@agent-` and let autocomplete show it.

If you're outside the project, or you have several Unity projects in one workspace, pass it explicitly:

```
@agent-metica-sdk-agents:unity-integrator
PROJECT=/absolute/path/to/your/unity/project
```

## What it does

The integrator runs in 7 steps:

1. **Compat-check** — Unity ≥ 2021.3, Java ≥ 11, MaxSDK ≥ 8.2.0 (when present), Android API ≥ 23, MeticaSDK installed. Any FAIL → BLOCK with a specific remediation (e.g. the GitHub Releases URL if MeticaSDK isn't imported yet).
2. **Mode detection** — multi-signal: `Assets/MaxSdk/` folder, `MaxSdk.Initialize(` symbol, AppLovin manifest entry. Two-of-three → **straight-swap** (replace Max in the game's *direct* call sites with MeticaSDK; leave any dedicated Max-wrapper file like `AdManager.cs` untouched). Else → **fresh** (no existing ad SDK). When Max is present, Step 2.5 also detects which remote-config provider the project uses — but this drives a **cohort-gating recipe** in the final report (Step 7), not a router/binding artifact. The router stack was retired in v0.5.0; the user wires their own gate against their existing provider.
3. **Plan presentation** — Claude Code plan mode (or plain-text fallback) lists files to create / edit. You approve.
4. **Git snapshot** — tags `pre-metica-integration` for one-command rollback.
5. **Codegen** — both modes generate a `MeticaAdService` orchestrator plus per-format objects (`MeticaInterstitialAd` / `MeticaRewardedAd` / `MeticaBannerAd` / `MeticaMRecAd`) that own each format's callbacks (named methods you can extend — not inline lambdas), auto-reload on hidden (interstitial/rewarded), `IsReady`-guarded `Show()`, and exponential-backoff retry on load failure (1→2→4→8s … capped at 64s, hosted on the bootstrap MonoBehaviour). **Fresh** writes the orchestrator + per-format files under `Assets/Scripts/Metica/` plus a thin `MeticaBootstrap.cs` MonoBehaviour. **Straight-swap** writes the same standalone set and rewrites the game's direct Max call sites to call it directly. Existing `Assets/MaxSdk/` is **never** modified, and dedicated Max-wrapper files are also left alone — only the game's direct call sites are rewritten. The namespace defaults to `<dominant>.Metica` if the project has a dominant namespace, no wrapper when the project uses no namespaces, and `MeticaIntegration` when ambiguous — never `Metica.AbTest`.
6. **Validator** — runs independent grep checks: `init_count`, `privacy_before_init`, per-format callbacks subscribed, load/show parity, `<format>_reload_on_hidden`, `<format>_show_ready_guard`, `placeholder_ids_replaced` (catches leftover `YOUR_*` literals), `user_id_not_test_value` (catches `null`/`"test"`/`"debug"` userId values), etc.
7. **Final report** — mode, SDK version, files changed, validator summary, rollback command (if anything failed), and (straight-swap + remote-config provider detected) a cohort-gating recipe: a copy-paste pattern for reading your provider's boolean key and gating the rewritten call sites behind it.

## Optional inputs

Tune behavior by passing any of these after `PROJECT=...`:

| Name | Default | Notes |
|---|---|---|
| `API_KEY` | `YOUR_METICA_API_KEY` | Metica API key |
| `APP_ID` | `YOUR_METICA_APP_ID` | Metica App ID |
| `MAX_SDK_KEY` | `YOUR_MAX_SDK_KEY` | Existing AppLovin MAX SDK key (straight-swap only — MeticaSDK mediates through MAX) |
| `FORMATS` | `interstitial` | Comma-sep: `banner,interstitial,rewarded,mrec` |
| `USER_ID_EXPR` | `null` | C# expression for `MeticaInitConfig`'s userId arg. Default `null` makes the validator FAIL until you replace it. Common: `SystemInfo.deviceUniqueIdentifier`, `PlayerProfile.PlayerId`. |
| `VERSION` | `latest:` in `metica-versions.yaml` | Target MeticaSDK version |
| `REMOTE_CONFIG_PROVIDER` | auto-detected | `firebase` / `appmetrica` / `unity-remote-config` / `none`. Report-only — drives the Step 7 cohort-gating recipe but does not change generated artifacts. |
| `REMOTE_CONFIG_KEY` | `metica_rollout` | Boolean-typed key name suggested in the cohort-gating recipe. |
| `NAMESPACE` | auto-detected | Explicit namespace for all generated files (overrides project-dominant detection). Pass an empty string to force bare/no-namespace. |
| `ADAPTER_FOLDER` | `Assets/Scripts/Metica` | Explicit project-relative path for the Metica adapter folder (must start with `Assets/`; absolute paths and `..` segments are rejected). |

## The three agents

| Agent | Role |
|---|---|
| `@agent-metica-sdk-agents:unity-compat-checker` | Detects Unity / Java / MaxSDK / Android API / MeticaSDK install. PASS or BLOCK with a precise remediation hint. |
| `@agent-metica-sdk-agents:unity-integrator` | Orchestrator. Mode-detects (fresh vs straight-swap), presents a plan, snapshots git, generates code, invokes the validator. |
| `@agent-metica-sdk-agents:unity-validator` | Independent verification of any integration. Runs rule-based grep checks for init-count, privacy-before-init, callback parity, etc. |

Most users only ever invoke the integrator. The compat-checker and validator are called by the integrator automatically (and are available standalone if you want to spot-check an existing integration).

## What straight-swap does and doesn't do

It rewrites your game's **direct** `MaxSdk.*` call sites (scene/UI/gameplay scripts) to call `MeticaAdService` instead, and deletes the corresponding `MaxSdkCallbacks.*` subscriptions (the per-format objects own those internally now). It does **not**:

- **Touch a dedicated Max-wrapper file** (e.g. `AdManager.cs` / `MaxHelper.cs` whose primary purpose is wrapping MaxSDK). The integrator rewrites the game's call sites to **bypass** the wrapper and call MeticaSDK directly; the orphaned wrapper is yours to delete when you're ready.
- **Touch `Assets/MaxSdk/`** — that's vendored MAX, never modified.
- **Generate any A/B router, `IAdService`, `MaxAdService`, or `MeticaRolloutBinding`** — the router stack was retired in v0.5.0. If you want to roll out gradually, the Step 7 final report includes a copy-paste cohort-gating recipe tailored to your remote-config provider (Firebase / Unity Remote Config / AppMetrica), gating the rewritten call sites behind a boolean flag you add in your provider's dashboard. You wire the gate; the integrator doesn't.

## Compatibility matrix

Defined in `metica-versions.yaml` (single source of truth):

| MeticaSDK | Unity | Java | MAX | Android API |
|---|---|---|---|---|
| 2.4.0 (latest) | ≥ 2021.3 | ≥ 11 | ≥ 8.2.0 | ≥ 23 |
| 2.2.7 | ≥ 2021.3 | ≥ 11 | ≥ 8.0.0 | ≥ 23 |

The compat-checker reads this file. To add a new SDK version, add an entry and bump `latest:`.

## Running the tests

```bash
cd ~/.metica-sdk-agents   # or wherever you cloned
bash tests/run-all.sh
```

Test suites cover: `compat`, `format`, `download`, `validator`, `mode`, `codegen` (fresh and straight-swap modes), `input-validation`, and `resolver`.

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
│   ├── detect-mode.sh
│   ├── format-compat-report.sh
│   ├── validate-integration.sh
│   ├── validate-keys.sh               # input-validation + escaping helper called by the integrator at codegen time
│   ├── download-metica-sdk.sh         # offered by integrator when compat-check finds MeticaSDK missing
│   ├── git-snapshot.sh
│   ├── lib/                           # awk helpers: clean-cs, strip-comments, check-init-userid
│   └── templates/standalone/          # per-format adapter templates (Interstitial, Rewarded, Banner, MRec)
├── references/
│   └── max-vs-metica-2.4.0-api.md     # MaxSdk ↔ MeticaSdk parity table
└── tests/                             # 8 test scripts + fixtures + goldens
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
