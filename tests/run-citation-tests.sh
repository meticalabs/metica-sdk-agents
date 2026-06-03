#!/bin/bash
# run-citation-tests.sh — unit tests for scripts/check-citation.sh.
#
# check-citation.sh is the deterministic anti-hallucination guard for the
# validator's semantic phase: it confirms every line-cited piece of evidence the
# LLM returns actually exists in the source at the cited line. Because it is
# deterministic, it is the one part of the semantic path we golden/unit-test here;
# the LLM verdict itself is evaluated out-of-band against tests/semantic-fixtures/.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CC="$SCRIPT_DIR/../scripts/check-citation.sh"

pass=0
fail=0
ok()  { echo "  ok    $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }

# A throwaway project with one source file of known content.
proj="$(mktemp -d -t metica-cite-XXXXXX)"
mkdir -p "$proj/Assets/Scripts/Metica"
cat > "$proj/Assets/Scripts/Metica/MeticaInterstitialAd.cs" <<'EOF'
void RewardedAdsView_OnAdClosed(MeticaAd ad)
{
    if (m_IsAutoReload) RestartRewardedCycle();
}

void RestartRewardedCycle()
{
    MeticaSdk.Ads.LoadRewarded(m_Config.rewardedID);
}
EOF
F="Assets/Scripts/Metica/MeticaInterstitialAd.cs"

echo "== check-citation.sh unit tests =="

# 1. Exact line match → OK, exit 0.
out="$(printf '%s\t%s\t%s\n' "$F" 8 "MeticaSdk.Ads.LoadRewarded(m_Config.rewardedID);" | bash "$CC" --project="$proj")"; rc=$?
{ [ "$rc" = "0" ] && printf '%s' "$out" | grep -q "^OK"; } \
    && ok "exact line match → OK exit 0" || bad "exact match (rc=$rc, out=$out)"

# 2. Substring of the line still matches (agent cited only part of the line).
out="$(printf '%s\t%s\t%s\n' "$F" 3 "RestartRewardedCycle()" | bash "$CC" --project="$proj")"; rc=$?
{ [ "$rc" = "0" ] && printf '%s' "$out" | grep -q "^OK"; } \
    && ok "substring match → OK" || bad "substring (rc=$rc, out=$out)"

# 3. Indentation / whitespace difference is tolerated (normalization).
out="$(printf '%s\t%s\t%s\n' "$F" 3 "if   (m_IsAutoReload)    RestartRewardedCycle();" | bash "$CC" --project="$proj")"; rc=$?
{ [ "$rc" = "0" ] && printf '%s' "$out" | grep -q "^OK"; } \
    && ok "whitespace-collapsed match → OK" || bad "whitespace (rc=$rc, out=$out)"

# 4. Hallucinated content on a real line → MISMATCH, exit 1.
out="$(printf '%s\t%s\t%s\n' "$F" 3 "LoadRewarded called here directly" | bash "$CC" --project="$proj")"; rc=$?
{ [ "$rc" = "1" ] && printf '%s' "$out" | grep -q "^MISMATCH"; } \
    && ok "wrong snippet on real line → MISMATCH exit 1" || bad "wrong snippet (rc=$rc, out=$out)"

# 5. Line out of range → MISMATCH.
out="$(printf '%s\t%s\t%s\n' "$F" 999 "anything" | bash "$CC" --project="$proj")"; rc=$?
{ [ "$rc" = "1" ] && printf '%s' "$out" | grep -q "out of range"; } \
    && ok "line out of range → MISMATCH" || bad "out of range (rc=$rc, out=$out)"

# 6. Missing file → MISMATCH.
out="$(printf '%s\t%s\t%s\n' "Assets/Nope.cs" 1 "x" | bash "$CC" --project="$proj")"; rc=$?
{ [ "$rc" = "1" ] && printf '%s' "$out" | grep -q "file not found"; } \
    && ok "missing file → MISMATCH" || bad "missing file (rc=$rc, out=$out)"

# 7. Empty snippet → MISMATCH (a PASS citation must point at real code).
out="$(printf '%s\t%s\t%s\n' "$F" 1 "" | bash "$CC" --project="$proj")"; rc=$?
{ [ "$rc" = "1" ] && printf '%s' "$out" | grep -q "empty snippet"; } \
    && ok "empty snippet → MISMATCH" || bad "empty snippet (rc=$rc, out=$out)"

# 8. Mixed batch: one good + one bad → overall exit 1, both records present.
out="$(printf '%s\t%s\t%s\n%s\t%s\t%s\n' \
        "$F" 1 "RewardedAdsView_OnAdClosed" \
        "$F" 3 "totally fabricated" | bash "$CC" --project="$proj")"; rc=$?
n_ok="$(printf '%s\n' "$out" | grep -c '^OK')"
n_bad="$(printf '%s\n' "$out" | grep -c '^MISMATCH')"
{ [ "$rc" = "1" ] && [ "$n_ok" = "1" ] && [ "$n_bad" = "1" ]; } \
    && ok "mixed batch → 1 OK + 1 MISMATCH, exit 1" || bad "mixed (rc=$rc, ok=$n_ok, bad=$n_bad)"

# 9. Empty input → exit 0 (nothing to verify is vacuously fine).
out="$(printf '' | bash "$CC" --project="$proj")"; rc=$?
{ [ "$rc" = "0" ] && [ -z "$out" ]; } \
    && ok "empty input → exit 0, no output" || bad "empty input (rc=$rc, out=$out)"

# 10. Absolute path works without --project.
out="$(printf '%s\t%s\t%s\n' "$proj/$F" 8 "LoadRewarded" | bash "$CC")"; rc=$?
{ [ "$rc" = "0" ] && printf '%s' "$out" | grep -q "^OK"; } \
    && ok "absolute path, no --project → OK" || bad "absolute path (rc=$rc, out=$out)"

# 11. Non-integer line → MISMATCH.
out="$(printf '%s\t%s\t%s\n' "$F" "8x" "LoadRewarded" | bash "$CC" --project="$proj")"; rc=$?
{ [ "$rc" = "1" ] && printf '%s' "$out" | grep -q "not a positive integer"; } \
    && ok "non-integer line → MISMATCH" || bad "non-integer (rc=$rc, out=$out)"

# 12. Unknown arg → exit 2.
out="$(bash "$CC" --bogus 2>&1)"; rc=$?
[ "$rc" = "2" ] && ok "unknown arg → exit 2" || bad "unknown arg (rc=$rc, out=$out)"

# 13. Bad --project dir → exit 2.
out="$(bash "$CC" --project=/no/such/dir 2>&1 <<<'')"; rc=$?
[ "$rc" = "2" ] && ok "nonexistent --project → exit 2" || bad "bad project (rc=$rc, out=$out)"

# 14. Exactly one line past EOF on a newline-terminated file → "out of range",
# NOT a confusing "snippet not found" (regression guard for the awk NR line count).
nlines="$(awk 'END{print NR}' "$proj/$F")"
out="$(printf '%s\t%s\t%s\n' "$F" "$((nlines + 1))" "anything" | bash "$CC" --project="$proj")"; rc=$?
{ [ "$rc" = "1" ] && printf '%s' "$out" | grep -q "out of range"; } \
    && ok "one past EOF (newline-terminated) → out of range" || bad "one-past-EOF (rc=$rc, out=$out)"

rm -rf "$proj"

echo
echo "Pass: $pass   Fail: $fail"
[ "$fail" = "0" ] || exit 1
