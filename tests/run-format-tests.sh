#!/bin/bash
# run-format-tests.sh — golden eval for format-compat-report.sh.
# Combines substring checks with one byte-exact golden-file diff and
# structural invariants (row count, single Overall line).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECT="${SCRIPT_DIR}/../scripts/detect-compat.sh"
FORMAT="${SCRIPT_DIR}/../scripts/format-compat-report.sh"
FIX="${SCRIPT_DIR}/fixtures"
GOLDENS="${SCRIPT_DIR}/goldens"

pass=0
fail=0

run_pipeline() {
    # stderr deliberately separated so noisy detector logs do not enter the formatter.
    bash "$DETECT" --project="$1" 2>/dev/null | bash "$FORMAT"
}

assert_contains() {
    local name="$1" out="$2"; shift 2
    local missing=0
    for needle in "$@"; do
        if ! printf '%s\n' "$out" | grep -qF -- "$needle"; then
            printf "  FAIL  %s: missing substring %q\n" "$name" "$needle"
            missing=1
        fi
    done
    if [ "$missing" -eq 0 ]; then
        printf "  ok    %s\n" "$name"
        pass=$((pass+1))
    else
        printf '%s\n' "$out" | sed 's/^/    /'
        fail=$((fail+1))
    fi
}

assert_structure() {
    local name="$1" out="$2" expected_rows="$3"
    local rows; rows=$(printf '%s\n' "$out" | awk '/^  [A-Za-z]/ && /\[(PASS|FAIL|WARN|UNKNOWN) *\]/' | wc -l | tr -d ' ')
    local overalls; overalls=$(printf '%s\n' "$out" | grep -c '^Overall:')
    if [ "$rows" != "$expected_rows" ]; then
        printf "  FAIL  %s: row count expected=%s got=%s\n" "$name" "$expected_rows" "$rows"
        fail=$((fail+1)); return
    fi
    if [ "$overalls" != "1" ]; then
        printf "  FAIL  %s: Overall: line count expected=1 got=%s\n" "$name" "$overalls"
        fail=$((fail+1)); return
    fi
    printf "  ok    %s\n" "$name"
    pass=$((pass+1))
}

assert_golden() {
    local name="$1" out="$2" golden_file="$3"
    [ -f "$golden_file" ] || { printf "  FAIL  %s: missing golden file %s\n" "$name" "$golden_file"; fail=$((fail+1)); return; }
    if diff -u "$golden_file" <(printf '%s\n' "$out") >/dev/null; then
        printf "  ok    %s\n" "$name"
        pass=$((pass+1))
    else
        printf "  FAIL  %s: differs from golden:\n" "$name"
        diff -u "$golden_file" <(printf '%s\n' "$out") | sed 's/^/    /'
        fail=$((fail+1))
    fi
}

echo "== format-compat-report golden eval =="

out=$(run_pipeline "$FIX/unity-too-low")
assert_contains "unity-too-low: header + unity FAIL + Overall BLOCK" "$out" \
    "COMPAT REPORT — target MeticaSDK 2.4.0" \
    "Unity         2020.3.24f1" \
    "[FAIL   ] Upgrade Unity to 2021.3 or later." \
    "Overall: BLOCK"
assert_structure "unity-too-low: 6 rows + 1 Overall" "$out" 6
assert_golden    "unity-too-low: byte-exact golden" "$out" "$GOLDENS/unity-too-low.txt"

out=$(run_pipeline "$FIX/api-ok")
assert_contains "api-ok: header + Overall PASS" "$out" \
    "COMPAT REPORT — target MeticaSDK 2.4.0" \
    "Android API   24" \
    "[PASS   ]" \
    "Overall: PASS"
assert_structure "api-ok: 6 rows" "$out" 6

out=$(run_pipeline "$FIX/max-too-low")
assert_contains "max-too-low: max FAIL hint" "$out" \
    "MaxSDK        8.1.0" \
    "[FAIL   ] Upgrade AppLovin MAX to 8.2.0 or later." \
    "Overall: BLOCK"

out=$(run_pipeline "$FIX/api-too-low")
assert_contains "api-too-low: api FAIL hint" "$out" \
    "Android API   21" \
    "[FAIL   ] Raise Android minSdk to 23." \
    "Overall: BLOCK"

out=$(MOCK_JAVA_VERSION=1.8.0_362 run_pipeline "$FIX/missing-max")
assert_contains "java-too-low (mock): java FAIL hint" "$out" \
    "Java          1.8.0_362" \
    "[FAIL   ] Upgrade Java to 11 or later." \
    "Overall: BLOCK"

# die_json path
out=$(bash "$DETECT" --project=/no/such/path 2>/dev/null | bash "$FORMAT")
assert_contains "die_json: nonexistent project" "$out" \
    "Overall: BLOCK" \
    "Error: Project not found: /no/such/path"

# Escaped-quote handling in extract()
escaped_json='{
  "schema": "compat-checker/1.0.0",
  "status": "BLOCK",
  "target_sdk": "2.4.0",
  "error": null,
  "warnings": [],
  "checks": [
    { "id": "unity", "detected": "2020.3", "required": ">=2021.3", "level": "FAIL", "hint": "Set \"foo\": bar then upgrade." }
  ]
}'
out=$(printf '%s\n' "$escaped_json" | bash "$FORMAT")
assert_contains "escaped-quote in hint preserved" "$out" \
    "Set \"foo\": bar then upgrade."

# Long detected truncation
long_json='{
  "schema": "compat-checker/1.0.0",
  "status": "BLOCK",
  "target_sdk": "2.4.0",
  "error": null,
  "warnings": [],
  "checks": [
    { "id": "unity", "detected": "this-is-a-very-long-detected-value-that-overflows", "required": ">=2021.3", "level": "FAIL", "hint": "x" }
  ]
}'
out=$(printf '%s\n' "$long_json" | bash "$FORMAT")
assert_contains "long-detected truncated with > sentinel" "$out" \
    "this-is-a-very-long-d>"

# Real project end-to-end
REAL_PROJECT="$(cd "$SCRIPT_DIR/../../max-agent-test/DemoApp" 2>/dev/null && pwd)"
if [ -d "$REAL_PROJECT" ]; then
    out=$(bash "$DETECT" --project="$REAL_PROJECT" 2>/dev/null | bash "$FORMAT")
    assert_contains "real-project: full pipeline" "$out" \
        "COMPAT REPORT — target MeticaSDK 2.4.0" \
        "Unity         2022.3.62f2" \
        "MaxSDK        8.6.3" \
        "Backend       Mono" \
        "Android API   19" \
        "[FAIL   ] Raise Android minSdk to 23." \
        "Overall: BLOCK"
    assert_structure "real-project: 6 rows + 1 Overall" "$out" 6
fi

echo "----"
printf "passed: %d   failed: %d\n" "$pass" "$fail"
[ "$fail" -eq 0 ]
