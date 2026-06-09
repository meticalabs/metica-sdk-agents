#!/bin/bash
# run-update-check-tests.sh — unit tests for scripts/check-for-update.sh.
#
# The script fetches the latest plugin.json over the network and semver-compares
# it to the locally-installed version. We can't hit the real network in CI, so a
# FAKE curl (and a minimal tool dir on PATH) drives every path hermetically:
# the fake curl prints $FAKE_REMOTE_JSON and exits $FAKE_CURL_RC. This exercises
# the script's real root-resolution, version parsing, comparison, fail-open
# branches, and the SessionStart JSON it emits — without a network.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CU="$SCRIPT_DIR/../scripts/check-for-update.sh"

pass=0
fail=0
ok()  { echo "  ok    $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }

# A throwaway plugin root carrying a .claude-plugin/plugin.json at $1's version.
make_root() {
    local v="$1" d
    d="$(mktemp -d -t metica-cu-root-XXXXXX)"
    mkdir -p "$d/.claude-plugin"
    printf '{\n  "name": "metica-sdk-agents",\n  "version": "%s"\n}\n' "$v" \
        > "$d/.claude-plugin/plugin.json"
    echo "$d"
}

# A bin dir with the external tools the script needs, plus a fake curl that
# prints $FAKE_REMOTE_JSON and exits $FAKE_CURL_RC (default 0).
BIN="$(mktemp -d -t metica-cu-bin-XXXXXX)"
for t in bash sed head tail sort dirname; do ln -s "$(command -v "$t")" "$BIN/$t" 2>/dev/null; done
cat > "$BIN/curl" <<'EOF'
#!/bin/bash
[ "${FAKE_CURL_RC:-0}" != "0" ] && exit "${FAKE_CURL_RC}"
printf '%s' "${FAKE_REMOTE_JSON:-}"
EOF
chmod +x "$BIN/curl"

# Same tool dir but WITHOUT curl — to exercise the "curl missing" branch.
NOCURL="$(mktemp -d -t metica-cu-nocurl-XXXXXX)"
for t in bash sed head tail sort dirname; do ln -s "$(command -v "$t")" "$NOCURL/$t" 2>/dev/null; done

echo "== check-for-update.sh unit tests =="

# 1. Opt-out env wins even when an update exists → silent, exit 0.
r="$(make_root 2.1.0)"
out="$(METICA_SKIP_UPDATE_CHECK=1 PATH="$BIN" CLAUDE_PLUGIN_ROOT="$r" \
       FAKE_REMOTE_JSON='{"version":"9.9.9"}' bash "$CU" </dev/null 2>&1)"; rc=$?
{ [ "$rc" = "0" ] && [ -z "$out" ]; } \
    && ok "METICA_SKIP_UPDATE_CHECK=1 → silent no-op" || bad "opt-out (rc=$rc, out=$out)"
rm -rf "$r"

# 2. Remote strictly newer → SessionStart notice naming both versions + command.
r="$(make_root 2.1.0)"
out="$(PATH="$BIN" CLAUDE_PLUGIN_ROOT="$r" \
       FAKE_REMOTE_JSON='{"version":"2.2.0"}' bash "$CU" </dev/null 2>&1)"; rc=$?
if [ "$rc" = "0" ] \
    && printf '%s' "$out" | grep -q '"hookEventName":"SessionStart"' \
    && printf '%s' "$out" | grep -q '"additionalContext"' \
    && printf '%s' "$out" | grep -q 'v2.1.0' \
    && printf '%s' "$out" | grep -q 'v2.2.0' \
    && printf '%s' "$out" | grep -q '/plugin marketplace update metica-sdk-agents'; then
    ok "remote newer → SessionStart additionalContext notice"
else
    bad "remote newer (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/        /'
fi
rm -rf "$r"

# 3. Remote equal → silent, exit 0.
r="$(make_root 2.1.0)"
out="$(PATH="$BIN" CLAUDE_PLUGIN_ROOT="$r" \
       FAKE_REMOTE_JSON='{"version":"2.1.0"}' bash "$CU" </dev/null 2>&1)"; rc=$?
{ [ "$rc" = "0" ] && [ -z "$out" ]; } \
    && ok "remote equal → silent" || bad "remote equal (rc=$rc, out=$out)"
rm -rf "$r"

# 4. Remote older → silent, exit 0 (no downgrade nag; 2.10 vs 2.9 sorts right too).
r="$(make_root 2.10.0)"
out="$(PATH="$BIN" CLAUDE_PLUGIN_ROOT="$r" \
       FAKE_REMOTE_JSON='{"version":"2.9.0"}' bash "$CU" </dev/null 2>&1)"; rc=$?
{ [ "$rc" = "0" ] && [ -z "$out" ]; } \
    && ok "remote older (semver, not lexical) → silent" || bad "remote older (rc=$rc, out=$out)"
rm -rf "$r"

# 5. Fetch fails (curl nonzero) → fail-open silent, exit 0.
r="$(make_root 2.1.0)"
out="$(PATH="$BIN" CLAUDE_PLUGIN_ROOT="$r" FAKE_CURL_RC=22 \
       FAKE_REMOTE_JSON='{"version":"9.9.9"}' bash "$CU" </dev/null 2>&1)"; rc=$?
{ [ "$rc" = "0" ] && [ -z "$out" ]; } \
    && ok "curl failure → fail-open silent" || bad "fetch fail (rc=$rc, out=$out)"
rm -rf "$r"

# 6. curl missing entirely → fail-open silent, exit 0.
r="$(make_root 2.1.0)"
out="$(PATH="$NOCURL" CLAUDE_PLUGIN_ROOT="$r" \
       FAKE_REMOTE_JSON='{"version":"9.9.9"}' bash "$CU" </dev/null 2>&1)"; rc=$?
{ [ "$rc" = "0" ] && [ -z "$out" ]; } \
    && ok "curl missing → fail-open silent" || bad "no curl (rc=$rc, out=$out)"
rm -rf "$r"

# 7. Local manifest has no parseable version → silent, exit 0 (never crash).
r="$(make_root nightly)"
out="$(PATH="$BIN" CLAUDE_PLUGIN_ROOT="$r" \
       FAKE_REMOTE_JSON='{"version":"2.2.0"}' bash "$CU" </dev/null 2>&1)"; rc=$?
{ [ "$rc" = "0" ] && [ -z "$out" ]; } \
    && ok "unparseable local version → silent" || bad "bad local version (rc=$rc, out=$out)"
rm -rf "$r"

# 8. Self-location: no CLAUDE_PLUGIN_ROOT, script run from inside a temp root's
#    scripts/ dir → it must read THAT root's plugin.json, not the repo's.
r="$(make_root 2.1.0)"; mkdir -p "$r/scripts"; cp "$CU" "$r/scripts/check-for-update.sh"
out="$( unset CLAUDE_PLUGIN_ROOT; PATH="$BIN" \
        FAKE_REMOTE_JSON='{"version":"3.0.0"}' bash "$r/scripts/check-for-update.sh" </dev/null 2>&1)"; rc=$?
{ [ "$rc" = "0" ] && printf '%s' "$out" | grep -q 'v3.0.0'; } \
    && ok "self-location resolves root without CLAUDE_PLUGIN_ROOT" || bad "self-location (rc=$rc, out=$out)"
rm -rf "$r"

# 9. No `sort`/`tail` on PATH → must still detect a newer version. Guards the
#    BSD/macOS regression where GNU-only `sort -V` would silently suppress the
#    notice; the compare is now pure bash.
NOSORT="$(mktemp -d -t metica-cu-nosort-XXXXXX)"
for t in bash sed head dirname; do ln -s "$(command -v "$t")" "$NOSORT/$t" 2>/dev/null; done
cp "$BIN/curl" "$NOSORT/curl"
r="$(make_root 2.1.0)"
out="$(PATH="$NOSORT" CLAUDE_PLUGIN_ROOT="$r" \
       FAKE_REMOTE_JSON='{"version":"2.2.0"}' bash "$CU" </dev/null 2>&1)"; rc=$?
{ [ "$rc" = "0" ] && printf '%s' "$out" | grep -q 'v2.2.0'; } \
    && ok "no sort/tail on PATH → still detects update (no GNU-sort dep)" \
    || bad "no-sort regression (rc=$rc, out=$out)"
rm -rf "$r" "$NOSORT"

rm -rf "$BIN" "$NOCURL"

echo
echo "Pass: $pass   Fail: $fail"
[ "$fail" = "0" ] || exit 1
