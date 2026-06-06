#!/bin/bash
# run-all.sh — convenience runner for all plugin tests.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The plugin's logic now lives in agent prose, not scripts; only the few
# scripts an agent can't do in prose remain, and these suites cover them.
any_fail=0
bash "$SCRIPT_DIR/run-resolver-tests.sh"     || any_fail=1; echo
bash "$SCRIPT_DIR/run-download-tests.sh"     || any_fail=1; echo
bash "$SCRIPT_DIR/run-compile-tests.sh"      || any_fail=1; echo
bash "$SCRIPT_DIR/run-log-monitor-tests.sh"  || any_fail=1

echo
[ "$any_fail" -eq 0 ] && { echo "ALL GREEN"; exit 0; }
echo "FAILURES"
exit 1
