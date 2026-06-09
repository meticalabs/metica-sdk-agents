#!/usr/bin/env bash
# check-for-update.sh — SessionStart hook: tell the user when a newer
# metica-sdk-agents is published.
#
# Wired from hooks/hooks.json as the plugin's SessionStart command hook. It
# compares the locally-installed plugin version (.claude-plugin/plugin.json)
# against the latest published one (the same file on the repo's default branch)
# and, only when the remote is strictly newer, prints a SessionStart
# `additionalContext` notice that Claude Code surfaces to the user.
#
# This is one of the few things that genuinely needs a script, not agent prose:
# a deterministic network fetch + semver compare on a fixed schedule (session
# start), with hard fail-open semantics so it can never block or nag.
#
# Fail-open by design — ANY uncertainty (no curl, no network, a 404, a malformed
# version, an unreadable manifest) exits 0 with NO output. The check is best
# effort; a missed notice is fine, a broken session start is not.
#
# Escape hatches / overrides (all optional):
#   METICA_SKIP_UPDATE_CHECK=1   — disable the check entirely (silent exit 0).
#   METICA_UPDATE_URL=<url>       — override the "latest" manifest URL (tests).
#   METICA_UPDATE_TIMEOUT=<secs>  — curl timeout (default 3).
#   CLAUDE_PLUGIN_ROOT=<dir>      — plugin root (Claude Code sets this for hooks;
#                                   we self-locate from this script if it is unset).

set -u

# Opt-out: silent no-op.
[ "${METICA_SKIP_UPDATE_CHECK:-}" = "1" ] && exit 0

DEFAULT_URL="https://raw.githubusercontent.com/meticalabs/metica-sdk-agents/main/.claude-plugin/plugin.json"
URL="${METICA_UPDATE_URL:-$DEFAULT_URL}"
TIMEOUT="${METICA_UPDATE_TIMEOUT:-3}"

is_root() { [ -f "$1/.claude-plugin/plugin.json" ]; }

# Locate the plugin root: env var first (Claude Code exports it to hooks), then
# self-location two levels up from this script (<root>/scripts/check-for-update.sh).
ROOT=""
if [ "${CLAUDE_PLUGIN_ROOT:-}" != "" ] && is_root "$CLAUDE_PLUGIN_ROOT"; then
    ROOT="$CLAUDE_PLUGIN_ROOT"
else
    self_src="${BASH_SOURCE[0]:-$0}"
    cand="$(cd "$(dirname "$self_src")/.." 2>/dev/null && pwd || true)"
    [ -n "$cand" ] && is_root "$cand" && ROOT="$cand"
fi
[ -n "$ROOT" ] || exit 0

# Extract the first "version": "x.y.z" string value from a plugin.json on stdin.
extract_version() {
    sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"([0-9]+\.[0-9]+\.[0-9]+[^"]*)".*/\1/p' \
        | head -n1
}

LOCAL_VER="$(extract_version < "$ROOT/.claude-plugin/plugin.json" 2>/dev/null || true)"
[ -n "$LOCAL_VER" ] || exit 0

# Need curl to fetch the latest manifest; absent → silent no-op.
command -v curl >/dev/null 2>&1 || exit 0

REMOTE_JSON="$(curl -fsS --max-time "$TIMEOUT" "$URL" 2>/dev/null || true)"
[ -n "$REMOTE_JSON" ] || exit 0
REMOTE_VER="$(printf '%s' "$REMOTE_JSON" | extract_version)"
[ -n "$REMOTE_VER" ] || exit 0

# Strictly-newer test via version sort. Equal or older → nothing to say.
[ "$REMOTE_VER" = "$LOCAL_VER" ] && exit 0
higher="$(printf '%s\n%s\n' "$LOCAL_VER" "$REMOTE_VER" | sort -V 2>/dev/null | tail -n1)"
[ "$higher" = "$REMOTE_VER" ] || exit 0

# Remote is newer — surface the notice. additionalContext is a single-line,
# double-quote-free string, so it is safe to splice into the JSON directly.
MSG="metica-sdk-agents update available: v${LOCAL_VER} installed, v${REMOTE_VER} published. Update with '/plugin marketplace update metica-sdk-agents' then '/reload-plugins'. (Silence this check with METICA_SKIP_UPDATE_CHECK=1.)"
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$MSG"
exit 0
