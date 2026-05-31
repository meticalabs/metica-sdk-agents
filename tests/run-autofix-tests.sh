#!/bin/bash
# run-autofix-tests.sh — validator-side preconditions of the integrator's
# autofix loop (RFC v1.0 §7; integrator.md Step 6.5).
#
# The loop itself is integrator PROSE (Review-OQ C: the agent applies the edits
# and prompts; a pure-bash harness cannot drive it). So this suite asserts what
# the loop DEPENDS ON from the read-only validator:
#   * every FAIL-producing rule the loop acts on is emitted as level=FAIL on a
#     fixture that triggers it, with the location shape the loop needs — rules
#     that target a specific line (privacy reorder, placeholder/userId prompts,
#     duplicate-init) emit file:line; append-type autofixes and the
#     count-0 codegen-bug emit no location, by design;
#   * the §7 partition (autofix | prompt | surface) is recorded here so a rule
#     silently changing class is caught in review;
#   * the loop's EXIT condition holds — a correctly-integrated fixture PASSes.
#
# It does NOT assert the agent applied a patch (not bash-observable).

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATE="$SCRIPT_DIR/../scripts/validate-integration.sh"
FIX="$SCRIPT_DIR/validator-fixtures"
pass=0; fail=0

echo "=== run-autofix-tests.sh ==="

status_of() {
    printf '%s\n' "$1" | grep -o '"status": "[A-Z]*"' | head -1 | sed -E 's/.*"([A-Z]*)"/\1/'
}

# For a given rule, emit "<level>\t<location>" from the first matching check line
# (check lines are emitted one-per-line as { "rule": .., "location": .., "level": .. }).
rule_field() {
    printf '%s\n' "$1" | grep "\"rule\": \"$2\"" | head -1 \
      | sed -E 's/.*"location": "([^"]*)".*"level": "([^"]*)".*/\2\t\1/'
}

# assert_fail_rule <name> <fixture> <rule> <class> <want_loc:y|n>
assert_fail_rule() {
    local name="$1" fixture="$2" rule="$3" class="$4" want_loc="$5"
    local json st lv loc result ok=1 why=""
    json="$(bash "$VALIDATE" --project="$FIX/$fixture" 2>&1 || true)"
    st="$(status_of "$json")"
    result="$(rule_field "$json" "$rule")"
    IFS=$'\t' read -r lv loc <<< "$result"
    # Guard against a vacuous pass: a typo'd/absent rule yields an empty result,
    # which would otherwise satisfy a want_loc=n location check. Require the rule
    # to actually be present in the validator output.
    [ -n "$result" ] || { ok=0; why="$why rule '$rule' not found in validator output;"; }
    [ "$st" = "FAIL" ] || { ok=0; why="$why status=$st (want FAIL);"; }
    [ "$lv" = "FAIL" ] || { ok=0; why="$why $rule level='$lv' (want FAIL);"; }
    if [ "$want_loc" = "y" ]; then
        [ -n "$loc" ] || { ok=0; why="$why $rule location empty (want file:line for $class target);"; }
    else
        [ -z "$loc" ] || { ok=0; why="$why $rule location='$loc' (want empty);"; }
    fi
    if [ "$ok" = "1" ]; then echo "  ok    $name  [$class] $rule"; pass=$((pass+1));
    else echo "  FAIL  $name: $why"; fail=$((fail+1)); fi
}

# assert_pass <name> <fixture>
assert_pass() {
    local name="$1" fixture="$2" st
    st="$(status_of "$(bash "$VALIDATE" --project="$FIX/$fixture" 2>&1 || true)")"
    if [ "$st" = "PASS" ]; then echo "  ok    $name → PASS (loop exit condition)"; pass=$((pass+1));
    else echo "  FAIL  $name: status='$st' (want PASS)"; fail=$((fail+1)); fi
}

# Format-parameterized rule families (callbacks_subscribed, reload_on_hidden,
# show_failed_subscribed, load_show_parity) behave identically across
# banner/interstitial/rewarded/mrec — the validator builds them from one helper.
# We assert one representative per family (the location SHAPE is what the loop
# depends on); the full per-format set is covered by the "correctly-integrated
# fixtures must PASS" safety net and the integrator prose (per RFC §9).

# --- autofix-class rules (loop edits an existing file in place) -------------
assert_fail_rule "privacy reorder"           bad-privacy-after-init       privacy_before_init                 autofix y
assert_fail_rule "interstitial callbacks"    bad-no-interstitial-callback interstitial_callbacks_subscribed   autofix n
assert_fail_rule "rewarded reward callback"  bad-no-reward-callback       rewarded_reward_callback            autofix n
assert_fail_rule "reload-on-hidden"          bad-no-reload-on-hidden      interstitial_reload_on_hidden       autofix n
assert_fail_rule "show-failed subscribed"    bad-no-show-failed           interstitial_show_failed_subscribed autofix n
assert_fail_rule "mrec callbacks"            bad-mrec-no-callbacks        mrec_callbacks_subscribed           autofix n

# --- prompt-class rules (loop asks, then substitutes) -----------------------
assert_fail_rule "placeholder key"           bad-placeholder-key          placeholder_ids_replaced            prompt  y
assert_fail_rule "test userId"               bad-test-userid              user_id_not_test_value              prompt  y
assert_fail_rule "test userId (multiline)"   bad-userid-multiline         user_id_not_test_value              prompt  y

# --- surface-class rules (loop can't infer; integrator emits rollback hint) -
assert_fail_rule "duplicate init"            bad-double-init              init_count                          surface y
assert_fail_rule "missing init (codegen bug)" bad-no-init                init_count                          surface n
assert_fail_rule "load/show parity"          bad-load-no-show             interstitial_load_show_parity       surface n

# --- loop exit condition: a correctly-integrated project PASSes -------------
assert_pass "good fresh"          good-fresh
assert_pass "good straight-swap"  good-straight-swap

echo
echo "Pass: $pass   Fail: $fail"
[ "$fail" = "0" ] || exit 1
