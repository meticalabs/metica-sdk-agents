#!/bin/bash
# run-validator-tests.sh — golden eval for validate-integration.sh.
# Asserts per-fixture: overall status + the specific rule(s) expected to FAIL/ADVISORY.

set -u

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

mode_of() {
    printf '%s\n' "$1" | awk '
        /"mode":[[:space:]]*"/ {
            n = index($0, "\"mode\":")
            s = substr($0, n + 7); sub(/^[^"]*"/, "", s); sub(/".*$/, "", s)
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

# assert_case <name> <expected_status> <expected_mode> [rule:level ...]
assert_case() {
    local name="$1" exp_status="$2" exp_mode="$3"; shift 3
    local out; out=$(bash "$VALIDATE" --project="$FIX/$name" 2>&1) || true

    local got_status got_mode
    got_status=$(status_of "$out")
    got_mode=$(mode_of "$out")

    local err=0
    if [ "$got_status" != "$exp_status" ]; then
        printf "  FAIL  %s: status expected=%s got=%s\n" "$name" "$exp_status" "$got_status"
        err=1
    fi
    if [ -n "$exp_mode" ] && [ "$got_mode" != "$exp_mode" ]; then
        printf "  FAIL  %s: mode expected=%s got=%s\n" "$name" "$exp_mode" "$got_mode"
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

assert_case good-fresh                    "PASS" "fresh"        \
    "init_count:PASS" "privacy_before_init:PASS" "interstitial_callbacks_subscribed:PASS" \
    "interstitial_reload_on_hidden:PASS"

assert_case good-sidebyside               "PASS" "side-by-side" \
    "init_count:PASS" "interstitial_reload_on_hidden:PASS"

assert_case bad-no-init                   "FAIL" "fresh"        \
    "init_count:FAIL"

assert_case bad-double-init               "FAIL" "fresh"        \
    "init_count:FAIL"

assert_case bad-privacy-after-init        "FAIL" "fresh"        \
    "privacy_before_init:FAIL"

assert_case bad-no-interstitial-callback  "FAIL" "fresh"        \
    "interstitial_callbacks_subscribed:FAIL"

assert_case bad-load-no-show              "FAIL" "fresh"        \
    "interstitial_load_show_parity:FAIL"

assert_case bad-no-reward-callback        "FAIL" "fresh"        \
    "rewarded_reward_callback:FAIL"

assert_case advisory-no-revenue           "PASS" "fresh"        \
    "revenue_callback_subscribed:ADVISORY"

# New: string-literal and block-comment immunity
assert_case good-string-literal-mention   "PASS" "fresh"        \
    "init_count:PASS"

assert_case good-block-comment-mention    "PASS" "fresh"        \
    "init_count:PASS"

assert_case good-verbatim-string          "PASS" "fresh"        \
    "init_count:PASS" "interstitial_load_show_parity:PASS"

# Regression: imported MeticaSDK (Assets/MeticaSdk/) contains its own test
# files with multiple Initialize() calls. Validator must scope to user code only.
assert_case good-fresh-with-imported-sdk  "PASS" "fresh"        \
    "init_count:PASS"

# New: cross-file privacy is FAIL with explicit hint
assert_case bad-cross-file-privacy        "FAIL" "fresh"        \
    "privacy_before_init:FAIL"

# New: interstitial without OnAdHidden auto-reload FAILs
assert_case bad-no-reload-on-hidden       "FAIL" "fresh"        \
    "interstitial_reload_on_hidden:FAIL"

# New: Show without an IsReady guard → ADVISORY, still overall PASS.
assert_case advisory-no-ready-guard       "PASS" "fresh"        \
    "interstitial_show_ready_guard:ADVISORY"

# New: straight-swap mode (Max present, no remote config). Validated with an
# explicit --mode; no router is generated and the dropped ad_service_router_present
# check must not appear.
out=$(bash "$VALIDATE" --project="$FIX/good-straight-swap" --mode=straight-swap 2>&1) || true
if [ "$(status_of "$out")" = "PASS" ] && [ "$(mode_of "$out")" = "straight-swap" ] \
   && ! printf '%s' "$out" | grep -q 'ad_service_router_present'; then
    printf "  ok    good-straight-swap (mode=straight-swap, no router check)\n"; pass=$((pass+1))
else
    printf "  FAIL  good-straight-swap unexpected output:\n"; printf '%s\n' "$out" | sed 's/^/    /'; fail=$((fail+1))
fi

# New: the same project auto-detects as straight-swap (Max wrapper + Metica, no
# router) and gets same-file privacy validation — not a router-branch false-PASS.
assert_case good-straight-swap            "PASS" "straight-swap" \
    "init_count:PASS" "privacy_before_init:PASS" "interstitial_reload_on_hidden:PASS"

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

# Assert all-fixtures JSON parses (no syntax errors)
for fx in good-fresh good-sidebyside bad-no-init bad-double-init bad-privacy-after-init \
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
