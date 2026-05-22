#!/bin/bash
# detect-mode.sh — decide whether MeticaSDK integration into a Unity project
# should run in "fresh" mode (no existing ad SDK) or "side-by-side" mode
# (MaxSDK already present, never modify Max code; add a MeticaAdapter beside it).
#
# Multi-signal rule (two-of-three → side-by-side):
#   S1: Assets/MaxSdk/ directory exists
#   S2: a .cs file contains a MaxSdk.Initialize(... call (not in strings/comments)
#   S3: an Android manifest contains the applovin namespace, OR an applovin
#       Editor dependency XML exists
#
# Usage: detect-mode.sh --project=<path>
# Exit:  0 on success; 1 on invocation error.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT=""
for arg in "$@"; do
    case $arg in
        --project=*) PROJECT="${arg#*=}" ;;
        -h|--help)
            sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown arg: $arg" >&2; exit 1 ;;
    esac
done

[ -n "$PROJECT" ]        || { echo "Missing --project=<path>" >&2; exit 1; }
[ -d "$PROJECT" ]        || { echo "Project not found: $PROJECT" >&2; exit 1; }
[ -d "$PROJECT/Assets" ] || { echo "Not a Unity project (no Assets/): $PROJECT" >&2; exit 1; }

# ---- JSON helpers (small subset) -------------------------------------------

json_escape() {
    awk 'BEGIN { ORS=""; for (i=0;i<256;i++) ord[sprintf("%c",i)]=i }
    {
        if (NR>1) printf "\\n"
        n=length($0)
        for (i=1;i<=n;i++) {
            c=substr($0,i,1)
            if (c=="\\") printf "\\\\"
            else if (c=="\"") printf "\\\""
            else if (ord[c]<32) printf "\\u%04x", ord[c]
            else printf "%s", c
        }
    }' <<< "$1"
}

# ---- C# source cleaner (shared awk script) ---------------------------------

CLEAN_CS_AWK="$SCRIPT_DIR/lib/clean-cs.awk"
clean_cs() { awk -f "$CLEAN_CS_AWK" "$1"; }

# ---- signal detection ------------------------------------------------------

# S1: MaxSdk/ directory
S1=false
[ -d "$PROJECT/Assets/MaxSdk" ] && S1=true

# S2: MaxSdk.Initialize symbol in any .cs file (not inside strings/comments)
S2=false
S2_LOC=""
while IFS= read -r f; do
    n="$(clean_cs "$f" 2>/dev/null | grep -nF -- 'MaxSdk.Initialize' | head -1 | awk -F: '{ print $1 }')"
    if [ -n "$n" ]; then
        S2=true
        S2_LOC="$f:$n"
        break
    fi
done < <(find "$PROJECT/Assets" "$PROJECT/Packages" -type f -name '*.cs' 2>/dev/null \
            | grep -v '/MaxSdk/' \
            | grep -v '/PackageCache/' \
            | grep -v '/Library/' \
            | grep -v '/Temp/' \
            | grep -v '/obj/')

# S3: AppLovin manifest entry or Editor dependency XML
S3=false
S3_LOC=""
if [ -f "$PROJECT/Assets/Plugins/Android/AndroidManifest.xml" ] \
   && grep -qiF -- 'applovin' "$PROJECT/Assets/Plugins/Android/AndroidManifest.xml"; then
    S3=true
    S3_LOC="Assets/Plugins/Android/AndroidManifest.xml"
fi
if [ "$S3" = false ] && [ -f "$PROJECT/Assets/MaxSdk/AppLovin/Editor/Dependencies.xml" ]; then
    S3=true
    S3_LOC="Assets/MaxSdk/AppLovin/Editor/Dependencies.xml"
fi

# ---- decide ----------------------------------------------------------------

count=0
[ "$S1" = true ] && count=$((count + 1))
[ "$S2" = true ] && count=$((count + 1))
[ "$S3" = true ] && count=$((count + 1))

if [ "$count" -ge 2 ]; then
    MODE="side-by-side"
    REASON="$count of 3 signals present (>=2 → side-by-side)."
else
    MODE="fresh"
    REASON="$count of 3 signals present (<2 → fresh)."
fi

# ---- emit JSON --------------------------------------------------------------

printf '{\n'
printf '  "schema": "mode-detect/1.0.0",\n'
printf '  "mode": "%s",\n' "$MODE"
printf '  "signals": {\n'
printf '    "maxsdk_folder":       { "present": %s, "location": "%s" },\n' "$S1" "$( [ "$S1" = true ] && printf '%s' 'Assets/MaxSdk/' )"
printf '    "maxsdk_init_symbol":  { "present": %s, "location": "%s" },\n' "$S2" "$(json_escape "$S2_LOC")"
printf '    "applovin_manifest":   { "present": %s, "location": "%s" }\n'  "$S3" "$(json_escape "$S3_LOC")"
printf '  },\n'
printf '  "decision": "%s"\n' "$(json_escape "$REASON")"
printf '}\n'
