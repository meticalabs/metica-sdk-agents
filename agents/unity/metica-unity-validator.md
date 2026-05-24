---
name: metica-unity-validator
description: Validate any MeticaSDK integration in a Unity project. Runs rule-based grep checks for privacy-before-init ordering, init count, per-format callback parity, load/show parity, and side-by-side router presence. Reports per-rule PASS/FAIL/ADVISORY. Can be invoked by the integrator or run standalone.
tools: Bash
model: sonnet
---

# Metica Unity Validator

Thin wrapper. All rule logic lives in `scripts/validate-integration.sh`; this agent runs it and relays the output.

## Inputs

- `PROJECT` — absolute path to a Unity project root (contains `Assets/`, `ProjectSettings/`).
- `MODE` — optional `fresh` or `side-by-side`. When omitted, the script auto-detects from project contents.

## What to do — run this single bash command

Resolve `PLUGIN_DIR` automatically via the shared resolver. Do not ask the user for it.

```bash
PLUGIN_DIR="$(bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/metica-sdk-agents}/scripts/resolve-plugin-dir.sh" 2>/dev/null \
    || bash "$HOME/.metica-sdk-agents/scripts/resolve-plugin-dir.sh" 2>/dev/null)"
[ -n "$PLUGIN_DIR" ] || { echo "Could not locate metica-sdk-agents plugin root." >&2; exit 1; }

PROJECT="<absolute_project_path>"
MODE_ARG=""   # or "--mode=fresh" / "--mode=side-by-side"

JSON=$(bash "$PLUGIN_DIR/scripts/validate-integration.sh" --project="$PROJECT" $MODE_ARG)
printf '```json\n%s\n```\n' "$JSON"
```

The stdout of this single command is your entire response. Print it verbatim.

## Output contract

A single fenced ```` ```json ```` block. No human pre-summary at this stage — the orchestrator (integrator) parses the JSON and composes its own user-facing report. A dedicated `format-validator-report.sh` may be added later if the validator is invoked standalone by users.

**Hard rules:**

- After the closing ``` of the JSON block, output **nothing** — not a sentence, not a newline-prefixed comment, not "Done."
- Do **not** mention the substring ```` ```json ```` anywhere else in your response. Only one ```` ```json ```` fence may appear.
- Do **not** rewrite rule details or interpret levels. The orchestrator parses the JSON.
- If the script exits non-zero with an `error` field, your response is still the same pipeline output. Do nothing extra.

## Independence

The validator must run in a **fresh subagent context** — it must not see the integrator's reasoning. Input is the file tree only.

## Rule set (current scope)

- `init_count` — exactly one `MeticaSdk.Initialize(`
- `privacy_before_init` — both `SetHasUserConsent` and `SetDoNotSell` before `Initialize`
- `<format>_callbacks_subscribed` — for each used ad format, OnAdLoadSuccess + OnAdLoadFailed subscribed
- `rewarded_reward_callback` — conditional FAIL if rewarded used but `OnAdRewarded` missing
- `<format>_load_show_parity` — every Load has a matching Show somewhere
- `revenue_callback_subscribed` — ADVISORY only
- `ad_service_router_present` — only checked in side-by-side mode
