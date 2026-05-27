#!/usr/bin/env bash
# One-line installer for metica-sdk-agents.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/meticalabs/metica-sdk-agents/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/meticalabs/metica-sdk-agents/main/install.sh | bash -s -- --global
#   bash install.sh [--global] [--clone-dir PATH] [--project PATH]
#
# Default: project-local install into ./.claude/agents/ (clone goes to ~/.metica-sdk-agents).
# --global: user-wide install into ~/.claude/agents/.

set -euo pipefail

REPO_URL="${METICA_SDK_AGENTS_REPO:-https://github.com/meticalabs/metica-sdk-agents.git}"
CLONE_DIR="${HOME}/.metica-sdk-agents"
SCOPE="project"
PROJECT_DIR="$(pwd)"

while [ $# -gt 0 ]; do
    case "$1" in
        --global)        SCOPE="global"; shift ;;
        --project)       SCOPE="project"; shift; PROJECT_DIR="$1"; shift ;;
        --project=*)     SCOPE="project"; PROJECT_DIR="${1#--project=}"; shift ;;
        --clone-dir)     shift; CLONE_DIR="$1"; shift ;;
        --clone-dir=*)   CLONE_DIR="${1#--clone-dir=}"; shift ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            exit 2 ;;
    esac
done

case "$SCOPE" in
    project) AGENTS_DEST="${PROJECT_DIR}/.claude/agents" ;;
    global)  AGENTS_DEST="${HOME}/.claude/agents" ;;
esac

if [ ! -d "$CLONE_DIR/.git" ]; then
    echo "Cloning metica-sdk-agents into ${CLONE_DIR}..."
    git clone --depth=1 "$REPO_URL" "$CLONE_DIR"
else
    echo "Updating existing clone at ${CLONE_DIR}..."
    git -C "$CLONE_DIR" fetch --depth=1 origin main
    git -C "$CLONE_DIR" reset --hard origin/main
fi

if [ ! -d "$CLONE_DIR/agents/unity" ]; then
    echo "Error: agents/unity not found under $CLONE_DIR" >&2
    exit 1
fi

mkdir -p "$AGENTS_DEST"

# Remove symlinks left by a previous install of THIS plugin (their targets live
# inside our clone dir) so renamed or deleted agents don't linger as stale or
# dangling links. Symlinks from other tools sharing this dir are left untouched.
for dest in "$AGENTS_DEST"/*.md; do
    [ -L "$dest" ] || continue
    case "$(readlink "$dest")" in
        "$CLONE_DIR"/agents/unity/*) rm -f "$dest" ;;
    esac
done

linked=0
for src in "$CLONE_DIR"/agents/unity/*.md; do
    name="$(basename "$src")"
    dest="$AGENTS_DEST/$name"
    if [ -L "$dest" ] || [ -e "$dest" ]; then
        rm -f "$dest"
    fi
    ln -s "$src" "$dest"
    linked=$((linked + 1))
done

echo "Linked $linked agents into $AGENTS_DEST"
echo ""
echo "Done. Open Claude Code in a Unity project and run:"
echo "    @agent-unity-integrator"
echo "    PROJECT=/absolute/path/to/your/unity/project"
