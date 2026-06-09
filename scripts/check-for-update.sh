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

# Extract the first strict "version": "x.y.z" string value from a plugin.json on
# stdin. Only a clean three-part numeric version is captured; anything else
# (pre-release suffixes, missing field) yields empty and fails the check open.
extract_version() {
    sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/p' \
        | head -n1
}

# ver_gt A B → true (exit 0) when A is a strictly-newer x.y.z than B. Pure bash
# numeric compare — no `sort -V`, which is GNU-only and absent on BSD/macOS
# (where it would error out and silently suppress the notice).
ver_gt() {
    local a1 a2 a3 b1 b2 b3
    IFS=. read -r a1 a2 a3 <<<"$1"
    IFS=. read -r b1 b2 b3 <<<"$2"
    # Coerce each segment to a base-10 int (strips leading zeros, defaults a
    # missing field to 0) so a segment like "08" can't trip arithmetic and leak
    # "integer expression expected" to stderr — preserving silent fail-open.
    a1=$((10#${a1:-0})); a2=$((10#${a2:-0})); a3=$((10#${a3:-0}))
    b1=$((10#${b1:-0})); b2=$((10#${b2:-0})); b3=$((10#${b3:-0}))
    (( a1 != b1 )) && { (( a1 > b1 )); return; }
    (( a2 != b2 )) && { (( a2 > b2 )); return; }
    (( a3 > b3 ))
}

LOCAL_VER="$(extract_version < "$ROOT/.claude-plugin/plugin.json" 2>/dev/null || true)"
[ -n "$LOCAL_VER" ] || exit 0

# Need curl to fetch the latest manifest; absent → silent no-op.
command -v curl >/dev/null 2>&1 || exit 0

REMOTE_JSON="$(curl -fsS --max-time "$TIMEOUT" "$URL" 2>/dev/null || true)"
[ -n "$REMOTE_JSON" ] || exit 0
REMOTE_VER="$(printf '%s' "$REMOTE_JSON" | extract_version)"
[ -n "$REMOTE_VER" ] || exit 0

# Equal or older → nothing to say. Only a strictly-newer remote notifies.
ver_gt "$REMOTE_VER" "$LOCAL_VER" || exit 0

# Remote is newer — surface the notice. additionalContext is a single-line,
# double-quote-free string, so it is safe to splice into the JSON directly.
MSG="metica-sdk-agents update available: v${LOCAL_VER} installed, v${REMOTE_VER} published. Update with '/plugin marketplace update metica-sdk-agents' then '/reload-plugins'. (Silence this check with METICA_SKIP_UPDATE_CHECK=1.)"
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$MSG"
exit 0
