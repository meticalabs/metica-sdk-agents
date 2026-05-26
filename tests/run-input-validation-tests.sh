#!/bin/bash
# run-input-validation-tests.sh — exercise scripts/validate-keys.sh.
#
# These tests preserve the input-validation invariants that the deleted
# codegen-fresh.sh / codegen-sidebyside.sh enforced (empty rejection,
# control-char rejection, C# string-literal escaping, injection-resistance,
# and the REMOTE_CONFIG_KEY character class). The integrator agent is now
# REQUIRED to call validate-keys.sh for every key/ID it embeds in generated
# code, so a drift in agent prose alone cannot bypass these checks.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
V="$PLUGIN_DIR/scripts/validate-keys.sh"

pass=0
fail=0

# expect_ok name expected_stdout --type=... <value>
expect_ok() {
    local name="$1" expected="$2"; shift 2
    local got rc
    got="$("$V" "$@" 2>&1)"; rc=$?
    if [ "$rc" = "0" ] && [ "$got" = "$expected" ]; then
        echo "  PASS  $name"; pass=$((pass+1))
    else
        echo "  FAIL  $name  (rc=$rc, got='$got', want='$expected')"; fail=$((fail+1))
    fi
}

# expect_fail name --type=... <value>
expect_fail() {
    local name="$1"; shift
    local got rc
    got="$("$V" "$@" 2>&1)"; rc=$?
    if [ "$rc" != "0" ]; then
        echo "  PASS  $name  (exit $rc; stderr starts '${got%%$'\n'*}')"; pass=$((pass+1))
    else
        echo "  FAIL  $name  (expected failure but exit 0; stdout='$got')"; fail=$((fail+1))
    fi
}

echo "=== run-input-validation-tests.sh ==="

# --- string-literal positive cases ---
expect_ok "string-literal: plain ASCII"             "abc123"             --type=string-literal "abc123"
expect_ok "string-literal: backslash escaped"       'x\\y'               --type=string-literal 'x\y'
expect_ok "string-literal: double-quote escaped"    'x\"y'               --type=string-literal 'x"y'
expect_ok "string-literal: & preserved"             'a&b'                --type=string-literal 'a&b'
expect_ok "string-literal: / preserved"             'a/b'                --type=string-literal 'a/b'
expect_ok "string-literal: injection resistance"    'abc\"; System.IO.File.Delete(\"/\") //' \
                                                                         --type=string-literal 'abc"; System.IO.File.Delete("/") //'

# --- string-literal negative cases ---
expect_fail "string-literal: rejects empty"         --type=string-literal ""
expect_fail "string-literal: rejects newline"       --type=string-literal $'foo\nbar'
expect_fail "string-literal: rejects tab"           --type=string-literal $'foo\tbar'
expect_fail "string-literal: rejects CR"            --type=string-literal $'foo\rbar'

# --- remote-config-key positive cases ---
expect_ok "remote-config-key: underscore (default)" "metica_rollout"         --type=remote-config-key "metica_rollout"
expect_ok "remote-config-key: dotted"               "metica.rollout.enabled" --type=remote-config-key "metica.rollout.enabled"
expect_ok "remote-config-key: hyphenated"           "metica-rollout-flag"    --type=remote-config-key "metica-rollout-flag"
expect_ok "remote-config-key: alphanumeric only"    "ab123"                  --type=remote-config-key "ab123"
expect_ok "remote-config-key: mixed _ . -"          "a.b-c_d"                --type=remote-config-key "a.b-c_d"

# --- remote-config-key negative cases ---
expect_fail "remote-config-key: rejects empty"      --type=remote-config-key ""
expect_fail "remote-config-key: rejects space"      --type=remote-config-key "has space"
expect_fail "remote-config-key: rejects newline"    --type=remote-config-key $'foo\nbar'
expect_fail "remote-config-key: rejects tab"        --type=remote-config-key $'foo\tbar'
expect_fail "remote-config-key: rejects CR"         --type=remote-config-key $'foo\rbar'
expect_fail "remote-config-key: rejects quote"      --type=remote-config-key 'has"quote'
expect_fail "remote-config-key: rejects backslash"  --type=remote-config-key 'has\bs'
expect_fail "remote-config-key: rejects /"          --type=remote-config-key "a/b"
expect_fail "remote-config-key: rejects %"          --type=remote-config-key "pct%"
expect_fail "remote-config-key: rejects @"          --type=remote-config-key "at@sign"

# --- invocation error cases ---
expect_fail "missing --type"                        "abc"
expect_fail "unknown --type"                        --type=bogus "abc"
expect_fail "missing value"                         --type=string-literal

# --- exit code semantics ---
"$V" --type=string-literal "abc" >/dev/null 2>&1 && pass=$((pass+1)) && echo "  PASS  exit 0 on success" \
    || { echo "  FAIL  exit 0 on success"; fail=$((fail+1)); }
"$V" --type=string-literal "" >/dev/null 2>&1; rc=$?
[ "$rc" = "1" ] && pass=$((pass+1)) && echo "  PASS  exit 1 on validation failure" \
    || { echo "  FAIL  exit 1 on validation failure  (got $rc)"; fail=$((fail+1)); }
"$V" --type=bogus "x" >/dev/null 2>&1; rc=$?
[ "$rc" = "2" ] && pass=$((pass+1)) && echo "  PASS  exit 2 on invocation error" \
    || { echo "  FAIL  exit 2 on invocation error  (got $rc)"; fail=$((fail+1)); }

echo
echo "Pass: $pass   Fail: $fail"
[ "$fail" = "0" ] || exit 1
