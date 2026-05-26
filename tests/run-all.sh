#!/bin/bash
# run-all.sh — convenience runner for all plugin tests.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

any_fail=0
bash "$SCRIPT_DIR/run-compat-tests.sh"     || any_fail=1; echo
bash "$SCRIPT_DIR/run-format-tests.sh"     || any_fail=1; echo
bash "$SCRIPT_DIR/run-download-tests.sh"   || any_fail=1; echo
bash "$SCRIPT_DIR/run-validator-tests.sh"  || any_fail=1; echo
bash "$SCRIPT_DIR/run-mode-tests.sh"       || any_fail=1; echo
bash "$SCRIPT_DIR/run-codegen-validator-tests.sh" || any_fail=1

echo
[ "$any_fail" -eq 0 ] && { echo "ALL GREEN"; exit 0; }
echo "FAILURES"
exit 1
