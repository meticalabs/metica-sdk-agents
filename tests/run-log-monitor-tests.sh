#!/bin/bash
# run-log-monitor-tests.sh — unit tests for ad-log-monitor scripts.
#
# Covers the script error paths (invalid args, missing toolchain, no-session)
# plus one synthetic-logcat happy-path Phase 2 run that asserts the report
# contains the expected rule rows.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
START="$SCRIPT_DIR/../scripts/log-monitor-start.sh"
STOP="$SCRIPT_DIR/../scripts/log-monitor-stop.sh"
FIXT_DIR="$SCRIPT_DIR/fixtures/log-monitor"

pass=0
fail=0
ok()  { echo "  ok    $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }

# A hermetic PATH that strips brew-installed tools (adb / idevicesyslog) but
# keeps coreutils. Works on macOS (/usr/bin) and Linux (/usr/bin, /bin).
HERMETIC_PATH="/usr/bin:/bin"

echo "== log-monitor scripts: argument + toolchain gates =="

# 1. start.sh — missing --label
out="$(bash "$START" 2>&1)"; rc=$?
{ [ "$rc" = "1" ] && printf '%s' "$out" | grep -q 'Missing --label'; } \
    && ok "start: missing --label → FAIL exit 1" \
    || bad "start: missing --label (rc=$rc, out=$out)"

# 2. start.sh — bad label (not kebab-case)
out="$(bash "$START" --label="Bad Label" --platform=android 2>&1)"; rc=$?
{ [ "$rc" = "1" ] && printf '%s' "$out" | grep -q 'kebab-case'; } \
    && ok "start: non-kebab label → FAIL exit 1" \
    || bad "start: non-kebab label (rc=$rc, out=$out)"

# 3. start.sh — adb missing on PATH (Android platform)
out="$(PATH="$HERMETIC_PATH" bash "$START" --label=t-android --platform=android 2>&1)"; rc=$?
{ [ "$rc" = "1" ] && printf '%s' "$out" | grep -q 'adb not found' \
    && printf '%s' "$out" | grep -q 'brew install android-platform-tools'; } \
    && ok "start: adb missing → FAIL with install hint" \
    || bad "start: adb missing (rc=$rc, out=$out)"

# 4. start.sh — idevicesyslog missing on PATH (iOS platform)
out="$(PATH="$HERMETIC_PATH" bash "$START" --label=t-ios --platform=ios 2>&1)"; rc=$?
{ [ "$rc" = "1" ] && printf '%s' "$out" | grep -q 'idevicesyslog not found' \
    && printf '%s' "$out" | grep -q 'brew install libimobiledevice'; } \
    && ok "start: idevicesyslog missing → FAIL with install hint" \
    || bad "start: idevicesyslog missing (rc=$rc, out=$out)"

# 5. start.sh — unknown platform
out="$(bash "$START" --label=t --platform=symbian 2>&1)"; rc=$?
{ [ "$rc" = "1" ] && printf '%s' "$out" | grep -q 'Unknown --platform'; } \
    && ok "start: bad platform → FAIL" \
    || bad "start: bad platform (rc=$rc, out=$out)"

echo
echo "== log-monitor scripts: stop.sh argument gates =="

# 6. stop.sh — missing --label
out="$(bash "$STOP" 2>&1)"; rc=$?
{ [ "$rc" = "1" ] && printf '%s' "$out" | grep -q 'Missing --label'; } \
    && ok "stop: missing --label → FAIL exit 1" \
    || bad "stop: missing --label (rc=$rc, out=$out)"

# 7. stop.sh — no session file for this label
tmp="$(mktemp -d)"
out="$(cd "$tmp" && bash "$STOP" --label=does-not-exist 2>&1)"; rc=$?
{ [ "$rc" = "1" ] && printf '%s' "$out" | grep -qE 'No session file|log-monitor-start.sh'; } \
    && ok "stop: missing session → FAIL with start-first hint" \
    || bad "stop: missing session (rc=$rc, out=$out)"
rm -rf "$tmp"

echo
echo "== log-monitor: Phase 2 happy-path against synthetic fixture =="

# 8. stop.sh — run against a synthetic Android logcat fixture; verify the
# report contains the headline sections + a PASS row we know should pass.
if [ -f "$FIXT_DIR/happy-android.log" ]; then
    tmp="$(mktemp -d)"
    cp "$FIXT_DIR/happy-android.log" "$tmp/happy-android.log"
    # Use a no-op PID for the session so kill is a noop. PID 1 always exists
    # but is init; kill -0 succeeds. The actual kill is gated by kill -0 so it
    # tries `kill 1` which will fail without privileges — that's fine, the
    # script tolerates kill failure (|| true).
    {
        printf 'label=happy\n'
        printf 'platform=android\n'
        printf 'pid=99999\n'
        printf 'log_file=%s/happy-android.log\n' "$tmp"
        printf 'app=\n'
        printf 'started_at=2026-06-02T12:00:00Z\n'
    } > "$tmp/happy.session"

    out="$(cd "$tmp" && bash "$STOP" --label=happy 2>&1)"; rc=$?
    report="$tmp/happy-analysis.md"

    if [ "$rc" = "0" ] && [ -f "$report" ] \
        && grep -q '^# Ad Log Analysis' "$report" \
        && grep -q '## Init checks' "$report" \
        && grep -q '## Interstitial' "$report" \
        && grep -q '## Metica → MAX handoff' "$report" \
        && grep -q '## Errors & warnings' "$report"; then
        ok "stop: synthetic Android fixture → report has expected sections"
    else
        bad "stop: synthetic fixture (rc=$rc) — report missing sections"
        echo "    --- stop.sh stdout ---"
        printf '%s\n' "$out" | sed 's/^/    /'
        [ -f "$report" ] && { echo "    --- report ---"; sed 's/^/    /' "$report"; }
    fi

    # The fixture is constructed so that privacy_before_init must PASS.
    if [ -f "$report" ] && grep -E '^\| privacy_before_init \| PASS' "$report" > /dev/null; then
        ok "stop: privacy_before_init = PASS on happy fixture"
    else
        bad "stop: privacy_before_init expected PASS"
        [ -f "$report" ] && grep -E '^\| privacy_before_init' "$report" | sed 's/^/    /'
    fi

    # And session file should be removed after a successful run.
    if [ ! -f "$tmp/happy.session" ]; then
        ok "stop: session file cleaned up after run"
    else
        bad "stop: session file lingered"
    fi

    rm -rf "$tmp"
else
    echo "  SKIP  fixture $FIXT_DIR/happy-android.log not present"
fi

echo
echo "Pass: $pass   Fail: $fail"
[ "$fail" = "0" ] || exit 1
