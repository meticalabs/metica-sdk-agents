#!/bin/bash
# run-mode-tests.sh — golden eval for detect-mode.sh (Phase 4a multi-signal rule).

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECT="$SCRIPT_DIR/../scripts/detect-mode.sh"
FIX="$SCRIPT_DIR/mode-fixtures"

pass=0
fail=0

mode_of() {
    printf '%s\n' "$1" | awk '
        /"mode":[[:space:]]*"/ {
            n=index($0, "\"mode\":")
            s=substr($0, n+7); sub(/^[^"]*"/, "", s); sub(/".*$/, "", s)
            print s; exit
        }'
}

assert_mode() {
    local name="$1" expected="$2"
    local out got
    out=$(bash "$DETECT" --project="$3" 2>&1) || true
    got=$(mode_of "$out")
    if [ "$got" = "$expected" ]; then
        printf "  ok    %s → %s\n" "$name" "$got"
        pass=$((pass+1))
    else
        printf "  FAIL  %s: expected=%s got=%s\n" "$name" "$expected" "$got"
        printf '%s\n' "$out" | sed 's/^/    /'
        fail=$((fail+1))
    fi
}

echo "== mode-detect golden eval =="
assert_mode "s1-only (folder only)"          fresh         "$FIX/s1-only"
assert_mode "s2-only (symbol only)"          fresh         "$FIX/s2-only"
assert_mode "s3-only (manifest only)"        fresh         "$FIX/s3-only"
assert_mode "s1+s2 (folder + symbol)"        side-by-side  "$FIX/s1-s2"
assert_mode "s2+s3 (symbol + manifest)"      side-by-side  "$FIX/s2-s3"
assert_mode "stringlit (symbol in string)"   fresh         "$FIX/stringlit"

# Real project: MaxSDK demo → side-by-side (all 3 signals)
REAL="$(cd "$SCRIPT_DIR/../../max-agent-test/DemoApp" 2>/dev/null && pwd)"
if [ -d "$REAL" ]; then
    assert_mode "real DemoApp"               side-by-side  "$REAL"
fi

# Validator's good-fresh fixture (no Max) → fresh
assert_mode "validator good-fresh"           fresh         "$SCRIPT_DIR/validator-fixtures/good-fresh"

# JSON parses
for f in s1-only s2-only s3-only s1-s2 s2-s3 stringlit; do
    out=$(bash "$DETECT" --project="$FIX/$f" 2>&1) || true
    if printf '%s' "$out" | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null; then
        :
    else
        printf "  FAIL  json-parses: %s\n" "$f"; fail=$((fail+1))
        printf '%s\n' "$out" | sed 's/^/    /'
        continue
    fi
done
printf "  ok    all fixture outputs parse as JSON\n"; pass=$((pass+1))

echo "----"
printf "passed: %d   failed: %d\n" "$pass" "$fail"
[ "$fail" -eq 0 ]
