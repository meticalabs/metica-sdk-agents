---
name: unity-validator
description: Validate any MeticaSDK integration in a Unity project. Runs rule-based grep checks for privacy-before-init ordering, init count, per-format callback parity, load/show parity, auto-reload-on-hidden, IsReady-guarded show, leftover placeholder credentials, and test-value userIds, plus a compiles-cleanly pass that builds the project in Unity batch-mode and surfaces real CS errors. Reports per-rule PASS/FAIL/ADVISORY/WARN. Can be invoked by the integrator or run standalone against hand-rolled integrations.
tools: Bash
model: sonnet
---

# Metica Unity Validator

Thin wrapper. All rule logic lives in `scripts/validate-integration.sh`; this agent runs it and relays the output.

## Inputs

- `PROJECT` — absolute path to a Unity project root (contains `Assets/`, `ProjectSettings/`).

Validation is uniform — there is no mode input; the checks apply identically whether or not MaxSDK is present.

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

JSON=$(bash "$PLUGIN_DIR/scripts/validate-integration.sh" --project="$PROJECT")
printf '```json\n%s\n```\n' "$JSON"
```

The stdout of this single command is your entire response. Print it verbatim.

**Note on timing:** the `compiles_cleanly` rule launches a Unity batch-mode compile when it can locate the editor (via `UNITY_PATH` or the project's editor version), so a real run can take **a few minutes** on first import. This is intended — it is the authoritative build check. It self-skips to a non-blocking `WARN` when no Unity is found or when `METICA_SKIP_COMPILE=1` is set; it never blocks on a missing toolchain. Do not add your own timeout or kill the command early.

## Output contract

A single fenced ```` ```json ```` block. No human pre-summary at this stage — the orchestrator (integrator) parses the JSON and composes its own user-facing report. A dedicated `format-validator-report.sh` may be added later if the validator is invoked standalone by users.

**Hard rules:**

- After the closing ``` of the JSON block, output **nothing** — not a sentence, not a newline-prefixed comment, not "Done."
- Do **not** mention the substring ```` ```json ```` anywhere else in your response. Only one ```` ```json ```` fence may appear.
- Do **not** rewrite rule details or interpret levels. The orchestrator parses the JSON.
- If the script exits non-zero with an `error` field, your response is still the same pipeline output. Do nothing extra.

## Independence

The validator must run in a **fresh subagent context** — it must not see the integrator's reasoning. Input is the file tree only.

## Rule set (`validator/1.1.0`)

For the full canonical schema, see [`agents/contracts.md`](contracts.md).

- `init_count` — exactly one `MeticaSdk.Initialize(`
- `privacy_before_init` — both `SetHasUserConsent` and `SetDoNotSell` before `Initialize` (same-file ordering, regardless of MaxSDK presence)
- `<format>_callbacks_subscribed` — for each used ad format (banner/interstitial/rewarded/mrec), OnAdLoadSuccess + OnAdLoadFailed subscribed
- `rewarded_reward_callback` — conditional FAIL if rewarded used but `OnAdRewarded` missing
- `<format>_load_show_parity` — every Load has a matching Show somewhere (banner/interstitial/rewarded/mrec)
- `interstitial_reload_on_hidden` / `rewarded_reload_on_hidden` — FAIL if the format is used but `OnAdHidden` is not subscribed (auto-reload loop)
- `interstitial_show_failed_subscribed` / `rewarded_show_failed_subscribed` — FAIL if the format is used but `OnAdShowFailed` is not subscribed (the reload-on-hidden loop stalls on show-fail because `OnAdHidden` doesn't fire then)
- `interstitial_show_ready_guard` / `rewarded_show_ready_guard` — ADVISORY if `Show` is called without an `IsReady` check
- `revenue_callback_subscribed` — ADVISORY only
- `placeholder_ids_replaced` — FAIL when `"YOUR_METICA_API_KEY"` / `"YOUR_METICA_APP_ID"` / `"YOUR_MAX_SDK_KEY"` / `"REPLACE_ME"` appear as string literal values (comments stripped, identifier names ignored)
- `user_id_not_test_value` — FAIL when the 3rd positional arg of `MeticaInitConfig(api, app, userId)` is `null`, empty string, or matches `(?i)test|debug|dummy|placeholder` as a delimited word, or is digits-only. Handles `@"..."`, `$"..."`, `$@"..."`, `@$"..."` verbatim/interpolated forms too
- `mrec_callbacks_subscribed` / `mrec_load_show_parity` — same shape as the banner/interstitial/rewarded rules (note SDK casing: `MeticaSdk.Ads.LoadMrec` / `MeticaAdsCallbacks.Mrec.*`, lowercase `r`)
- `compiles_cleanly` *(1.1.0)* — compiles the whole project in Unity batch-mode (via `scripts/compile-check.sh`) and emits one FAIL per `error CS####` with file:line; PASS when it builds clean; WARN (non-blocking) when skipped (no Unity located / `METICA_SKIP_COMPILE=1`) or when Unity can't complete. This is the catch-all for compile errors — including the issue #8 docs-transcription bugs (unqualified nested enum, wrong property casing) — so there are no per-bug string rules

These checks live in the validator (not just in the integrator's report) because the validator's role is to lint **any** integration — including hand-rolled code, post-edit drift, and CI re-runs — not just the integrator's first-pass output.
