#!/bin/bash
# run-compile-tests.sh — unit tests for scripts/compile-check.sh.
#
# We can't ship a real Unity editor in CI, so the happy/error paths are driven by
# a FAKE Unity binary (pointed at via UNITY_PATH) that writes a canned Unity-style
# log to the -logFile path it is handed. This exercises the script's real argument
# handling, log parsing, and exit-code mapping end-to-end without Unity.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CC="$SCRIPT_DIR/../scripts/compile-check.sh"

pass=0
fail=0

ok()   { echo "  ok    $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL  $1"; fail=$((fail+1)); }

# A throwaway Unity project skeleton.
make_project() {
    local dir; dir="$(mktemp -d -t metica-cc-proj-XXXXXX)"
    mkdir -p "$dir/Assets/Scripts" "$dir/ProjectSettings"
    printf 'm_EditorVersion: 2022.3.62f2\n' > "$dir/ProjectSettings/ProjectVersion.txt"
    printf 'public class A {}\n' > "$dir/Assets/Scripts/A.cs"
    echo "$dir"
}

# A fake Unity binary that finds -logFile in its args and writes $FAKE_LOG_BODY
# into it, then exits with $FAKE_RC. Captured from env so each test can vary it.
make_fake_unity() {
    local body="$1" rc="${2:-0}"
    local f; f="$(mktemp -t metica-fake-unity-XXXXXX)"
    cat > "$f" <<EOF
#!/bin/bash
log=""
prev=""
for a in "\$@"; do
    [ "\$prev" = "-logFile" ] && log="\$a"
    prev="\$a"
done
[ -n "\$log" ] && printf '%s' "$(printf '%s' "$body" | sed "s/'/'\\\\''/g")" > "\$log"
exit $rc
EOF
    chmod +x "$f"
    echo "$f"
}

echo "== compile-check.sh unit tests =="

# 1. Missing --project → FAIL exit 2
out="$(bash "$CC" 2>&1)"; rc=$?
{ [ "$rc" = "2" ] && printf '%s' "$out" | grep -q '^FAIL'; } \
    && ok "missing --project → FAIL exit 2" || bad "missing --project (rc=$rc, out=$out)"

# 2. Nonexistent project → FAIL exit 2
out="$(bash "$CC" --project=/no/such/dir 2>&1)"; rc=$?
{ [ "$rc" = "2" ] && printf '%s' "$out" | grep -q 'not found'; } \
    && ok "nonexistent project → FAIL exit 2" || bad "nonexistent project (rc=$rc)"

# 3. Unknown arg → FAIL exit 2
p="$(make_project)"
out="$(bash "$CC" --project="$p" --bogus 2>&1)"; rc=$?
{ [ "$rc" = "2" ] && printf '%s' "$out" | grep -q 'Unknown arg'; } \
    && ok "unknown arg → FAIL exit 2" || bad "unknown arg (rc=$rc)"

# 4. METICA_SKIP_COMPILE=1 → SKIP exit 3 (and never consults UNITY_PATH)
out="$(METICA_SKIP_COMPILE=1 UNITY_PATH=/bin/true bash "$CC" --project="$p" 2>&1)"; rc=$?
{ [ "$rc" = "3" ] && printf '%s' "$out" | grep -q '^SKIP'; } \
    && ok "METICA_SKIP_COMPILE=1 → SKIP exit 3" || bad "skip-env (rc=$rc, out=$out)"

# 5. UNITY_PATH set but not executable → SKIP exit 3
out="$(UNITY_PATH=/no/such/unity bash "$CC" --project="$p" 2>&1)"; rc=$?
{ [ "$rc" = "3" ] && printf '%s' "$out" | grep -q 'not executable'; } \
    && ok "non-executable UNITY_PATH → SKIP exit 3" || bad "bad UNITY_PATH (rc=$rc, out=$out)"

# 6. Fake Unity, CLEAN log → OK exit 0
clean_log="$(printf 'Initialize engine version: 2022.3.62f2\nMono: successfully reloaded assembly\nExiting batchmode successfully now!\n')"
fu="$(make_fake_unity "$clean_log" 0)"
out="$(UNITY_PATH="$fu" bash "$CC" --project="$p" 2>&1)"; rc=$?
{ [ "$rc" = "0" ] && printf '%s' "$out" | grep -q '^OK$'; } \
    && ok "clean compile → OK exit 0" || bad "clean compile (rc=$rc, out=$out)"
rm -f "$fu"

# 7. Fake Unity, log WITH the two issue-#8 compile errors → one ERROR record each, exit 1
err_log="$(printf '%s\n%s\n%s\n' \
    "Assets/Scripts/Metica/MeticaAdService.cs(32,62): error CS0103: The name 'MeticaMediationType' does not exist in the current context" \
    "Assets/Scripts/Metica/MeticaAdService.cs(39,59): error CS1061: 'MeticaSmartFloors' does not contain a definition for 'isForcedHoldout'" \
    "Exiting batchmode successfully now!")"
fu="$(make_fake_unity "$err_log" 0)"
out="$(UNITY_PATH="$fu" bash "$CC" --project="$p" 2>&1)"; rc=$?
n_err="$(printf '%s\n' "$out" | grep -c '^ERROR')"
if [ "$rc" = "1" ] && [ "$n_err" = "2" ] \
    && printf '%s' "$out" | grep -qP '^ERROR\tAssets/Scripts/Metica/MeticaAdService\.cs\t32\tCS0103: ' \
    && printf '%s' "$out" | grep -qP '^ERROR\tAssets/Scripts/Metica/MeticaAdService\.cs\t39\tCS1061: '; then
    ok "compile errors → 2 ERROR records (file/line/msg) exit 1"
else
    bad "compile errors (rc=$rc, n_err=$n_err)"; printf '%s\n' "$out" | sed 's/^/        /'
fi
rm -f "$fu"

# 7b. CRLF log + a path containing '(' — the file field must keep the parens and
# carry no trailing carriage return (regression: file="${loc%(*}" not %%, + \r strip).
paren_log="$(printf 'Assets/Foo (copy).cs(7,3): error CS0246: type not found\r\n')"
fu="$(make_fake_unity "$paren_log" 0)"
out="$(UNITY_PATH="$fu" bash "$CC" --project="$p" 2>&1)"; rc=$?
if [ "$rc" = "1" ] && printf '%s' "$out" | grep -qP '^ERROR\tAssets/Foo \(copy\)\.cs\t7\tCS0246: type not found$'; then
    ok "paren-in-path + CRLF → file kept intact, no trailing CR"
else
    bad "paren/CRLF parse (rc=$rc)"; printf '%s\n' "$out" | cat -A | sed 's/^/        /'
fi
rm -f "$fu"

# 8. Fake Unity that produces NO log and exits non-zero → FAIL (non-completion) exit 2
nolog="$(mktemp -t metica-fake-unity-XXXXXX)"
printf '#!/bin/bash\nexit 1\n' > "$nolog"; chmod +x "$nolog"
out="$(UNITY_PATH="$nolog" bash "$CC" --project="$p" 2>&1)"; rc=$?
{ [ "$rc" = "2" ] && printf '%s' "$out" | grep -q '^FAIL'; } \
    && ok "Unity ran, empty log, nonzero → FAIL exit 2" || bad "non-completion (rc=$rc, out=$out)"
rm -f "$nolog"

rm -rf "$p"

echo
echo "Pass: $pass   Fail: $fail"
[ "$fail" = "0" ] || exit 1
