#!/bin/bash
# run-log-monitor-tests.sh — unit tests for ad-log-monitor scripts.
#
# Covers the script error paths (invalid args, missing toolchain, no-session)
# plus one synthetic-logcat happy-path Phase 2a run that asserts stop.sh
# stopped the capture, printed the summary, and cleaned up.
#
# Phase 2b (the analysis itself) is agent prose; there is nothing for a
# script test to assert about the report — log shape varies enough between
# games / SDK versions that locking goldens here gives false signals. See
# agents/ad-log-monitor.md for the rationale.

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

# 5a. start.sh — log file already exists (no-clobber)
tmp="$(mktemp -d)"
: > "$tmp/dupe-android.log"
out="$(bash "$START" --label=dupe --platform=android --output-dir="$tmp" 2>&1)"; rc=$?
{ [ "$rc" = "1" ] && printf '%s' "$out" | grep -q 'Log file already exists'; } \
    && ok "start: log file already exists → FAIL with rename hint" \
    || bad "start: log no-clobber (rc=$rc, out=$out)"
rm -rf "$tmp"

# 5b. start.sh — session file already exists (stale capture)
tmp="$(mktemp -d)"
: > "$tmp/stale.session"
out="$(bash "$START" --label=stale --platform=android --output-dir="$tmp" 2>&1)"; rc=$?
{ [ "$rc" = "1" ] && printf '%s' "$out" | grep -q 'Session file already exists'; } \
    && ok "start: stale .session → FAIL with stop-first hint" \
    || bad "start: session no-clobber (rc=$rc, out=$out)"
rm -rf "$tmp"

echo
echo "== log-monitor scripts: stop.sh argument gates =="

# 6. stop.sh — missing --label
out="$(bash "$STOP" 2>&1)"; rc=$?
{ [ "$rc" = "1" ] && printf '%s' "$out" | grep -q 'Missing --label'; } \
    && ok "stop: missing --label → FAIL exit 1" \
    || bad "stop: missing --label (rc=$rc, out=$out)"

# 7. stop.sh — non-kebab label
out="$(bash "$STOP" --label="Bad Label" 2>&1)"; rc=$?
{ [ "$rc" = "1" ] && printf '%s' "$out" | grep -q 'kebab-case'; } \
    && ok "stop: non-kebab label → FAIL exit 1" \
    || bad "stop: non-kebab label (rc=$rc, out=$out)"

# 8. stop.sh — no session file for this label
tmp="$(mktemp -d)"
out="$(cd "$tmp" && bash "$STOP" --label=does-not-exist 2>&1)"; rc=$?
{ [ "$rc" = "1" ] && printf '%s' "$out" | grep -q 'No session file'; } \
    && ok "stop: missing session → FAIL with start-first hint" \
    || bad "stop: missing session (rc=$rc, out=$out)"
rm -rf "$tmp"

echo
echo "== log-monitor: Phase 2a stop-and-summarise =="

# 9. stop.sh against a synthetic Android log fixture. The script no longer
# writes a report (that's the agent's job in Phase 2b), so we assert only
# that it stopped the capture, printed the summary block the agent expects,
# and cleaned up the session file.
if [ -f "$FIXT_DIR/happy-android.log" ]; then
    tmp="$(mktemp -d)"
    cp "$FIXT_DIR/happy-android.log" "$tmp/happy-android.log"
    # Non-existent PID so kill -0 returns false and the kill block is skipped.
    {
        printf 'label=happy\n'
        printf 'platform=android\n'
        printf 'pid=99999\n'
        printf 'log_file=%s/happy-android.log\n' "$tmp"
        printf 'app=\n'
        printf 'started_at=2026-06-02T12:00:00Z\n'
    } > "$tmp/happy.session"

    out="$(cd "$tmp" && bash "$STOP" --label=happy 2>&1)"; rc=$?

    if [ "$rc" = "0" ] \
        && printf '%s' "$out" | grep -q '^OK	capture stopped' \
        && printf '%s' "$out" | grep -q '  label:    happy' \
        && printf '%s' "$out" | grep -q '  platform: android' \
        && printf '%s' "$out" | grep -q "  log:      $tmp/happy-android.log" \
        && printf '%s' "$out" | grep -qE '  lines:    [0-9]+' \
        && printf '%s' "$out" | grep -q 'Proceed with analysis'; then
        ok "stop: synthetic fixture → summary printed for agent"
    else
        bad "stop: summary (rc=$rc)"
        echo "    --- stop.sh stdout ---"
        printf '%s\n' "$out" | sed 's/^/    /'
    fi

    # Session file cleaned up.
    if [ ! -f "$tmp/happy.session" ]; then
        ok "stop: session file cleaned up after run"
    else
        bad "stop: session file lingered"
    fi

    # stop.sh must NOT write an analysis report — that's Phase 2b's job.
    if [ ! -f "$tmp/happy-analysis.md" ]; then
        ok "stop: no analysis report written by the script (correct — agent does it)"
    else
        bad "stop: unexpected analysis report written by the script"
    fi

    rm -rf "$tmp"
else
    echo "  SKIP  fixture $FIXT_DIR/happy-android.log not present"
fi

echo
echo "Pass: $pass   Fail: $fail"
[ "$fail" = "0" ] || exit 1
