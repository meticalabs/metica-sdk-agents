#!/bin/bash
# resolve-sdk-release.sh — read a published MeticaSDK Unity release from GitHub.
#
# Usage:
#   resolve-sdk-release.sh [--version=<x.y.z>]
#
#   Without --version it resolves the release GitHub marks as latest.
#
# Output (stdout, one key=value per line):
#   version=<x.y.z>
#   download_url=<.unitypackage asset URL>
#   sha256=<asset digest>
#   released_at=<YYYY-MM-DD>
#   release_notes_url=<release page URL>
#
# Env:
#   METICA_SDK_RELEASES_API=<url>  releases API base (tests point it at file://).
#   METICA_SDK_RELEASE_TIMEOUT=<s> curl timeout (default 15).
#
# Exit:
#   0 = release resolved, all five fields printed
#   1 = release not reachable, not found, or missing a field

set -u
set -o pipefail

API="${METICA_SDK_RELEASES_API:-https://api.github.com/repos/meticalabs/metica-unity-package/releases}"
TIMEOUT="${METICA_SDK_RELEASE_TIMEOUT:-15}"
VERSION=""

for arg in "$@"; do
    case $arg in
        --version=*) VERSION="${arg#*=}" ;;
        -h|--help)   sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown arg: $arg" >&2; exit 1 ;;
    esac
done

command -v curl >/dev/null 2>&1 || { echo "curl not found" >&2; exit 1; }

if [ -n "$VERSION" ]; then
    ENDPOINT="$API/tags/v$VERSION"
else
    ENDPOINT="$API/latest"
fi

JSON="$(curl -fsSL --max-time "$TIMEOUT" -H 'Accept: application/vnd.github+json' "$ENDPOINT")" || {
    echo "Could not read MeticaSDK release from $ENDPOINT" >&2
    exit 1
}

json_string() {
    printf '%s\n' "$JSON" | sed -nE "s/^[[:space:]]*\"$1\":[[:space:]]*\"([^\"]*)\".*/\1/p"
}

TAG="$(json_string tag_name | head -1)"
PUBLISHED="$(json_string published_at | head -1)"
URL="$(json_string browser_download_url | grep -E '\.unitypackage$' | head -1)"
NOTES="https://github.com/meticalabs/metica-unity-package/releases/tag/$TAG"

# GitHub prints each asset's digest before its browser_download_url.
SHA="$(printf '%s\n' "$JSON" | awk -F'"' '
    $2 == "digest" { digest = $4 }
    $2 == "browser_download_url" && $4 ~ /\.unitypackage$/ { sub(/^sha256:/, "", digest); print digest; exit }
')"

RESOLVED="${TAG#v}"
printf '%s' "$RESOLVED" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "Release at $ENDPOINT has no x.y.z tag (got: '$TAG')" >&2; exit 1; }
[ -n "$URL" ] || { echo "Release $TAG has no .unitypackage asset" >&2; exit 1; }
printf '%s' "$SHA" | grep -Eq '^[0-9a-f]{64}$' || { echo "Release $TAG has no sha256 digest for its .unitypackage asset" >&2; exit 1; }
[ -n "$PUBLISHED" ] || { echo "Release $TAG has no published_at" >&2; exit 1; }

echo "version=$RESOLVED"
echo "download_url=$URL"
echo "sha256=$SHA"
echo "released_at=${PUBLISHED%%T*}"
echo "release_notes_url=$NOTES"
