#!/bin/bash
# run-compat-tests.sh — golden eval for detect-compat.sh.
# Each fixture is documented with the rule it is meant to trigger.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECT="${SCRIPT_DIR}/../scripts/detect-compat.sh"
FIX="${SCRIPT_DIR}/fixtures"

pass=0
fail=0

# extract a check's level by id from a JSON document, ignoring sibling objects.
level_of() {
    local json="$1" id="$2"
    printf '%s\n' "$json" | awk -v want="$id" '
        /^[[:space:]]*\{/ { obj = $0; next }
        /"id":[[:space:]]*"/ { obj = $0; next }
    ' >/dev/null   # noop; logic below operates on single-line check entries
    printf '%s\n' "$json" | awk -v want="\"$id\"" '
        /"id":[[:space:]]*"[a-z_]+"/ {
            # extract id between quotes after "id":
            n = index($0, "\"id\":")
            s = substr($0, n + 5)
            sub(/^[^"]*"/, "", s); sub(/".*$/, "", s)
            if ("\"" s "\"" == want) {
                m = index($0, "\"level\":")
                if (m > 0) {
                    t = substr($0, m + 8)
                    sub(/^[^"]*"/, "", t); sub(/".*$/, "", t)
                    print t
                    exit
                }
            }
        }
    '
}

status_of() {
    printf '%s\n' "$1" | awk '
        /"status":[[:space:]]*"/ {
            n = index($0, "\"status\":")
            s = substr($0, n + 9)
            sub(/^[^"]*"/, "", s); sub(/".*$/, "", s)
            print s
            exit
        }
    '
}

assert_case() {
    local name="$1" expected_status="$2" expected_fail_id="$3"
    local env_prefix="$4"
    local out
    if [ -n "$env_prefix" ]; then
        # env handles paths with spaces correctly; eval would word-split.
        out=$(env $env_prefix bash "$DETECT" --project="$FIX/$name" 2>&1) || true
    else
        out=$(bash "$DETECT" --project="$FIX/$name" 2>&1) || true
    fi

    local actual_status; actual_status=$(status_of "$out")
    if [ "$actual_status" != "$expected_status" ]; then
        printf "  FAIL  %s: status expected=%s got=%s\n" "$name" "$expected_status" "$actual_status"
        printf '%s\n' "$out" | sed 's/^/    /'
        fail=$((fail+1))
        return
    fi

    if [ -n "$expected_fail_id" ]; then
        local lvl; lvl=$(level_of "$out" "$expected_fail_id")
        if [ "$lvl" != "FAIL" ]; then
            printf "  FAIL  %s: check '%s' expected level=FAIL got=%s\n" "$name" "$expected_fail_id" "$lvl"
            printf '%s\n' "$out" | sed 's/^/    /'
            fail=$((fail+1))
            return
        fi
    fi

    printf "  ok    %s\n" "$name"
    pass=$((pass+1))
}

assert_check_levels() {
    # assert_check_levels <name> <project_path> <expected_status> <id1:level1> <id2:level2> ...
    local name="$1" path="$2" expected_status="$3"; shift 3
    local out; out=$(bash "$DETECT" --project="$path" 2>&1) || true
    local actual_status; actual_status=$(status_of "$out")
    if [ "$actual_status" != "$expected_status" ]; then
        printf "  FAIL  %s: status expected=%s got=%s\n" "$name" "$expected_status" "$actual_status"
        printf '%s\n' "$out" | sed 's/^/    /'
        fail=$((fail+1))
        return
    fi
    local mismatch=0
    for pair in "$@"; do
        local id="${pair%%:*}" expected="${pair#*:}"
        local got; got=$(level_of "$out" "$id")
        if [ "$got" != "$expected" ]; then
            printf "  FAIL  %s: check '%s' expected=%s got=%s\n" "$name" "$id" "$expected" "$got"
            mismatch=1
        fi
    done
    if [ "$mismatch" -eq 0 ]; then
        printf "  ok    %s\n" "$name"
        pass=$((pass+1))
    else
        printf '%s\n' "$out" | sed 's/^/    /'
        fail=$((fail+1))
    fi
}

echo "== compat-checker golden eval =="
assert_case unity-too-low "BLOCK" "unity"       ""
assert_case missing-max   "PASS"  ""            ""
assert_case max-too-low   "BLOCK" "max"         ""
assert_case api-too-low   "BLOCK" "android_api" ""
assert_case api-ok        "PASS"  ""            ""
# Java mock: too-low via MOCK_JAVA_VERSION env var on a clean fixture
assert_case missing-max   "BLOCK" "java"        "MOCK_JAVA_VERSION=1.8.0_362"

# Real project — locked expected per-check levels
REAL_PROJECT="$(cd "$SCRIPT_DIR/../../max-agent-test/DemoApp" 2>/dev/null && pwd)"
if [ -d "$REAL_PROJECT" ]; then
    # Real DemoApp: Android API bumped 19→23. Whether MeticaSDK is imported
    # depends on whether the user has opened Unity and imported the .unitypackage.
    # The test asserts only the non-volatile rows; metica_sdk varies with demo state.
    if [ -f "$REAL_PROJECT/Assets/MeticaSdk/Runtime/Sdk/MeticaSdk.cs" ]; then
        assert_check_levels "real-project (MeticaSDK installed)" "$REAL_PROJECT" "PASS" \
            "unity:PASS" "java:PASS" "max:PASS" "android_api:PASS" "scripting_backend:PASS" "gradle:UNKNOWN" "metica_sdk:PASS"
    else
        assert_check_levels "real-project (MeticaSDK not installed)" "$REAL_PROJECT" "BLOCK" \
            "unity:PASS" "java:PASS" "max:PASS" "android_api:PASS" "scripting_backend:PASS" "gradle:UNKNOWN" "metica_sdk:FAIL"
    fi
fi

echo "----"
printf "passed: %d   failed: %d\n" "$pass" "$fail"
[ "$fail" -eq 0 ]
