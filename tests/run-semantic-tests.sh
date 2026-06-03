#!/bin/bash
# run-semantic-tests.sh — deterministic guards for the semantic-adjudication
# calibration corpus (tests/semantic-fixtures/).
#
# The LLM verdict itself is evaluated OUT OF BAND (see semantic-fixtures/README.md);
# CI cannot run a model. What CI *can* and must guard deterministically:
#   (a) the grep shadow verdict stays stable per fixture — this documents the
#       grep/semantic divergence the layer exists to fix, and trips if the
#       deterministic floor drifts;
#   (b) every cited evidence line in each fixture's expected-evidence.tsv still
#       resolves via scripts/check-citation.sh — so the goldens can't bit-rot
#       when fixture source is edited.

set -u

# Synthetic fixtures are not openable Unity projects — never launch a real compile.
export METICA_SKIP_COMPILE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATE="$SCRIPT_DIR/../scripts/validate-integration.sh"
CHECK_CITATION="$SCRIPT_DIR/../scripts/check-citation.sh"
FIX="$SCRIPT_DIR/semantic-fixtures"

pass=0
fail=0
ok()  { echo "  ok    $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }

# Extract the level of a named rule from a validator JSON blob.
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

echo "== semantic-fixtures: deterministic guards =="

# (a) grep shadow verdicts stay stable.
while IFS=$'\t' read -r fixture rule grep_shadow semantic_expected note; do
    [ "$fixture" = "fixture" ] && continue   # header
    [ -z "$fixture" ] && continue
    out="$(bash "$VALIDATE" --project="$FIX/$fixture" 2>&1)" || true
    got="$(level_of_rule "$out" "$rule")"
    if [ "$got" = "$grep_shadow" ]; then
        ok "grep shadow stable: $fixture/$rule = $got (semantic target: $semantic_expected)"
    else
        bad "grep shadow drift: $fixture/$rule expected=$grep_shadow got=$got"
        printf '%s\n' "$out" | sed 's/^/        /'
    fi
done < "$FIX/expected-verdicts.tsv"

# (b) every fixture's cited evidence resolves.
for ev in "$FIX"/*/expected-evidence.tsv; do
    [ -f "$ev" ] || continue
    fixture_dir="$(dirname "$ev")"
    fixture="$(basename "$fixture_dir")"
    if bash "$CHECK_CITATION" --project="$fixture_dir" < "$ev" >/dev/null; then
        ok "evidence citations resolve: $fixture"
    else
        bad "evidence citations DO NOT resolve: $fixture"
        bash "$CHECK_CITATION" --project="$fixture_dir" < "$ev" | sed 's/^/        /'
    fi
done

echo
echo "Pass: $pass   Fail: $fail"
echo "(LLM verdict agreement is evaluated out-of-band — see semantic-fixtures/README.md)"
[ "$fail" = "0" ] || exit 1
