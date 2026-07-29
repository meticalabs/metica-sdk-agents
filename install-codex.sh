#!/usr/bin/env bash
# Install the Metica custom agents and ad-log-monitor skill for Codex.
#
# Usage:
#   bash install-codex.sh
#
# The installer links this checkout into the user's Codex configuration so
# updates to the checkout are picked up without copying prompt files.

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_CONFIG_DIR="${CODEX_HOME:-${HOME}/.codex}"
AGENTS_DEST="${CODEX_CONFIG_DIR}/agents"
SKILLS_DEST="${CODEX_CONFIG_DIR}/skills"
PLUGIN_LINK="${HOME}/.metica-sdk-agents"

link_component() {
    src="$1"
    dest="$2"

    if [ -L "$dest" ]; then
        if [ ! -e "$dest" ]; then
            rm -f "$dest"
        elif [ "$dest" -ef "$src" ]; then
            rm -f "$dest"
        else
            echo "Error: refusing to replace unrelated symlink at $dest" >&2
            exit 1
        fi
    elif [ -e "$dest" ]; then
        echo "Error: refusing to replace existing path at $dest" >&2
        exit 1
    fi

    ln -s "$src" "$dest"
}

for name in \
    metica_unity_compat_checker.toml \
    metica_unity_integrator.toml \
    metica_unity_validator.toml; do
    if [ ! -f "${PLUGIN_DIR}/codex/agents/${name}" ]; then
        echo "Error: missing codex/agents/${name}; run this installer from a complete metica-sdk-agents checkout." >&2
        exit 1
    fi
done

if [ ! -f "${PLUGIN_DIR}/agents/unity-integrator.md" ] \
    || [ ! -f "${PLUGIN_DIR}/skills/ad-log-monitor/SKILL.md" ]; then
    echo "Error: run this installer from a complete metica-sdk-agents checkout." >&2
    exit 1
fi

mkdir -p "$AGENTS_DEST" "$SKILLS_DEST"

link_component "$PLUGIN_DIR" "$PLUGIN_LINK"

linked=0
for src in "${PLUGIN_DIR}"/codex/agents/*.toml; do
    name="$(basename "$src")"
    link_component "$src" "${AGENTS_DEST}/${name}"
    linked=$((linked + 1))
done

link_component "${PLUGIN_DIR}/skills/ad-log-monitor" "${SKILLS_DEST}/ad-log-monitor"

echo "Linked $linked Metica custom agents into $AGENTS_DEST"
echo "Linked ad-log-monitor into $SKILLS_DEST"
echo ""
echo "Done. Start a new Codex task, then ask for:"
echo "    metica_unity_integrator"
echo "    metica_unity_compat_checker"
echo "    metica_unity_validator"
