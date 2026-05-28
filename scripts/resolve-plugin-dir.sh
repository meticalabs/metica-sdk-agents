#!/usr/bin/env bash
# Print the absolute path of the metica-sdk-agents plugin root (the directory
# containing .claude-plugin/plugin.json) on stdout, or exit non-zero with a
# diagnostic on stderr.
#
# Resolution order:
#   1. $CLAUDE_PLUGIN_ROOT, if set and is a plugin root (explicit override).
#   2. $METICA_SDK_AGENTS_DIR, if set and is a plugin root (env override).
#   3. Self-location: this script lives at <root>/scripts/resolve-plugin-dir.sh,
#      so the root is two levels up from the script file. This is the most
#      reliable source — it works for every install layout and needs no env var.
#      (Note: $CLAUDE_PLUGIN_ROOT is NOT reliably exported into an agent's bash
#      tool environment, which is why self-location, not the env var, is the
#      load-bearing path.)
#   4. The symlink target of either .claude/agents/unity-integrator.md
#      (project-local install) or ~/.claude/agents/unity-integrator.md
#      (global symlink install).
#   5. Common install locations, including the marketplace cache
#      (~/.claude/plugins/cache/*/metica-sdk-agents/*), ~/.claude/plugins/
#      metica-sdk-agents, ~/.metica-sdk-agents, ~/dev/metica-sdk-agents.

set -eu

is_root() { [ -f "$1/.claude-plugin/plugin.json" ] && [ -d "$1/agents" ]; }

# 1. Explicit env var (override; honored first when valid)
if [ "${CLAUDE_PLUGIN_ROOT:-}" != "" ] && is_root "$CLAUDE_PLUGIN_ROOT"; then
    printf '%s\n' "$CLAUDE_PLUGIN_ROOT"
    exit 0
fi

# 2. Explicit env override
if [ "${METICA_SDK_AGENTS_DIR:-}" != "" ] && is_root "$METICA_SDK_AGENTS_DIR"; then
    printf '%s\n' "$METICA_SDK_AGENTS_DIR"
    exit 0
fi

# 3. Self-location from this script's own path (the reliable, env-free path)
self_src="${BASH_SOURCE[0]:-$0}"
self_root="$(cd "$(dirname "$self_src")/.." 2>/dev/null && pwd || true)"
if [ -n "$self_root" ] && is_root "$self_root"; then
    printf '%s\n' "$self_root"
    exit 0
fi

# 4. Resolve from symlinked agent file
resolve_symlink() {
    target=$(readlink "$1" 2>/dev/null || true)
    if [ -n "$target" ]; then
        case "$target" in
            /*) ;;
            *)  target="$(dirname "$1")/$target" ;;
        esac
        candidate=$(cd "$(dirname "$target")/../.." 2>/dev/null && pwd || true)
        if [ -n "$candidate" ] && is_root "$candidate"; then
            printf '%s' "$candidate"
            return 0
        fi
    fi
    return 1
}

for f in \
    "$(pwd)/.claude/agents/unity-integrator.md" \
    "${HOME}/.claude/agents/unity-integrator.md"; do
    if [ -L "$f" ]; then
        if found=$(resolve_symlink "$f"); then
            printf '%s\n' "$found"
            exit 0
        fi
    fi
done

# 5. Known install locations, incl. the marketplace cache. The cache path
#    carries a <marketplace>/<plugin>/<version> layout, so it is globbed; if
#    several versions are cached, the highest (last in version-sorted order)
#    wins. Unmatched globs fall through harmlessly (is_root fails on the
#    literal pattern).
cache_glob=("${HOME}"/.claude/plugins/cache/*/metica-sdk-agents/*)
cache_sorted=()
if [ -e "${cache_glob[0]}" ]; then
    while IFS= read -r line; do cache_sorted+=("$line"); done \
        < <(printf '%s\n' "${cache_glob[@]}" | sort -V -r)
fi
for candidate in \
    "${cache_sorted[@]:-}" \
    "${HOME}/.claude/plugins/metica-sdk-agents" \
    "${HOME}/.claude/plugins/marketplaces/metica-sdk-agents/metica-sdk-agents" \
    "${HOME}/.claude/plugins/marketplaces/metica-sdk-agents" \
    "${HOME}/.metica-sdk-agents" \
    "${HOME}/dev/metica-sdk-agents"; do
    if [ -n "$candidate" ] && is_root "$candidate"; then
        printf '%s\n' "$candidate"
        exit 0
    fi
done

cat >&2 <<EOF
resolve-plugin-dir: could not locate the metica-sdk-agents plugin root.
Tried:
  \$CLAUDE_PLUGIN_ROOT, \$METICA_SDK_AGENTS_DIR,
  self-location (two levels up from this script),
  symlink target of .claude/agents/unity-integrator.md,
  symlink target of ~/.claude/agents/unity-integrator.md,
  ~/.claude/plugins/cache/*/metica-sdk-agents/*,
  ~/.claude/plugins/metica-sdk-agents,
  ~/.metica-sdk-agents, ~/dev/metica-sdk-agents.
Set METICA_SDK_AGENTS_DIR to the absolute path of the plugin root and retry.
EOF
exit 1
