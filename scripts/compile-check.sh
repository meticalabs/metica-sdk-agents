#!/bin/bash
# compile-check.sh — compile a Unity project in batch mode and surface C# compile
# errors. This is the authoritative "does the integration actually build" check
# the validator's `compiles_cleanly` rule delegates to.
#
# Why Unity and not csc/dotnet: Unity C# only compiles against the editor's
# managed assemblies (UnityEngine.*), the project's package assemblies, the
# vendored SDK source, and the active scripting-define symbols + .asmdef graph.
# A raw `csc`/`dotnet` invocation can't see any of that, so it would emit hundreds
# of spurious "type or namespace not found" errors and bury the real ones. We
# therefore compile with the actual Unity editor or skip — we never guess.
#
# Usage: compile-check.sh --project=<path>
#
# stdout (tab-delimited, one record per line):
#   OK                                          compiled with zero C# errors
#   ERROR<TAB>file<TAB>line<TAB>CScode: message  (one per compile error)
#   SKIP<TAB><reason>                           no Unity located / disabled
#   FAIL<TAB><reason>                           Unity ran but could not complete
#
# Exit: 0 = clean, 1 = compile errors, 2 = run did not complete, 3 = skipped,
#       2 also used for invocation errors (with a FAIL line).
#
# Env:
#   METICA_SKIP_COMPILE=1   force SKIP (used by the plugin's own test suites so
#                           synthetic fixtures never launch Unity).
#   UNITY_PATH=<binary>     explicit Unity editor binary (takes precedence over
#                           the version-derived Unity Hub search).
#   METICA_COMPILE_TIMEOUT  seconds before the batch compile is abandoned
#                           (default 900). Requires `timeout` on PATH; ignored if
#                           absent.

set -u

PROJECT=""

for arg in "$@"; do
    case $arg in
        --project=*) PROJECT="${arg#*=}" ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) printf 'FAIL\tUnknown arg: %s\n' "$arg"; exit 2 ;;
    esac
done

[ -n "$PROJECT" ]        || { printf 'FAIL\tMissing --project=<path>\n'; exit 2; }
[ -d "$PROJECT" ]        || { printf 'FAIL\tProject not found: %s\n' "$PROJECT"; exit 2; }
[ -d "$PROJECT/Assets" ] || { printf 'FAIL\tNot a Unity project (no Assets/): %s\n' "$PROJECT"; exit 2; }

# Explicit opt-out (test suites, or a user who never wants the heavy compile).
if [ "${METICA_SKIP_COMPILE:-0}" = "1" ]; then
    printf 'SKIP\tcompile check disabled (METICA_SKIP_COMPILE=1)\n'
    exit 3
fi

# ---- locate a Unity editor -------------------------------------------------

editor_version() {
    local pv="$PROJECT/ProjectSettings/ProjectVersion.txt"
    [ -f "$pv" ] || return 0
    awk -F': ' '/^m_EditorVersion:/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "$pv"
}

locate_unity() {
    # 1. explicit override
    if [ -n "${UNITY_PATH:-}" ]; then
        [ -x "$UNITY_PATH" ] && { printf '%s' "$UNITY_PATH"; return 0; }
        return 1   # an explicit-but-wrong path is an error the caller should see
    fi
    # 2. version-derived Unity Hub install locations (macOS / Linux / Windows-git-bash)
    local ver; ver="$(editor_version)"
    if [ -n "$ver" ]; then
        local c
        for c in \
            "/Applications/Unity/Hub/Editor/$ver/Unity.app/Contents/MacOS/Unity" \
            "$HOME/Unity/Hub/Editor/$ver/Editor/Unity" \
            "/opt/unity/editors/$ver/Editor/Unity" \
            "/opt/Unity/Hub/Editor/$ver/Editor/Unity" \
            "/c/Program Files/Unity/Hub/Editor/$ver/Editor/Unity.exe" \
            "/mnt/c/Program Files/Unity/Hub/Editor/$ver/Editor/Unity.exe" \
        ; do
            [ -x "$c" ] && { printf '%s' "$c"; return 0; }
        done
    fi
    # 3. anything on PATH
    local p
    for p in unity-editor Unity unity; do
        if command -v "$p" >/dev/null 2>&1; then command -v "$p"; return 0; fi
    done
    return 1
}

UNITY="$(locate_unity)" || {
    if [ -n "${UNITY_PATH:-}" ]; then
        printf 'SKIP\tUNITY_PATH set but not executable: %s\n' "$UNITY_PATH"
    else
        printf 'SKIP\tno Unity editor located (set UNITY_PATH to your Unity binary to enable the compile check)\n'
    fi
    exit 3
}

# ---- run the batch compile -------------------------------------------------

LOG="$(mktemp -t metica-compile-XXXXXX.log)"
trap 'rm -f "$LOG"' EXIT

# Opening the project in -batchmode -quit triggers a script compile; Unity writes
# any `error CS####` to the log. -nographics avoids a display dependency.
RUN=( "$UNITY" -batchmode -quit -nographics -projectPath "$PROJECT" -logFile "$LOG" )

TIMEOUT="${METICA_COMPILE_TIMEOUT:-900}"
if command -v timeout >/dev/null 2>&1; then
    timeout "$TIMEOUT" "${RUN[@]}" >/dev/null 2>&1
    rc=$?
else
    "${RUN[@]}" >/dev/null 2>&1
    rc=$?
fi

if [ "$rc" = "124" ]; then
    printf 'FAIL\tUnity batch compile timed out after %ss (raise METICA_COMPILE_TIMEOUT)\n' "$TIMEOUT"
    exit 2
fi

# Parse compile errors from the log regardless of Unity's exit code — Unity often
# exits 0 even when scripts fail to compile, so the log is the source of truth.
# Format: Assets/Foo/Bar.cs(12,34): error CS0103: The name 'X' does not exist...
ERR_LINES="$(grep -aoE '[^[:space:]].*\.cs\([0-9]+,[0-9]+\): error CS[0-9]+: .*' "$LOG" 2>/dev/null | sort -u)"

if [ -n "$ERR_LINES" ]; then
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        loc="${line%%): error*}"        # Assets/...cs(12,34
        file="${loc%%(*}"               # Assets/...cs
        linecol="${loc##*(}"            # 12,34
        ln="${linecol%%,*}"             # 12
        msg="${line#*): error }"        # CS0103: The name 'X' does not exist...
        printf 'ERROR\t%s\t%s\t%s\n' "$file" "$ln" "$msg"
    done <<< "$ERR_LINES"
    exit 1
fi

# No errors parsed. If Unity itself failed to run (non-zero) with an empty/odd
# log, report a non-completion rather than a misleading clean pass.
if [ "$rc" != "0" ] && [ ! -s "$LOG" ]; then
    printf 'FAIL\tUnity exited %s without producing a log (activation/license?)\n' "$rc"
    exit 2
fi

printf 'OK\n'
exit 0
