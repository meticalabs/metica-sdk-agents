#!/bin/bash
# log-monitor-stop.sh — Phase 2a of ad-log-monitor.
# Stop the capture identified by --label and print a minimal summary the
# agent uses to drive its analysis. This script does NOT analyse the log;
# log shape varies enough between games and SDK versions that rule-based
# grep counting gives false PASS/FAIL. Analysis is agent prose (Phase 2b).
#
# Usage: log-monitor-stop.sh --label=<slug> [--output-dir=<dir>]
# Exit:  0 = capture stopped, log present, summary printed.
#        1 = invocation/missing-session.

set -u
set -o pipefail

LABEL=""
OUTPUT_DIR="$PWD"

die() { printf 'FAIL\t%s\n' "$1" >&2; exit 1; }

for arg in "$@"; do
    case $arg in
        --label=*)      LABEL="${arg#*=}" ;;
        --output-dir=*) OUTPUT_DIR="${arg#*=}" ;;
        -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown arg: $arg" ;;
    esac
done

[ -n "$LABEL" ] || die "Missing --label=<slug>"
# Same kebab-case rule as start.sh — prevents path traversal via --label=../foo
# when the value is then used to build $SESSION_FILE and `.` sourced.
printf '%s' "$LABEL" | grep -qE '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$' \
    || die "Label '$LABEL' is not kebab-case (lowercase letters, digits, dashes; no leading/trailing dash)."
[ -d "$OUTPUT_DIR" ] || die "Output dir not found: $OUTPUT_DIR"

SESSION_FILE="$OUTPUT_DIR/$LABEL.session"
[ -f "$SESSION_FILE" ] || die "No session file for label '$LABEL' at $SESSION_FILE.
  Run log-monitor-start.sh --label=$LABEL first."

# Parse the session as plain key=value data — do NOT source it. Sourcing
# a tampered or corrupted .session is equivalent to arbitrary code
# execution; this loop only assigns to a fixed whitelist of variables.
label=""; platform=""; pid=""; log_file=""; app=""; started_at=""
while IFS='=' read -r key value; do
    case "$key" in
        label)      label="$value" ;;
        platform)   platform="$value" ;;
        pid)        pid="$value" ;;
        log_file)   log_file="$value" ;;
        app)        app="$value" ;;
        started_at) started_at="$value" ;;
        # Anything else is silently dropped.
    esac
done < "$SESSION_FILE"

[ -n "$label" ]    || die "session file missing label"
[ -n "$platform" ] || die "session file missing platform"
[ -n "$pid" ]      || die "session file missing pid"
[ -n "$log_file" ] || die "session file missing log_file"
[ -f "$log_file" ] || die "Captured log file not found: $log_file"

# Defensive validation against a tampered or corrupted .session before we
# pass anything to `kill`. A non-numeric pid trips set -u arithmetic; pid=0
# would `kill` the caller's entire process group; a negative pid broadcasts
# the signal to every process the caller can signal. Refuse anything that
# isn't strictly > 1 (PID 1 is init / launchd — also wrong to signal).
case "$pid" in
    ''|*[!0-9]*) die "Invalid pid in session file: '$pid' (expected a positive integer)" ;;
esac
[ "$pid" -gt 1 ] || die "Refusing to signal pid=$pid from session file (must be > 1)."

# Sanity-check: the label embedded in the session file should match the
# label we were invoked with. A mismatch means the user renamed the
# .session file or pointed --label at the wrong session — bail rather
# than acting on the wrong capture.
[ "$label" = "$LABEL" ] \
    || die "Session label mismatch: file says '$label', --label=$LABEL. Refusing to act on the wrong capture."

# ---- stop capture ----------------------------------------------------------

# We have the exact PID from the session file — kill that and stop. We
# do NOT fall back to `pkill -f "$log_file"`: that's a regex match on the
# full command line and can hit unrelated processes (an editor open on
# the file, a `tail -f`, etc.). If the PID is stale, the user can clean
# up manually rather than us nuking innocent processes.
if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    sleep 0.3
    kill -9 "$pid" 2>/dev/null || true
fi

# ---- summary printed for the agent ----------------------------------------

TOTAL_LINES=$(wc -l < "$log_file" | tr -d ' ')

printf 'OK\tcapture stopped\n'
printf '  label:    %s\n' "$LABEL"
printf '  platform: %s\n' "$platform"
printf '  log:      %s\n' "$log_file"
printf '  lines:    %s\n' "$TOTAL_LINES"
printf '  app:      %s\n' "${app:-(unfiltered)}"
printf '  started:  %s\n' "${started_at:-unknown}"
printf '\nProceed with analysis: read the captured log and produce ./%s-analysis.md.\n' "$LABEL"

# Clean up session.
rm -f "$SESSION_FILE"

exit 0
