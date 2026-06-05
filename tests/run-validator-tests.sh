#!/bin/bash
# run-validator-tests.sh — golden eval for validate-integration.sh.
# Asserts per-fixture: overall status + the specific rule(s) expected to FAIL/ADVISORY.

set -u

# Force the validator's compiles_cleanly rule to skip — these are synthetic
# fixtures, not openable Unity projects, so a real batch compile would be both
# impossible and nondeterministic across CI machines. The skip path (→ WARN) is
# exercised explicitly below; the real compile path is covered by compile-check
# unit tests + runs on the user's machine.
export METICA_SKIP_COMPILE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATE="$SCRIPT_DIR/../scripts/validate-integration.sh"
FIX="$SCRIPT_DIR/validator-fixtures"

pass=0
fail=0

status_of() {
    printf '%s\n' "$1" | awk '
        /"status":[[:space:]]*"/ {
            n = index($0, "\"status\":")
            s = substr($0, n + 9); sub(/^[^"]*"/, "", s); sub(/".*$/, "", s)
            print s; exit
        }'
}

# Extract level of a specific rule. Anchored to "rule": "<name>" then "level": "<...>" on same line.
level_of_rule() {
    printf '%s\n' "$1" | awk -v want="$2" '
        /"rule":[[:space:]]*"/ {
            n = index($0, "\"rule\":")
            s = substr($0, n + 7); sub(/^[^"]*"/, "", s); sub(/".*$/, "", s)
            if (s == want) {
                m = index($0, "\"level\":")
                if (m > 0) {
                    t = substr($0, m + 8); sub(/^[^"]*"/, "", t); sub(/".*$/, "", t)
                    print t; exit
                }
            }
        }'
}

# assert_case <name> <expected_status> [rule:level ...]
assert_case() {
    local name="$1" exp_status="$2"; shift 2
    local out; out=$(bash "$VALIDATE" --project="$FIX/$name" 2>&1) || true

    local got_status
    got_status=$(status_of "$out")

    local err=0
    if [ "$got_status" != "$exp_status" ]; then
        printf "  FAIL  %s: status expected=%s got=%s\n" "$name" "$exp_status" "$got_status"
        err=1
    fi
    for pair in "$@"; do
        local rule="${pair%%:*}" exp_level="${pair#*:}"
        local got_level; got_level=$(level_of_rule "$out" "$rule")
        if [ "$got_level" != "$exp_level" ]; then
            printf "  FAIL  %s: rule %s expected=%s got=%s\n" "$name" "$rule" "$exp_level" "$got_level"
            err=1
        fi
    done

    if [ "$err" -eq 0 ]; then
        printf "  ok    %s\n" "$name"
        pass=$((pass+1))
    else
        printf '%s\n' "$out" | sed 's/^/    /'
        fail=$((fail+1))
    fi
}

echo "== validator golden eval =="

assert_case good-fresh                    "PASS"        \
    "init_count:PASS" "privacy_before_init:PASS" "interstitial_callbacks_subscribed:PASS" \
    "interstitial_reload_on_hidden:PASS"

assert_case bad-no-init                   "FAIL"        \
    "init_count:FAIL"

assert_case bad-double-init               "FAIL"        \
    "init_count:FAIL"

assert_case bad-privacy-after-init        "FAIL"        \
    "privacy_before_init:FAIL"

assert_case bad-no-interstitial-callback  "FAIL"        \
    "interstitial_callbacks_subscribed:FAIL"

assert_case bad-load-no-show              "FAIL"        \
    "interstitial_load_show_parity:FAIL"

assert_case bad-no-reward-callback        "FAIL"        \
    "rewarded_reward_callback:FAIL"

assert_case advisory-no-revenue           "PASS"        \
    "revenue_callback_subscribed:ADVISORY"

# New: string-literal and block-comment immunity
assert_case good-string-literal-mention   "PASS"        \
    "init_count:PASS"

assert_case good-block-comment-mention    "PASS"        \
    "init_count:PASS"

assert_case good-verbatim-string          "PASS"        \
    "init_count:PASS" "interstitial_load_show_parity:PASS"

# Regression: imported MeticaSDK (Assets/MeticaSdk/) contains its own test
# files with multiple Initialize() calls. Validator must scope to user code only.
assert_case good-fresh-with-imported-sdk  "PASS"        \
    "init_count:PASS"

# New: cross-file privacy is FAIL with explicit hint
assert_case bad-cross-file-privacy        "FAIL"        \
    "privacy_before_init:FAIL"

# New: interstitial without OnAdHidden auto-reload FAILs
assert_case bad-no-reload-on-hidden       "FAIL"        \
    "interstitial_reload_on_hidden:FAIL"

# interstitial without OnAdShowFailed FAILs — show-failure does not
# fire OnAdHidden, so the reload loop alone is incomplete.
assert_case bad-no-show-failed            "FAIL"        \
    "interstitial_show_failed_subscribed:FAIL"

# New: Show without an IsReady guard → ADVISORY, still overall PASS.
assert_case advisory-no-ready-guard       "PASS"        \
    "interstitial_show_ready_guard:ADVISORY"

# Credential-hygiene checks (placeholder keys + test/null userIds).
# Validator is an integration linter for human code, not just our codegen smoke
# test, so these checks belong in the script — not just in the integrator report.
assert_case bad-placeholder-key           "FAIL"        \
    "placeholder_ids_replaced:FAIL"

assert_case bad-test-userid               "FAIL"        \
    "user_id_not_test_value:FAIL"

assert_case bad-userid-multiline          "FAIL"        \
    "user_id_not_test_value:FAIL"

# Commented-out test value must NOT trip the check (strip-comments.awk gates).
assert_case good-commented-test-userid    "PASS"        \
    "placeholder_ids_replaced:PASS" "user_id_not_test_value:PASS"

# Regression: userId containing the substring 'test' as part of a word
# (contest-user-42) must NOT trip user_id_not_test_value. The pre-fix regex
# matched 'test' anywhere; the tightened pattern requires - / _ boundaries.
assert_case good-legitimate-userid-with-test-substring "PASS" \
    "user_id_not_test_value:PASS"

# Regression: a constant NAMED YOUR_METICA_API_KEY (holding the real value) must
# NOT trip placeholder_ids_replaced — the placeholder check matches only string
# literal values, not identifier names.
assert_case good-placeholder-named-constant "PASS" \
    "placeholder_ids_replaced:PASS"

# New: MRec format coverage — broken MRec integration FAILs
assert_case bad-mrec-no-callbacks         "FAIL"        \
    "mrec_callbacks_subscribed:FAIL" "mrec_load_show_parity:FAIL"

# v1.6.0: MaxSdk API surface checks driven by references/max-metica-api-map.tsv.

# Replaceable call in a Metica-aware file → FAIL.
# (Reproduces the Merge Art Canvas pattern: MaxSdk.SetInterstitialExtraParameter
# survives a mechanical s/MaxSdk./MeticaSdk.Ads./ swap and silently no-ops.)
assert_case bad-max-api-replaceable       "FAIL"        \
    "max_api_use_metica:FAIL"

# Drop-required call (no MeticaSdk equivalent) in a Metica-aware file → FAIL.
assert_case bad-max-api-unsupported       "FAIL"        \
    "max_api_unsupported:FAIL"

# Side-by-side pure-Max wrapper (no MeticaSdk references in that file) →
# ADVISORY only; overall status stays PASS because ADVISORY does not block.
assert_case advisory-max-wrapper          "PASS"        \
    "max_api_use_metica:ADVISORY"

# MaxSdkUtils.* is exempt — stateless helpers, mix-safe under Metica. Both
# MaxSdk rules must emit PASS.
assert_case good-maxsdkutils-exempt       "PASS"        \
    "max_api_use_metica:PASS" "max_api_unsupported:PASS"

# Regression: a fixture with NO MaxSdk.* references at all (good-fresh) must
# still emit PASS rows for both MaxSdk rules.
assert_case good-fresh                    "PASS"        \
    "max_api_use_metica:PASS" "max_api_unsupported:PASS"

# A Max-present project (Max wrapper + Metica) gets the same uniform validation
# — same-file privacy ordering, init count, reload-on-hidden.
assert_case good-max-present            "PASS" \
    "init_count:PASS" "privacy_before_init:PASS" "interstitial_reload_on_hidden:PASS"

# issue #8: the validator now verifies the integration actually BUILDS via the
# compiles_cleanly rule (Unity batch-mode). With METICA_SKIP_COMPILE=1 exported
# above, the rule must report WARN (skipped) and NOT affect the overall status —
# a good fixture stays PASS. The real compile (errors → FAIL) is covered by the
# compile-check unit tests and runs on the user's machine.
assert_case good-fresh                     "PASS" \
    "compiles_cleanly:WARN"

# New: project with no Metica refs gets a structured error, not a PASS-laden report
nometica=$(mktemp -d -t no-metica-XXXXXX)
mkdir -p "$nometica/Assets/Scripts" "$nometica/ProjectSettings"
printf 'm_EditorVersion: 2022.3.62f2\n' > "$nometica/ProjectSettings/ProjectVersion.txt"
printf 'public class Empty {}\n' > "$nometica/Assets/Scripts/Empty.cs"
out=$(bash "$VALIDATE" --project="$nometica" 2>&1) || true
if [ "$(status_of "$out")" = "FAIL" ] && printf '%s' "$out" | grep -q '"error":[[:space:]]*"No MeticaSdk references found'; then
    printf "  ok    no-metica project gets structured error\n"; pass=$((pass+1))
else
    printf "  FAIL  no-metica project unexpected output:\n"; printf '%s\n' "$out" | sed 's/^/    /'; fail=$((fail+1))
fi
rm -rf "$nometica"

# An unknown argument is rejected with a contract-shaped error (exit non-zero).
out=$(bash "$VALIDATE" --project="$FIX/good-max-present" --bogus 2>&1); rc=$?
if [ "$rc" != "0" ] && printf '%s' "$out" | grep -q 'Unknown arg: --bogus'; then
    printf "  ok    unknown argument is rejected\n"; pass=$((pass+1))
else
    printf "  FAIL  unknown argument should be rejected:\n"; printf '%s\n' "$out" | sed 's/^/    /'; fail=$((fail+1))
fi

# Assert all-fixtures JSON parses (no syntax errors)
for fx in good-fresh bad-no-init bad-double-init bad-privacy-after-init \
          bad-no-interstitial-callback bad-load-no-show bad-no-reward-callback advisory-no-revenue \
          good-string-literal-mention good-block-comment-mention bad-cross-file-privacy; do
    out=$(bash "$VALIDATE" --project="$FIX/$fx" 2>&1) || true
    if printf '%s' "$out" | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null; then
        :
    else
        printf "  FAIL  json-parses: fixture %s produced invalid JSON\n" "$fx"; fail=$((fail+1))
        continue
    fi
done
printf "  ok    all fixture outputs parse as JSON\n"; pass=$((pass+1))

# die_json case: nonexistent project
out=$(bash "$VALIDATE" --project=/no/such/path 2>&1) || true
if [ "$(status_of "$out")" = "FAIL" ] && printf '%s' "$out" | grep -q '"error":'; then
    printf "  ok    die_json: nonexistent project\n"; pass=$((pass+1))
else
    printf "  FAIL  die_json output unexpected:\n"; printf '%s\n' "$out" | sed 's/^/    /'; fail=$((fail+1))
fi

echo "----"
printf "passed: %d   failed: %d\n" "$pass" "$fail"
[ "$fail" -eq 0 ]
