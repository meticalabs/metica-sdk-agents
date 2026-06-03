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

# shellcheck disable=SC1090
. "$SESSION_FILE"
: "${label:?session file missing label}"
: "${platform:?session file missing platform}"
: "${pid:?session file missing pid}"
: "${log_file:?session file missing log_file}"
[ -f "$log_file" ] || die "Captured log file not found: $log_file"

# ---- stop capture ----------------------------------------------------------

if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    sleep 0.3
    kill -9 "$pid" 2>/dev/null || true
fi
# BSD pkill (macOS) does not accept `--` as an end-of-options marker, so we
# can't lean on it. $log_file is safe from a leading dash in practice: $LABEL
# is kebab-validated upstream and $OUTPUT_DIR defaults to $PWD (an absolute
# path); only an explicit `--output-dir=-foo` could synthesize one.
pkill -f "$log_file" 2>/dev/null || true

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
