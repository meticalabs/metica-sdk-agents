#!/bin/bash
# run-release-tests.sh — unit tests for scripts/resolve-sdk-release.sh and the
# live-version path of scripts/download-metica-sdk.sh.
#
# METICA_SDK_RELEASES_API points both scripts at a file:// fixture tree shaped
# like the GitHub releases API (<base>/latest, <base>/tags/v<x.y.z>), so every
# path runs without a network.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESOLVE="$PLUGIN_DIR/scripts/resolve-sdk-release.sh"

pass=0
fail=0
ok()  { echo "  ok    $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }

WORK="$(mktemp -d -t metica-release-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
API_DIR="$WORK/api"
mkdir -p "$API_DIR/tags"
export METICA_SDK_RELEASES_API="file://$API_DIR"

PKG="$WORK/MeticaSdk-9.8.7.unitypackage"
printf 'fake unitypackage payload\n' > "$PKG"
if command -v shasum >/dev/null 2>&1; then
    PKG_SHA="$(shasum -a 256 "$PKG" | awk '{print $1}')"
else
    PKG_SHA="$(sha256sum "$PKG" | awk '{print $1}')"
fi

# Mirrors GitHub's pretty-printed shape: per asset, digest precedes browser_download_url.
write_release() {
    local file="$1" tag="$2" digest="$3" asset_url="$4"
    cat > "$file" <<JSON
{
  "tag_name": "$tag",
  "published_at": "2026-12-01T10:00:00Z",
  "assets": [
    {
      "name": "notes.txt",
      "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
      "browser_download_url": "https://example.invalid/notes.txt"
    },
    {
      "name": "MeticaSdk.unitypackage",
      "digest": "$digest",
      "browser_download_url": "$asset_url"
    }
  ]
}
JSON
}

echo "== resolve-sdk-release.sh unit tests =="

write_release "$API_DIR/latest" "v9.8.7" "sha256:$PKG_SHA" "file://$PKG"
cp "$API_DIR/latest" "$API_DIR/tags/v9.8.7"

out="$(bash "$RESOLVE" 2>&1)"; rc=$?
expected="version=9.8.7
download_url=file://$PKG
sha256=$PKG_SHA
released_at=2026-12-01
release_notes_url=https://github.com/meticalabs/metica-unity-package/releases/tag/v9.8.7"
{ [ "$rc" = "0" ] && [ "$out" = "$expected" ]; } \
    && ok "latest release → five fields, unitypackage asset digest" || bad "latest (rc=$rc, out=$out)"

out="$(bash "$RESOLVE" --version=9.8.7 2>&1)"; rc=$?
{ [ "$rc" = "0" ] && [ "$out" = "$expected" ]; } \
    && ok "--version reads the tagged release" || bad "--version (rc=$rc, out=$out)"

out="$(bash "$RESOLVE" --version=1.2.3 2>&1)"; rc=$?
[ "$rc" != "0" ] && ok "unknown version → non-zero" || bad "unknown version (rc=$rc, out=$out)"

out="$(METICA_SDK_RELEASES_API="file://$WORK/unreachable" bash "$RESOLVE" 2>/dev/null)"; rc=$?
{ [ "$rc" != "0" ] && [ -z "$out" ]; } \
    && ok "unreachable API → non-zero, no fields" || bad "unreachable (rc=$rc, out=$out)"

write_release "$API_DIR/tags/v9.8.6" "v9.8.6" "" "file://$PKG"
out="$(bash "$RESOLVE" --version=9.8.6 2>/dev/null)"; rc=$?
{ [ "$rc" != "0" ] && [ -z "$out" ]; } \
    && ok "asset without sha256 digest → non-zero" || bad "no digest (rc=$rc, out=$out)"

write_release "$API_DIR/tags/v9.8.5" "v9.8.5" "sha256:$PKG_SHA" "https://example.invalid/sdk.zip"
out="$(bash "$RESOLVE" --version=9.8.5 2>/dev/null)"; rc=$?
{ [ "$rc" != "0" ] && [ -z "$out" ]; } \
    && ok "release without .unitypackage asset → non-zero" || bad "no asset (rc=$rc, out=$out)"

echo "== download-metica-sdk.sh live-version tests =="

make_project() {
    local d; d="$(mktemp -d "$WORK/project-XXXXXX")"
    mkdir -p "$d/Assets"
    echo "$d"
}

proj="$(make_project)"
out="$(bash "$PLUGIN_DIR/scripts/download-metica-sdk.sh" --project="$proj" 2>&1)"; rc=$?
{ [ "$rc" = "0" ] && [ -f "$proj/Assets/MeticaSDK-9.8.7.unitypackage" ] \
    && printf '%s' "$out" | grep -q "Checksum verified."; } \
    && ok "no --version → installs the live latest, ahead of the matrix, checksum verified" \
    || bad "live latest install (rc=$rc, out=$out)"

write_release "$API_DIR/latest" "v9.8.7" "sha256:0000000000000000000000000000000000000000000000000000000000000000" "file://$PKG"
proj="$(make_project)"
out="$(bash "$PLUGIN_DIR/scripts/download-metica-sdk.sh" --project="$proj" 2>&1)"; rc=$?
{ [ "$rc" != "0" ] && [ ! -f "$proj/Assets/MeticaSDK-9.8.7.unitypackage" ] \
    && printf '%s' "$out" | grep -q "Checksum mismatch"; } \
    && ok "live release digest mismatch → refused" || bad "digest mismatch (rc=$rc, out=$out)"

proj="$(make_project)"
out="$(METICA_SDK_RELEASES_API="file://$WORK/unreachable" \
       bash "$PLUGIN_DIR/scripts/download-metica-sdk.sh" --project="$proj" --dry-run 2>&1)"; rc=$?
{ [ "$rc" != "0" ] && ! printf '%s' "$out" | grep -q "^PLAN"; } \
    && ok "latest unreachable → fails, no plan from the matrix" || bad "unreachable download (rc=$rc, out=$out)"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
