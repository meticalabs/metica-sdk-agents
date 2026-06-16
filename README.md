# metica-sdk-agents

Claude Code subagents and a skill that integrate [MeticaSDK](https://github.com/meticalabs/metica-unity-package) into Unity projects in one pass — including projects that already use AppLovin MAX — and verify integrations at runtime by analysing device logs (Android logcat / iOS idevicesyslog).

## Install

**Via Claude Code marketplace (recommended):**

```
/plugin marketplace add meticalabs/metica-sdk-agents
/plugin install metica-sdk-agents@metica-sdk-agents
```

That's it. Claude Code clones the repo, registers three agents and one skill, and sets `$CLAUDE_PLUGIN_ROOT` for you.

**Verify:** launch Claude Code in your project and type `/agents` — you should see the three Unity agents under the `metica-sdk-agents` plugin. The `ad-log-monitor` skill shows up via `/` autocomplete (`/metica-sdk-agents:ad-log-monitor`) and via natural-language triggers (see "Use the ad-log-monitor skill" below).

## Use the integrator

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

## Use the ad-log-monitor skill

Use this when you have a build on a device and want to QA the runtime ad behaviour. It works for **any** Metica integration — fresh or already shipped — and is built around a **two-route protocol** (record the holdout user, then the trial user, then compare).

**How to trigger it.** Any of these in the main conversation:

| Form | Example |
|---|---|
| Slash (explicit) | `/metica-sdk-agents:ad-log-monitor` |
| Natural language (auto-loads the skill from its description) | "start ad-log monitoring", "capture logcat for ads", "analyse this logcat at `./trial-user-android-….log`", "compare trial vs holdout" |

(A skill is **not** invoked with the `@`-mention syntax used for agents — use the `/` slash form or just a trigger phrase.)

The skill will pick the right phase from your prompt: a bare invocation starts a new capture (Phase 1); "done playing" stops and analyses (Phase 2); "compare" produces the trial-vs-holdout verdict (Phase 3).

**Two-route protocol.** Plan to run it twice on the same device, same build, same network — once for each route — so the comparison is apples-to-apples. Target **~5 interstitials and ~5 rewarded ads** per route.

> "We'll run two captures so we can compare. First with the **holdout user** (control), then with the **trial user** (Metica active). On each run, play until you've seen roughly 5 interstitials and 5 rewarded ads. Don't change device, network, or app version between the two runs."

**Optional baseline (recommended).** Holdout and trial are dev builds *you* provide; you can also capture a third `baseline` route on the **live App Store / Play Store build**. It's not a third A/B arm — it's a fidelity anchor that confirms your holdout dev-build reproduces production before anyone trusts the trial-vs-holdout numbers. The comparison treats it as context only, never as the pass/fail gate.

**Minimal example.** In the main conversation, three turns end-to-end:

```
you  >  /metica-sdk-agents:ad-log-monitor start the holdout capture
claude > [runs log-monitor-start.sh --label=holdout-user, prints session block,
         "now play the game"]
you  >  [plays ~5 interstitials + ~5 rewarded ads, comes back]
       done
claude > [runs log-monitor-stop.sh, reads the log, writes ./holdout-user-analysis.md]
you  >  [swaps to the trial user on the device, repeats: "start the trial capture"
         → play → "done" → analysis lands at ./trial-user-analysis.md]
you  >  compare
claude > [reads both analyses + both raw logs, writes ./compare-trial-vs-holdout.md]
```

If you already have logs from elsewhere and want to skip the capture:

```
you  >  /metica-sdk-agents:ad-log-monitor analyse the 2 existing logs at
        ./holdout-user-android-….log and ./trial-user-android-….log
```

**Output artifacts** (all written to the current working directory; multiple captures coexist by label and timestamp):

| File | Source | What it is |
|---|---|---|
| `./<label>-<platform>-<YYYYMMDDThhmmssZ>.log` | start.sh | Raw capture (Android logcat or iOS syslog) |
| `./<label>.session` | start.sh | Shell-readable handoff state (label/platform/pid/log path). Removed by stop.sh; never sourced. |
| `./<label>-filtered.txt` | the skill | Grep-filtered subset, useful for browsing |
| `./<label>-analysis.md` | the skill | Per-route analysis (stack inventory, per-format stats, network attribution, revenue, floor handoff, load strategy, errors) |
| `./compare-<trial>-vs-<holdout>.md` | the skill | Phase 3 side-by-side verdict with the n=5 caveat |

The Phase 1 script clears the device's main `logcat` buffer for a clean capture — that wipes existing log history for every app on the device, not just the target. The skill warns the user before it runs the script.

## The four components

| Name                                        | Type  | Role                                                                                                                                |
| ------------------------------------------- | ----- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `@metica-sdk-agents:unity-compat-checker`   | Agent | Detects Unity / Java / MaxSDK / Android API / MeticaSDK install. PASS or BLOCK with a precise remediation hint.                     |
| `@metica-sdk-agents:unity-integrator`       | Agent | Orchestrator. Discovers whether MaxSDK is present, presents a plan, snapshots git, generates code, invokes the validator.           |
| `@metica-sdk-agents:unity-validator`        | Agent | Independent verification of any integration. Reads the project's code and reasons about every rule (structural + behavioral); behavioral verdicts carry line-cited evidence. Plus a Unity batch compile. |
| `/metica-sdk-agents:ad-log-monitor`         | Skill | Runtime QA on a connected device. Captures Android logcat / iOS idevicesyslog while QA plays, extracts ad unit IDs / network / revenue / lifecycle / Metica→MAX floor handoff, and compares holdout vs trial. |

Most users only ever invoke the integrator. The compat-checker and validator are called by the integrator automatically (and are available standalone if you want to spot-check an existing integration). The `ad-log-monitor` skill is a separate runtime-QA workflow — invoke it directly when you have a build on a device.

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

Test suites cover the scripts: `resolver`, `download`, `compile`, `update-check`, and `log-monitor`. The verification logic lives in agent prose (reviewed by the user at run time), so it is not golden-tested.

The `download` suite needs a local SDK build at `../Metica SDK builds/MeticaSdk-2.4.0.unitypackage` and silently skips when it's absent; the other four run on any clean clone.

## Repo layout

```
metica-sdk-agents/
├── .claude-plugin/
│   ├── marketplace.json               # Claude Code marketplace manifest
│   └── plugin.json                    # plugin manifest
├── install.sh                         # one-line installer
├── metica-versions.yaml               # compat matrix
├── hooks/
│   └── hooks.json                     # SessionStart update-notify hook
├── agents/
│   ├── contracts.md                   # JSON schemas for sub-agent outputs
│   ├── unity-compat-checker.md
│   ├── unity-integrator.md
│   └── unity-validator.md
├── skills/
│   └── ad-log-monitor/
│       └── SKILL.md                   # runtime ad-lifecycle verification + trial-vs-holdout comparison
├── scripts/                           # only what an agent can't do in prose
│   ├── resolve-plugin-dir.sh          # auto-detects plugin root for agents + skill
│   ├── check-for-update.sh            # SessionStart update-notify check
│   ├── compile-check.sh               # batch-mode Unity build behind the validator's compiles_cleanly rule
│   ├── download-metica-sdk.sh         # offered by integrator when compat-check finds MeticaSDK missing
│   ├── log-monitor-start.sh           # ad-log-monitor Phase 1: background capture + health checks
│   ├── log-monitor-stop.sh            # ad-log-monitor Phase 2a: stop capture + summary (analysis is the skill's job, Phase 2b)
│   └── templates/standalone/          # MeticaAdService.cs.tmpl — one MonoBehaviour, per-format @fmt regions
├── references/
│   ├── max-metica-api-map.tsv         # machine-readable MaxSdk → MeticaSdk map; read by both validator + integrator
│   ├── max-vs-metica-2.4.0-api.md     # narrative parity doc (keep in sync with the TSV)
│   └── 3pa-forwarders.md              # canonical 3PA revenue-forwarder shapes
└── tests/                             # 5 suite scripts (+ run-all.sh) + log-monitor fixture
```

## License

Apache License 2.0 — see [LICENSE](./LICENSE).

## Support

Issues and feedback: https://github.com/meticalabs/metica-sdk-agents/issues — `dev@metica.com`.
