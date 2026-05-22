#!/bin/bash
# download-metica-sdk.sh — fetch a MeticaSDK build and place it in a Unity project.
#
# Usage:
#   download-metica-sdk.sh --project=<path> [--version=<x.y.z>]
#                          [--skip-checksum] [--import] [--force] [--dry-run]
#
# Env:
#   METICA_SDK_DEV=1  use local_path from metica-versions.dev.yaml (no network).
#                     Also gates --skip-checksum (refused outside dev mode).
#   UNITY_PATH=<path> absolute path to a specific Unity binary (for --import).
#
# Exit:
#   0 = installed (or planned, if --dry-run)
#   1 = invocation / resolution / verification / install failure

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
YAML="$PLUGIN_DIR/metica-versions.yaml"
DEV_YAML="$PLUGIN_DIR/metica-versions.dev.yaml"

PROJECT=""
VERSION=""
SKIP_CHECKSUM=0
DO_IMPORT=0
FORCE=0
DRY_RUN=0

for arg in "$@"; do
    case $arg in
        --project=*)     PROJECT="${arg#*=}" ;;
        --version=*)     VERSION="${arg#*=}" ;;
        --skip-checksum) SKIP_CHECKSUM=1 ;;
        --import)        DO_IMPORT=1 ;;
        --force)         FORCE=1 ;;
        --dry-run)       DRY_RUN=1 ;;
        -h|--help)
            sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown arg: $arg" >&2; exit 1 ;;
    esac
done

[ -n "$PROJECT" ] || { echo "Missing --project=<path>" >&2; exit 1; }
[ -d "$PROJECT" ] || { echo "Project not found: $PROJECT" >&2; exit 1; }
[ -d "$PROJECT/Assets" ] || { echo "Not a Unity project (no Assets/ dir): $PROJECT" >&2; exit 1; }
[ -f "$YAML" ]    || { echo "YAML not found: $YAML" >&2; exit 1; }

# Refuse --skip-checksum in production. Dev mode only.
if [ "$SKIP_CHECKSUM" = "1" ] && [ "${METICA_SDK_DEV:-0}" != "1" ]; then
    echo "ERROR: --skip-checksum requires METICA_SDK_DEV=1. Refusing in production." >&2
    exit 1
fi

# ---- YAML readers -----------------------------------------------------------

unquote() { sed 's/^"//; s/"$//'; }

yaml_top() {
    grep -E "^$1:[[:space:]]" "$YAML" | head -1 | sed -E "s/^$1:[[:space:]]*//" | unquote
}

yaml_version_field() {
    local ver="$1" field="$2"
    awk -v vkey="\"$ver\":" -v field="$field" '
        $0 == "versions:" { in_v=1; next }
        in_v && $0 ~ /^[^[:space:]]/ { in_v=0 }
        in_v && $0 ~ /^  "/ {
            if ($0 ~ ("^  " vkey "[[:space:]]*$")) { hit=1 } else { hit=0 }
            next
        }
        in_v && hit {
            tag = "    " field ":"
            if (index($0, tag) == 1) {
                v = substr($0, length(tag) + 1)
                sub(/^[[:space:]]+/, "", v)
                print v
                exit
            }
        }
    ' "$YAML" | unquote
}

dev_yaml_local_path() {
    [ -f "$DEV_YAML" ] || return
    local ver="$1"
    awk -v vkey="\"$ver\":" '
        /^local_paths:/ { in_lp=1; next }
        in_lp && $0 ~ /^[^[:space:]]/ { in_lp=0 }
        in_lp && index($0, vkey) {
            tag = "  " vkey
            if (index($0, tag) == 1) {
                v = substr($0, length(tag) + 1)
                sub(/^[[:space:]]+/, "", v)
                print v
                exit
            }
        }
    ' "$DEV_YAML" | unquote
}

# ---- resolve target ---------------------------------------------------------

[ -z "$VERSION" ] && VERSION="$(yaml_top latest)"
[ -n "$VERSION" ] || { echo "Could not resolve version" >&2; exit 1; }

URL="$(yaml_version_field "$VERSION" download_url)"
SHA="$(yaml_version_field "$VERSION" sha256)"
[ -n "$URL" ] || { echo "No download_url for version $VERSION" >&2; exit 1; }
[ -n "$SHA" ] || { echo "No sha256 for version $VERSION" >&2; exit 1; }

LOCAL_PATH=""
if [ "${METICA_SDK_DEV:-0}" = "1" ]; then
    LOCAL_PATH="$(dev_yaml_local_path "$VERSION")"
fi

# ---- existing-install detection --------------------------------------------

EXISTING_PACKAGE=""
EXISTING_DIR=""
# Any other .unitypackage from a previous run
for f in "$PROJECT/Assets/"MeticaSDK-*.unitypackage "$PROJECT/Assets/"MeticaSdk-*.unitypackage; do
    [ -f "$f" ] && EXISTING_PACKAGE="$f"
done
# Imported source folder (best-effort match)
if [ -d "$PROJECT/Assets/Metica" ]; then EXISTING_DIR="$PROJECT/Assets/Metica"; fi
if [ -d "$PROJECT/Assets/MeticaSDK" ]; then EXISTING_DIR="$PROJECT/Assets/MeticaSDK"; fi

# ---- destination & form-factor ---------------------------------------------

TARGET="$PROJECT/Assets/MeticaSDK-$VERSION.unitypackage"
FORM="unitypackage"

# ---- dry-run plan -----------------------------------------------------------

print_plan() {
    echo "PLAN"
    echo "  version       $VERSION"
    if [ -n "$LOCAL_PATH" ]; then
        echo "  source        local: $LOCAL_PATH (METICA_SDK_DEV=1)"
    else
        echo "  source        url:   $URL"
    fi
    echo "  sha256        $SHA"
    if [ "$SKIP_CHECKSUM" = "1" ]; then
        echo "                (verification skipped — METICA_SDK_DEV=1)"
    fi
    echo "  target        $TARGET"
    if [ -n "$EXISTING_PACKAGE" ] || [ -n "$EXISTING_DIR" ]; then
        echo "  existing      $EXISTING_PACKAGE $EXISTING_DIR"
        [ "$FORCE" = "1" ] && echo "                (--force: will overwrite)" \
                           || echo "                (refusing without --force)"
    fi
    if [ "$DO_IMPORT" = "1" ]; then
        echo "  import        enabled — will invoke Unity headless after placement"
    else
        echo "  import        skipped — open project in Unity to import"
    fi
}

if [ "$DRY_RUN" = "1" ]; then
    print_plan
    exit 0
fi

# ---- refuse on existing install without --force ----------------------------

if [ "$FORCE" != "1" ] && { [ -n "$EXISTING_PACKAGE" ] || [ -n "$EXISTING_DIR" ]; }; then
    echo "ERROR: project already has a Metica install." >&2
    [ -n "$EXISTING_PACKAGE" ] && echo "  package: $EXISTING_PACKAGE" >&2
    [ -n "$EXISTING_DIR" ]     && echo "  dir:     $EXISTING_DIR" >&2
    echo "  Pass --force to overwrite." >&2
    exit 1
fi

print_plan

# ---- acquire ----------------------------------------------------------------

TMP="$(mktemp -d -t metica-sdk-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
STAGE="$TMP/sdk.unitypackage"

if [ -n "$LOCAL_PATH" ]; then
    case "$LOCAL_PATH" in
        /*) SRC="$LOCAL_PATH" ;;
        *)  SRC="$PLUGIN_DIR/$LOCAL_PATH" ;;
    esac
    SRC_REAL="$(cd "$(dirname "$SRC")" 2>/dev/null && pwd)/$(basename "$SRC")"
    [ -f "$SRC_REAL" ] || { echo "Local source not found: $SRC_REAL" >&2; exit 1; }
    cp "$SRC_REAL" "$STAGE" || { echo "Copy from local failed" >&2; exit 1; }
    echo "Copied from $SRC_REAL"
else
    command -v curl >/dev/null 2>&1 || { echo "curl not found" >&2; exit 1; }
    echo "Downloading $URL ..."
    if ! curl -fsSL "$URL" -o "$STAGE"; then
        echo "Download failed: $URL" >&2
        exit 1
    fi
fi

# ---- verify -----------------------------------------------------------------

if [ "$SKIP_CHECKSUM" = "0" ]; then
    if command -v shasum >/dev/null 2>&1; then
        GOT="$(shasum -a 256 "$STAGE" | awk '{print $1}')"
    elif command -v sha256sum >/dev/null 2>&1; then
        GOT="$(sha256sum "$STAGE" | awk '{print $1}')"
    else
        echo "Neither shasum nor sha256sum on PATH; cannot verify checksum." >&2
        exit 1
    fi
    if [ "$GOT" != "$SHA" ]; then
        echo "Checksum mismatch:" >&2
        echo "  expected: $SHA" >&2
        echo "  got:      $GOT" >&2
        exit 1
    fi
    echo "Checksum verified."
else
    echo "WARN: Checksum verification skipped (METICA_SDK_DEV=1 + --skip-checksum)." >&2
fi

# ---- install ----------------------------------------------------------------

cp "$STAGE" "$TARGET" || { echo "Failed to copy package into Assets/" >&2; exit 1; }
echo "Placed package: $TARGET"

# ---- optional Unity headless import ----------------------------------------

if [ "$DO_IMPORT" != "1" ]; then
    echo "Skipping Unity import (no --import). Open the project in Unity to import the package."
    exit 0
fi

# Refuse if Unity is already open on this project.
if [ -f "$PROJECT/Temp/UnityLockfile" ]; then
    echo "ERROR: Unity appears to be open on this project (Temp/UnityLockfile present). Close it first." >&2
    exit 1
fi

# Pick a Unity Editor that matches the project's ProjectVersion.txt.
PROJ_VER="$(awk '/^m_EditorVersion:/ { print $2; exit }' "$PROJECT/ProjectSettings/ProjectVersion.txt" 2>/dev/null)"
UNITY_BIN="${UNITY_PATH:-}"
if [ -z "$UNITY_BIN" ] && [ -n "$PROJ_VER" ] && [ -d "/Applications/Unity/Hub/Editor/$PROJ_VER" ]; then
    UNITY_BIN="/Applications/Unity/Hub/Editor/$PROJ_VER/Unity.app/Contents/MacOS/Unity"
fi
if [ -z "$UNITY_BIN" ] || [ ! -x "$UNITY_BIN" ]; then
    echo "ERROR: Could not locate Unity $PROJ_VER under /Applications/Unity/Hub/Editor." >&2
    echo "  Set UNITY_PATH=<absolute path to Unity binary> and rerun, or open the project manually." >&2
    exit 1
fi

echo "Importing via Unity headless ($UNITY_BIN) …"
"$UNITY_BIN" -projectPath "$PROJECT" -importPackage "$TARGET" -quit -batchmode -logFile - || {
    echo "ERROR: Unity headless import failed. Package remains in Assets/ for manual import." >&2
    exit 1
}
echo "Import complete."
