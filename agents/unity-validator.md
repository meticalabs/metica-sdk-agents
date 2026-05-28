---
name: unity-validator
description: Validate any MeticaSDK integration in a Unity project. Runs rule-based grep checks for privacy-before-init ordering, init count, per-format callback parity, load/show parity, auto-reload-on-hidden, IsReady-guarded show, leftover placeholder credentials, and test-value userIds. Reports per-rule PASS/FAIL/ADVISORY. Can be invoked by the integrator or run standalone against hand-rolled integrations.
tools: Bash
model: sonnet
---

# Metica Unity Validator

Thin wrapper. All rule logic lives in `scripts/validate-integration.sh`; this agent runs it and relays the output.

## Inputs

- `PROJECT` — absolute path to a Unity project root (contains `Assets/`, `ProjectSettings/`).
- `MODE` — optional `fresh` or `straight-swap`. When omitted, the script auto-detects from project contents (presence of `MaxSdk.*` → straight-swap, otherwise fresh). `--mode=side-by-side` is accepted as a deprecated alias for `straight-swap` (v0.3.x back-compat; the router stack is no longer generated).

## What to do — run this single bash command

Resolve `PLUGIN_DIR` automatically via the shared resolver. Do not ask the user for it. `$CLAUDE_PLUGIN_ROOT` is **not** reliably present in an agent's bash environment, so the loop below searches known install locations (including the **newest** cached marketplace version) for the resolver, then lets it self-verify the root.

```bash
PLUGIN_DIR=""
for cand in "${CLAUDE_PLUGIN_ROOT:-}" "${METICA_SDK_AGENTS_DIR:-}" \
            "$(ls -d "$HOME"/.claude/plugins/cache/*/metica-sdk-agents/* 2>/dev/null | sort -V 2>/dev/null | tail -1)" \
            "$HOME"/.claude/plugins/cache/*/metica-sdk-agents/* \
            "$HOME/.claude/plugins/marketplaces/metica-sdk-agents" \
            "$HOME/.claude/plugins/metica-sdk-agents" \
            "$HOME/.metica-sdk-agents" "$HOME/dev/metica-sdk-agents"; do
    [ -n "$cand" ] && [ -f "$cand/scripts/resolve-plugin-dir.sh" ] || continue
    PLUGIN_DIR="$(bash "$cand/scripts/resolve-plugin-dir.sh" 2>/dev/null)" && [ -n "$PLUGIN_DIR" ] && break
done
[ -n "$PLUGIN_DIR" ] || { echo "Could not locate metica-sdk-agents plugin root. Set METICA_SDK_AGENTS_DIR to the plugin path and retry." >&2; exit 1; }

PROJECT="<absolute_project_path>"
MODE_ARG=""   # or "--mode=fresh" / "--mode=straight-swap"

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
- `privacy_before_init` — both `SetHasUserConsent` and `SetDoNotSell` before `Initialize` (same-file ordering, both modes)
- `<format>_callbacks_subscribed` — for each used ad format, OnAdLoadSuccess + OnAdLoadFailed subscribed
- `rewarded_reward_callback` — conditional FAIL if rewarded used but `OnAdRewarded` missing
- `<format>_load_show_parity` — every Load has a matching Show somewhere
- `interstitial_reload_on_hidden` / `rewarded_reload_on_hidden` — FAIL if the format is used but `OnAdHidden` is not subscribed (auto-reload loop)
- `interstitial_show_ready_guard` / `rewarded_show_ready_guard` — ADVISORY if `Show` is called without an `IsReady` check
- `revenue_callback_subscribed` — ADVISORY only
- `placeholder_ids_replaced` — FAIL when `YOUR_METICA_API_KEY` / `YOUR_METICA_APP_ID` / `YOUR_MAX_SDK_KEY` / `REPLACE_ME` literals appear in source (comments stripped)
- `user_id_not_test_value` — FAIL when the 3rd positional arg of `MeticaInitConfig(api, app, userId)` is `null`, empty string, or matches `(?i)test|debug|dummy|placeholder`, or is a digits-only string

These checks live in the validator (not just in the integrator's report) because the validator's role is to lint **any** integration — including hand-rolled code, post-edit drift, and CI re-runs — not just the integrator's first-pass output. `ad_service_router_present` was removed in `validator/1.1.0` and the router stack was retired entirely in v0.5.0.
