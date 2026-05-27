#!/usr/bin/env bash
# Print the absolute path of the metica-sdk-agents plugin root (the directory
# containing .claude-plugin/plugin.json) on stdout, or exit non-zero with a
# diagnostic on stderr.
#
# Resolution order:
#   1. $CLAUDE_PLUGIN_ROOT, if set and is a plugin root (marketplace install).
#   2. $METICA_SDK_AGENTS_DIR, if set and is a plugin root (env override).
#   3. The symlink target of either .claude/agents/unity-integrator.md
#      (project-local install) or ~/.claude/agents/unity-integrator.md
#      (global symlink install).
#   4. Common install locations: ~/.claude/plugins/metica-sdk-agents,
#      ~/.metica-sdk-agents, ~/dev/metica-sdk-agents.

set -eu

is_root() { [ -f "$1/.claude-plugin/plugin.json" ] && [ -d "$1/agents" ]; }

# 1. Marketplace-set env var
if [ "${CLAUDE_PLUGIN_ROOT:-}" != "" ] && is_root "$CLAUDE_PLUGIN_ROOT"; then
    printf '%s\n' "$CLAUDE_PLUGIN_ROOT"
    exit 0
fi

# 2. Explicit env override
if [ "${METICA_SDK_AGENTS_DIR:-}" != "" ] && is_root "$METICA_SDK_AGENTS_DIR"; then
    printf '%s\n' "$METICA_SDK_AGENTS_DIR"
    exit 0
fi

# 3. Resolve from symlinked agent file
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

# 4. Known install locations
for candidate in \
    "${HOME}/.claude/plugins/metica-sdk-agents" \
    "${HOME}/.claude/plugins/marketplaces/metica-sdk-agents/metica-sdk-agents" \
    "${HOME}/.metica-sdk-agents" \
    "${HOME}/dev/metica-sdk-agents"; do
    if is_root "$candidate"; then
        printf '%s\n' "$candidate"
        exit 0
    fi
done

cat >&2 <<EOF
resolve-plugin-dir: could not locate the metica-sdk-agents plugin root.
Tried:
  \$CLAUDE_PLUGIN_ROOT, \$METICA_SDK_AGENTS_DIR,
  symlink target of .claude/agents/unity-integrator.md,
  symlink target of ~/.claude/agents/unity-integrator.md,
  ~/.claude/plugins/metica-sdk-agents,
  ~/.metica-sdk-agents, ~/dev/metica-sdk-agents.
Set METICA_SDK_AGENTS_DIR to the absolute path of the plugin root and retry.
EOF
exit 1
