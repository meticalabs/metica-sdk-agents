#!/bin/bash
# run-resolver-tests.sh — eval for scripts/resolve-plugin-dir.sh and the agent
# bootstrap loop that finds and runs it.
#
# The agent runtime does NOT reliably export $CLAUDE_PLUGIN_ROOT into a bash
# tool call (verified empirically). These tests pin down the fallbacks that
# make resolution work anyway: self-location from the script's own path, the
# marketplace-cache glob, and version-sort when several versions are cached.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVER="${SCRIPT_DIR}/../scripts/resolve-plugin-dir.sh"

pass=0
fail=0

assert_eq() {
    local name="$1" expected="$2" got="$3"
    if [ "$expected" = "$got" ]; then
        printf "  ok    %s\n" "$name"
        pass=$((pass+1))
    else
        printf "  FAIL  %s\n        expected=[%s]\n        got     =[%s]\n" "$name" "$expected" "$got"
        fail=$((fail+1))
    fi
}

assert_exit() {
    local name="$1" expected="$2" got="$3"
    if [ "$expected" = "$got" ]; then
        printf "  ok    %s\n" "$name"
        pass=$((pass+1))
    else
        printf "  FAIL  %s: expected exit=%s got=%s\n" "$name" "$expected" "$got"
        fail=$((fail+1))
    fi
}

# Build a valid plugin root at $1 with a copy of the (current) resolver inside.
make_root() {
    local root="$1"
    mkdir -p "$root/.claude-plugin" "$root/agents" "$root/scripts"
    printf '{}\n' > "$root/.claude-plugin/plugin.json"
    cp "$RESOLVER" "$root/scripts/resolve-plugin-dir.sh"
}

echo "== resolve-plugin-dir eval =="

# 1. Self-location: env unset, empty HOME so no known path can match. The
#    resolver must still find its own root two levels up from the script.
T=$(mktemp -d); ROOT="$T/root"; make_root "$ROOT"
got=$(env -u CLAUDE_PLUGIN_ROOT -u METICA_SDK_AGENTS_DIR HOME="$T/emptyhome" \
        bash "$ROOT/scripts/resolve-plugin-dir.sh" 2>/dev/null)
assert_eq "self-location with all env unset" "$(cd "$ROOT" && pwd)" "$got"
rm -rf "$T"

# 2. $CLAUDE_PLUGIN_ROOT overrides self-location.
T=$(mktemp -d); ROOT="$T/root"; OVERRIDE="$T/override"; make_root "$ROOT"; make_root "$OVERRIDE"
got=$(env -u METICA_SDK_AGENTS_DIR HOME="$T/emptyhome" CLAUDE_PLUGIN_ROOT="$OVERRIDE" \
        bash "$ROOT/scripts/resolve-plugin-dir.sh" 2>/dev/null)
assert_eq "CLAUDE_PLUGIN_ROOT wins over self-location" "$OVERRIDE" "$got"

# 3. $METICA_SDK_AGENTS_DIR override (with CLAUDE_PLUGIN_ROOT unset).
got=$(env -u CLAUDE_PLUGIN_ROOT HOME="$T/emptyhome" METICA_SDK_AGENTS_DIR="$OVERRIDE" \
        bash "$ROOT/scripts/resolve-plugin-dir.sh" 2>/dev/null)
assert_eq "METICA_SDK_AGENTS_DIR override" "$OVERRIDE" "$got"
rm -rf "$T"

# 4. Marketplace-cache glob: resolver lives in a NON-root dir (self-location
#    fails), but a valid root exists under HOME's cache path.
T=$(mktemp -d)
mkdir -p "$T/loose/scripts"; cp "$RESOLVER" "$T/loose/scripts/resolve-plugin-dir.sh"
CACHE="$T/.claude/plugins/cache/metica-sdk-agents/metica-sdk-agents/0.2.0"; make_root "$CACHE"
got=$(env -u CLAUDE_PLUGIN_ROOT -u METICA_SDK_AGENTS_DIR HOME="$T" \
        bash "$T/loose/scripts/resolve-plugin-dir.sh" 2>/dev/null)
assert_eq "marketplace-cache glob discovery" "$(cd "$CACHE" && pwd)" "$got"

# 5. Multiple cached versions → highest (version-sort, not lexical).
CACHE2="$T/.claude/plugins/cache/metica-sdk-agents/metica-sdk-agents/0.10.0"; make_root "$CACHE2"
got=$(env -u CLAUDE_PLUGIN_ROOT -u METICA_SDK_AGENTS_DIR HOME="$T" \
        bash "$T/loose/scripts/resolve-plugin-dir.sh" 2>/dev/null)
assert_eq "multi-version cache picks highest (0.10.0 > 0.2.0)" "$(cd "$CACHE2" && pwd)" "$got"
rm -rf "$T"

# 6. Failure path: resolver in a non-root dir, env unset, empty HOME, empty
#    cache. Must exit 1 cleanly (no 'unbound variable' on bash 3.2 empty array).
T=$(mktemp -d)
mkdir -p "$T/loose/scripts"; cp "$RESOLVER" "$T/loose/scripts/resolve-plugin-dir.sh"
err=$(env -u CLAUDE_PLUGIN_ROOT -u METICA_SDK_AGENTS_DIR HOME="$T/emptyhome" \
        bash "$T/loose/scripts/resolve-plugin-dir.sh" 2>&1 1>/dev/null); rc=$?
assert_exit "failure path exits 1" "1" "$rc"
if printf '%s' "$err" | grep -q 'unbound variable'; then
    printf "  FAIL  failure path: emitted 'unbound variable' (bash 3.2 empty-array bug)\n"; fail=$((fail+1))
else
    printf "  ok    failure path: clean diagnostic, no unbound-variable crash\n"; pass=$((pass+1))
fi
rm -rf "$T"

# Bootstrap loop end-to-end. run_bootstrap mirrors verbatim the snippet that
# lives in all three agent files (unity-{integrator,validator,compat-checker}.md);
# keep all four copies in sync. Runs with env unset and a fake HOME so only the
# cache path can match.
run_bootstrap() {  # $1 = HOME
    env -u CLAUDE_PLUGIN_ROOT -u METICA_SDK_AGENTS_DIR HOME="$1" bash -c '
PLUGIN_DIR=""
for cand in "${CLAUDE_PLUGIN_ROOT:-}" "${METICA_SDK_AGENTS_DIR:-}" \
            "$(ls -d "$HOME"/.claude/plugins/cache/*/metica-sdk-agents/* 2>/dev/null | sort -V 2>/dev/null | tail -1)" \
            "$HOME"/.claude/plugins/cache/*/metica-sdk-agents/* \
            "$HOME/.claude/plugins/marketplaces/metica-sdk-agents" \
            "$HOME/.claude/plugins/metica-sdk-agents" \
            "$HOME/.metica-sdk-agents" "$HOME/dev/metica-sdk-agents"; do
    [ -n "$cand" ] && [ -f "$cand/scripts/resolve-plugin-dir.sh" ] || continue
    PLUGIN_DIR="$(bash "$cand/scripts/resolve-plugin-dir.sh" 2>/dev/null)" && [ -n "$PLUGIN_DIR" ] && break
done
printf "%s" "$PLUGIN_DIR"
'
}

# 7. Single cached version, only reachable via the cache path under HOME.
T=$(mktemp -d)
CACHE="$T/.claude/plugins/cache/metica-sdk-agents/metica-sdk-agents/0.3.0"; make_root "$CACHE"
assert_eq "agent bootstrap loop finds cache root" "$(cd "$CACHE" && pwd)" "$(run_bootstrap "$T")"
rm -rf "$T"

# 8. Multiple cached versions: the bootstrap must pick the HIGHEST, not the
#    lexicographically-first. Glob order alone would pick 0.2.0 ("0.2.0" <
#    "0.3.0"); the version-sort in the snippet must override that, else an old
#    cached copy left behind by an upgrade silently wins.
T=$(mktemp -d)
for v in 0.2.0 0.3.0; do
    make_root "$T/.claude/plugins/cache/metica-sdk-agents/metica-sdk-agents/$v"
done
NEWEST="$T/.claude/plugins/cache/metica-sdk-agents/metica-sdk-agents/0.3.0"
assert_eq "bootstrap picks newest of two cached versions (0.3.0 > 0.2.0)" \
    "$(cd "$NEWEST" && pwd)" "$(run_bootstrap "$T")"
rm -rf "$T"

# 9. Two-digit minor must sort by version, not lexically (0.10.0 > 0.9.0).
T=$(mktemp -d)
for v in 0.9.0 0.10.0; do
    make_root "$T/.claude/plugins/cache/metica-sdk-agents/metica-sdk-agents/$v"
done
NEWEST="$T/.claude/plugins/cache/metica-sdk-agents/metica-sdk-agents/0.10.0"
assert_eq "bootstrap picks newest with 2-digit minor (0.10.0 > 0.9.0)" \
    "$(cd "$NEWEST" && pwd)" "$(run_bootstrap "$T")"
rm -rf "$T"

# 10. Symlink-resolution branch (install.sh project-local / global layouts):
#     a .claude/agents/unity-integrator.md symlinking into <plugin_root>/agents/
#     must resolve back to <plugin_root>. Self-location is forced to fail by
#     running a copy of the resolver from a non-root dir; HOME points at an
#     empty dir so the known-install-paths fallback can't accidentally match.
T=$(mktemp -d)
REAL="$T/realroot"; make_root "$REAL"
PROJ="$T/proj"; mkdir -p "$PROJ/.claude/agents"
ln -s "$REAL/agents/unity-integrator.md" "$PROJ/.claude/agents/unity-integrator.md"
mkdir -p "$T/loose/scripts"; cp "$RESOLVER" "$T/loose/scripts/resolve-plugin-dir.sh"
got=$(cd "$PROJ" && env -u CLAUDE_PLUGIN_ROOT -u METICA_SDK_AGENTS_DIR HOME="$T/emptyhome" \
        bash "$T/loose/scripts/resolve-plugin-dir.sh" 2>/dev/null)
assert_eq "symlink-resolution finds plugin root via project .claude/agents/<symlink>" \
    "$(cd "$REAL" && pwd)" "$got"
rm -rf "$T"

echo "----"
printf "passed: %d   failed: %d\n" "$pass" "$fail"
[ "$fail" -eq 0 ]
