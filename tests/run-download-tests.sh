#!/bin/bash
# run-download-tests.sh — golden eval for download-metica-sdk.sh.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DOWNLOAD="$PLUGIN_DIR/scripts/download-metica-sdk.sh"
LOCAL_BUILD="$PLUGIN_DIR/../Metica SDK builds/MeticaSdk-2.4.0.unitypackage"
EXPECTED_SHA="8bea5e13a759949f98b961df6b4d730db16ab5e133a5a38fc942195e72fdf067"

pass=0
fail=0
test_logs="$(mktemp -d -t metica-test-logs-XXXXXX)"
trap 'rm -rf "$test_logs"' EXIT

make_temp_project() {
    local dir
    dir="$(mktemp -d -t metica-test-project-XXXXXX)"
    mkdir -p "$dir/Assets" "$dir/ProjectSettings"
    printf 'm_EditorVersion: 2022.3.62f2\n' > "$dir/ProjectSettings/ProjectVersion.txt"
    echo "$dir"
}

# Run a command. Captures to per-test log so prior failures aren't clobbered.
# Sanitize name to a safe filename (spaces, slashes, parens → underscores).
log_for() {
    local n; n=$(printf '%s' "$1" | tr ' /():' '_____')
    echo "$test_logs/$n.log"
}

assert_pass() {
    local name="$1"; shift
    local logf; logf="$(log_for "$name")"
    if "$@" >"$logf" 2>&1; then
        printf "  ok    %s\n" "$name"
        pass=$((pass+1))
    else
        local rc=$?
        printf "  FAIL  %s (exit %d):\n" "$name" "$rc"
        sed 's/^/    /' "$logf"
        fail=$((fail+1))
    fi
}

assert_fail() {
    local name="$1"; shift
    local logf; logf="$(log_for "$name")"
    if "$@" >"$logf" 2>&1; then
        printf "  FAIL  %s: expected non-zero exit\n" "$name"
        sed 's/^/    /' "$logf"
        fail=$((fail+1))
    else
        printf "  ok    %s\n" "$name"
        pass=$((pass+1))
    fi
}

assert_contains_stderr() {
    local name="$1" needle="$2" logf="$3"
    if grep -qF -- "$needle" "$logf"; then
        printf "  ok    %s\n" "$name"
        pass=$((pass+1))
    else
        printf "  FAIL  %s: expected to find %q in output\n" "$name" "$needle"
        sed 's/^/    /' "$logf"
        fail=$((fail+1))
    fi
}

echo "== download-metica-sdk golden eval =="

# Prereq: local SDK build must exist; loud failure if missing (not silent skip).
if [ ! -f "$LOCAL_BUILD" ]; then
    echo "FAIL: local SDK build not present at $LOCAL_BUILD — cannot run tests."
    exit 1
fi

# 1. Dry-run, dev mode — plans, no write
proj=$(make_temp_project)
logf="$(log_for dry-run)"
METICA_SDK_DEV=1 bash "$DOWNLOAD" --project="$proj" --dry-run >"$logf" 2>&1
if [ -f "$proj/Assets/MeticaSDK-2.4.0.unitypackage" ]; then
    printf "  FAIL  dry-run wrote to Assets/\n"; fail=$((fail+1))
elif grep -q "^PLAN$" "$logf"; then
    printf "  ok    dry-run plans without writing\n"; pass=$((pass+1))
else
    printf "  FAIL  dry-run output:\n"; sed 's/^/    /' "$logf"; fail=$((fail+1))
fi
rm -rf "$proj"

# 2. Real install, dev mode — file placed + sha matches
proj=$(make_temp_project)
logf="$(log_for install-sha)"
METICA_SDK_DEV=1 bash "$DOWNLOAD" --project="$proj" >"$logf" 2>&1
if [ -f "$proj/Assets/MeticaSDK-2.4.0.unitypackage" ]; then
    got=$(shasum -a 256 "$proj/Assets/MeticaSDK-2.4.0.unitypackage" | awk '{print $1}')
    if [ "$got" = "$EXPECTED_SHA" ]; then
        printf "  ok    install + sha256 match\n"; pass=$((pass+1))
    else
        printf "  FAIL  installed file sha mismatch: got=%s\n" "$got"; fail=$((fail+1))
    fi
else
    printf "  FAIL  package not placed in Assets/\n"
    sed 's/^/    /' "$logf"
    fail=$((fail+1))
fi
rm -rf "$proj"

# 3. Explicit --version=2.4.0
proj=$(make_temp_project)
assert_pass "explicit --version=2.4.0 installs" \
    env METICA_SDK_DEV=1 bash "$DOWNLOAD" --project="$proj" --version=2.4.0
rm -rf "$proj"

# 4. Unknown version → fail
proj=$(make_temp_project)
assert_fail "unknown version exits non-zero" \
    env METICA_SDK_DEV=1 bash "$DOWNLOAD" --project="$proj" --version=9.9.9
rm -rf "$proj"

# 5. Missing project → fail
assert_fail "missing project exits non-zero" \
    bash "$DOWNLOAD" --project=/no/such/path

# 6. Non-Unity project → fail
nonunity=$(mktemp -d -t not-unity-XXXXXX)
mkdir -p "$nonunity/ProjectSettings"
assert_fail "non-Unity project (no Assets/) exits non-zero" \
    env METICA_SDK_DEV=1 bash "$DOWNLOAD" --project="$nonunity"
rm -rf "$nonunity"

# 7. Sha mismatch → fail AND no file written to target
proj=$(make_temp_project)
BAD_YAML=$(mktemp -t bad-yaml-XXXXXX.yaml)
sed 's/8bea5e13a759949f98b961df6b4d730db16ab5e133a5a38fc942195e72fdf067/0000000000000000000000000000000000000000000000000000000000000000/' "$PLUGIN_DIR/metica-versions.yaml" > "$BAD_YAML"
PATCHED_PLUGIN="$(mktemp -d -t patched-plugin-XXXXXX)"
cp -R "$PLUGIN_DIR/scripts" "$PATCHED_PLUGIN/scripts"
cp "$BAD_YAML" "$PATCHED_PLUGIN/metica-versions.yaml"
cat > "$PATCHED_PLUGIN/metica-versions.dev.yaml" <<EOF
schema: "metica-versions-dev/1.0.0"
local_paths:
  "2.4.0": "$LOCAL_BUILD"
EOF
logf="$(log_for sha-mismatch)"
if METICA_SDK_DEV=1 bash "$PATCHED_PLUGIN/scripts/download-metica-sdk.sh" --project="$proj" >"$logf" 2>&1; then
    printf "  FAIL  sha mismatch should have exited non-zero\n"; fail=$((fail+1))
elif [ -f "$proj/Assets/MeticaSDK-2.4.0.unitypackage" ]; then
    printf "  FAIL  sha mismatch left a file in Assets/\n"; fail=$((fail+1))
else
    printf "  ok    sha256 mismatch: exit non-zero AND no file written\n"; pass=$((pass+1))
fi
rm -rf "$proj" "$PATCHED_PLUGIN" "$BAD_YAML"

# 8. --skip-checksum refused in production (no METICA_SDK_DEV)
proj=$(make_temp_project)
logf="$(log_for skip-checksum-prod)"
if bash "$DOWNLOAD" --project="$proj" --skip-checksum >"$logf" 2>&1; then
    printf "  FAIL  --skip-checksum should be refused without METICA_SDK_DEV=1\n"; fail=$((fail+1))
elif grep -q "refusing in production\|Refusing in production\|requires METICA_SDK_DEV=1" "$logf"; then
    printf "  ok    --skip-checksum refused outside METICA_SDK_DEV\n"; pass=$((pass+1))
else
    printf "  FAIL  unexpected refusal message:\n"; sed 's/^/    /' "$logf"; fail=$((fail+1))
fi
rm -rf "$proj"

# 9. --skip-checksum + METICA_SDK_DEV=1 + bad sha → still installs, with stderr WARN
proj=$(make_temp_project)
BAD_YAML=$(mktemp -t bad-yaml-XXXXXX.yaml)
sed 's/8bea5e13a759949f98b961df6b4d730db16ab5e133a5a38fc942195e72fdf067/0000000000000000000000000000000000000000000000000000000000000000/' "$PLUGIN_DIR/metica-versions.yaml" > "$BAD_YAML"
PATCHED_PLUGIN="$(mktemp -d -t patched-plugin-XXXXXX)"
cp -R "$PLUGIN_DIR/scripts" "$PATCHED_PLUGIN/scripts"
cp "$BAD_YAML" "$PATCHED_PLUGIN/metica-versions.yaml"
cat > "$PATCHED_PLUGIN/metica-versions.dev.yaml" <<EOF
schema: "metica-versions-dev/1.0.0"
local_paths:
  "2.4.0": "$LOCAL_BUILD"
EOF
logf="$(log_for skip-checksum-dev)"
if METICA_SDK_DEV=1 bash "$PATCHED_PLUGIN/scripts/download-metica-sdk.sh" --project="$proj" --skip-checksum >"$logf" 2>&1; then
    if grep -q "WARN: Checksum verification skipped" "$logf"; then
        printf "  ok    --skip-checksum dev: installs + stderr WARN\n"; pass=$((pass+1))
    else
        printf "  FAIL  --skip-checksum dev: no WARN emitted\n"; sed 's/^/    /' "$logf"; fail=$((fail+1))
    fi
else
    printf "  FAIL  --skip-checksum dev: should have succeeded\n"; sed 's/^/    /' "$logf"; fail=$((fail+1))
fi
rm -rf "$proj" "$PATCHED_PLUGIN" "$BAD_YAML"

# 10. Existing install refused without --force
proj=$(make_temp_project)
touch "$proj/Assets/MeticaSdk-2.2.7.unitypackage"
logf="$(log_for existing-no-force)"
if METICA_SDK_DEV=1 bash "$DOWNLOAD" --project="$proj" >"$logf" 2>&1; then
    printf "  FAIL  existing install should refuse without --force\n"; fail=$((fail+1))
elif grep -q "already has a Metica install" "$logf"; then
    printf "  ok    existing install refused\n"; pass=$((pass+1))
else
    printf "  FAIL  unexpected refusal message:\n"; sed 's/^/    /' "$logf"; fail=$((fail+1))
fi
rm -rf "$proj"

# 11. Existing install installs with --force
proj=$(make_temp_project)
touch "$proj/Assets/MeticaSdk-2.2.7.unitypackage"
assert_pass "existing install + --force overwrites" \
    env METICA_SDK_DEV=1 bash "$DOWNLOAD" --project="$proj" --force
rm -rf "$proj"

# 12. curl path via file:// URL (no network)
# Copy the SDK build to a space-free path so curl's file:// URL is well-formed
# (we live under "SDK comparison/" whose space breaks curl URL parsing).
proj=$(make_temp_project)
PATCHED_PLUGIN="$(mktemp -d -t patched-plugin-XXXXXX)"
cp -R "$PLUGIN_DIR/scripts" "$PATCHED_PLUGIN/scripts"
SDK_COPY_DIR="$(mktemp -d -t metica-sdk-curl-XXXXXX)"
cp "$LOCAL_BUILD" "$SDK_COPY_DIR/sdk.unitypackage"
FILE_URL="file://$SDK_COPY_DIR/sdk.unitypackage"
awk -v url="$FILE_URL" '
    /^[[:space:]]+download_url: / && !done {
        sub(/".*"/, "\"" url "\"")
        done = 1
    }
    { print }
' "$PLUGIN_DIR/metica-versions.yaml" > "$PATCHED_PLUGIN/metica-versions.yaml"
# No dev yaml — force the curl path (METICA_SDK_DEV not set)
logf="$(log_for curl-file)"
if bash "$PATCHED_PLUGIN/scripts/download-metica-sdk.sh" --project="$proj" >"$logf" 2>&1; then
    if [ -f "$proj/Assets/MeticaSDK-2.4.0.unitypackage" ] && grep -q "Checksum verified." "$logf"; then
        printf "  ok    curl path via file:// URL + checksum verified\n"; pass=$((pass+1))
    else
        printf "  FAIL  curl path: file missing or checksum line absent\n"; sed 's/^/    /' "$logf"; fail=$((fail+1))
    fi
else
    printf "  FAIL  curl path exited non-zero:\n"; sed 's/^/    /' "$logf"; fail=$((fail+1))
fi
rm -rf "$proj" "$PATCHED_PLUGIN" "$SDK_COPY_DIR"

# 13. --import refuses when UnityLockfile present
proj=$(make_temp_project)
mkdir -p "$proj/Temp" && touch "$proj/Temp/UnityLockfile"
logf="$(log_for unity-lockfile)"
if METICA_SDK_DEV=1 bash "$DOWNLOAD" --project="$proj" --import >"$logf" 2>&1; then
    printf "  FAIL  --import should fail when Unity is open\n"; fail=$((fail+1))
elif grep -q "Unity appears to be open" "$logf"; then
    printf "  ok    --import refused with UnityLockfile present\n"; pass=$((pass+1))
else
    # Could also fail at Unity discovery before reaching the lockfile check; we want lockfile path.
    printf "  FAIL  unexpected message (expected lockfile detection):\n"; sed 's/^/    /' "$logf"; fail=$((fail+1))
fi
rm -rf "$proj"

# 14. Help text
assert_pass "--help exits 0" bash "$DOWNLOAD" --help

# 15. Unknown arg → fail
assert_fail "unknown arg exits non-zero" bash "$DOWNLOAD" --project=/tmp --bogus

echo "----"
printf "passed: %d   failed: %d\n" "$pass" "$fail"
exit "$fail"
