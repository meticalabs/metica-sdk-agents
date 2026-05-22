#!/bin/bash
# detect-compat.sh — detect environment versions in a Unity project and compare
# against the matrix in metica-versions.yaml. Emits JSON per the
# compat-checker/1.0.0 schema (see agents/contracts.md).
#
# Usage: detect-compat.sh --project=<path> [--version=<sdk_version>] [--yaml=<path>]
# Env:   MOCK_JAVA_VERSION=<x.y.z>   override java detection (testing)
# Exit:  0 = status PASS, 1 = status BLOCK (incl. invocation/YAML errors as JSON).

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAML_DEFAULT="${SCRIPT_DIR}/../metica-versions.yaml"

PROJECT=""
VERSION=""
YAML="$YAML_DEFAULT"

# ---- JSON helpers (defined early so error paths can use them) ---------------

json_escape() {
    # Minimal JSON string escape: backslash, double-quote, control chars, newlines.
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

jval() {
    if [ -z "$1" ]; then printf 'null'
    else printf '"%s"' "$(json_escape "$1")"
    fi
}

die_json() {
    # Emit a contract-shaped BLOCK with top-level error and exit 1.
    local msg="$1"
    printf '{\n'
    printf '  "schema": "compat-checker/1.0.0",\n'
    printf '  "status": "BLOCK",\n'
    printf '  "target_sdk": %s,\n' "$(jval "${VERSION:-}")"
    printf '  "error": "%s",\n' "$(json_escape "$msg")"
    printf '  "warnings": [],\n'
    printf '  "checks": []\n'
    printf '}\n'
    exit 1
}

# ---- args -------------------------------------------------------------------

for arg in "$@"; do
    case $arg in
        --project=*) PROJECT="${arg#*=}" ;;
        --version=*) VERSION="${arg#*=}" ;;
        --yaml=*)    YAML="${arg#*=}" ;;
        -h|--help)
            sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) die_json "Unknown arg: $arg" ;;
    esac
done

[ -n "$PROJECT" ] || die_json "Missing --project=<path>"
[ -d "$PROJECT" ] || die_json "Project not found: $PROJECT"
[ -f "$YAML" ]    || die_json "YAML not found: $YAML"

# ---- targeted YAML reader (POSIX-safe; knows our schema) --------------------

unquote() { sed 's/^"//; s/"$//'; }

yaml_top() {
    grep -E "^$1:[[:space:]]" "$YAML" | head -1 | sed -E "s/^$1:[[:space:]]*//" | unquote
}

yaml_version_field() {
    local ver="$1" field="$2"
    awk -v vkey="\"$ver\":" -v field="$field" '
        $0 == "versions:" { in_v=1; next }
        in_v && $0 ~ /^[^[:space:]]/ { in_v=0 }
        in_v && $0 ~ /^  "/ {
            if ($0 ~ ("^  " vkey "[[:space:]]*$")) { hit=1 } else { hit=0 }
            next
        }
        in_v && hit {
            tag = "    " field ":"
            if (index($0, tag) == 1) {
                v = substr($0, length(tag) + 1)
                sub(/^[[:space:]]+/, "", v)
                print v
                exit
            }
        }
    ' "$YAML" | unquote
}

# ---- resolve target version & matrix ----------------------------------------

[ -z "$VERSION" ] && VERSION="$(yaml_top latest)"
[ -n "$VERSION" ] || die_json "Could not resolve target version (no --version and no 'latest:' in YAML)"

UNITY_MIN=$(yaml_version_field "$VERSION" unity_min)
JAVA_MIN=$(yaml_version_field "$VERSION" java_min)
MAX_MIN=$(yaml_version_field "$VERSION" max_min)
API_MIN=$(yaml_version_field "$VERSION" android_api_min)
URL=$(yaml_version_field "$VERSION" download_url)

for pair in "unity_min:$UNITY_MIN" "java_min:$JAVA_MIN" "max_min:$MAX_MIN" "android_api_min:$API_MIN" "download_url:$URL"; do
    val="${pair#*:}"
    [ -n "$val" ] || die_json "Matrix incomplete for version $VERSION (missing ${pair%:*}). Reformat-tolerance: yaml_version_field requires the canonical 2/4-space indent."
done

# ---- detectors --------------------------------------------------------------

detect_unity() {
    local f="$PROJECT/ProjectSettings/ProjectVersion.txt"
    [ -f "$f" ] || return
    awk '/^m_EditorVersion:/ { print $2; exit }' "$f"
}

detect_java() {
    if [ -n "${MOCK_JAVA_VERSION:-}" ]; then echo "$MOCK_JAVA_VERSION"; return; fi
    command -v java >/dev/null 2>&1 || return
    java -version 2>&1 | head -1 | awk -F\" '/version/ { print $2; exit }'
}

# detect_max: search Assets/, Packages/, Library/PackageCache/, then UPM manifest
detect_max() {
    local f
    # 1. Legacy Asset Store layout
    f="$PROJECT/Assets/MaxSdk/Scripts/MaxSdk.cs"
    if [ -f "$f" ]; then
        grep -E 'private const string _version' "$f" | head -1 | awk -F\" '{ print $2 }'
        return
    fi
    # 2. UPM in-repo Packages/
    f=$(find "$PROJECT/Packages" -maxdepth 4 -type f -name MaxSdk.cs 2>/dev/null | head -1)
    if [ -n "$f" ] && [ -f "$f" ]; then
        grep -E 'private const string _version' "$f" | head -1 | awk -F\" '{ print $2 }'
        return
    fi
    # 3. UPM cache
    f=$(find "$PROJECT/Library/PackageCache" -maxdepth 4 -type f -name MaxSdk.cs 2>/dev/null | head -1)
    if [ -n "$f" ] && [ -f "$f" ]; then
        grep -E 'private const string _version' "$f" | head -1 | awk -F\" '{ print $2 }'
        return
    fi
    # 4. UPM manifest fallback (no version string available, only package version)
    local mf="$PROJECT/Packages/manifest.json"
    if [ -f "$mf" ] && grep -q 'com.applovin' "$mf"; then
        grep -E '"com\.applovin[^"]*"[[:space:]]*:[[:space:]]*"[^"]+"' "$mf" \
            | head -1 \
            | awk -F\" '{ print $4 }'
        return
    fi
}

detect_android_api() {
    local g="$PROJECT/Assets/Plugins/Android/mainTemplate.gradle"
    if [ -f "$g" ]; then
        # Skip Unity placeholders like **MINSDKVERSION**; only accept a bare integer.
        local v
        v=$(awk '/minSdkVersion[[:space:]]+[0-9]+|minSdk[[:space:]]+[0-9]+/ {
            for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) { print $i; exit }
        }' "$g")
        [ -n "$v" ] && { echo "$v"; return; }
    fi
    local s="$PROJECT/ProjectSettings/ProjectSettings.asset"
    [ -f "$s" ] && awk '/^[[:space:]]+AndroidMinSdkVersion:/ { print $2; exit }' "$s"
}

# detect_backend: scriptingBackend is multi-line YAML in Unity 2021.3+
#   scriptingBackend:
#     Android: 1     ← IL2CPP
#     Android: 0     ← Mono
# Empty map (`scriptingBackend: {}`) means "Unity default" → Mono on Android.
detect_backend() {
    local s="$PROJECT/ProjectSettings/ProjectSettings.asset"
    [ -f "$s" ] || return
    awk '
        /^[[:space:]]+scriptingBackend:[[:space:]]*$/ { in_b=1; next }
        in_b && /^[[:space:]]+Android:[[:space:]]+[0-9]+/ {
            v=$2
            if (v=="1") { print "IL2CPP"; exit }
            if (v=="0") { print "Mono";   exit }
        }
        in_b && /^  [a-zA-Z]/ && !/^[[:space:]]+Android:/ {
            # left the scriptingBackend block without finding an Android key
            in_b=0
        }
        /^[[:space:]]+scriptingBackend:[[:space:]]*\{\}[[:space:]]*$/ {
            print "Mono"; exit
        }
    ' "$s"
}

# Detect whether MeticaSDK is already imported. Returns the installed Version
# string (e.g. "2.4.0") or empty if not installed.
detect_metica() {
    local f="$PROJECT/Assets/MeticaSdk/Runtime/Sdk/MeticaSdk.cs"
    [ -f "$f" ] || return
    grep -E 'public static string Version' "$f" | head -1 | awk -F\" '{ print $2 }'
}

# gradle: deliberately not detected from gradleTemplate.properties (that file
# does not contain the Gradle version). Report UNKNOWN until we have a real source.
detect_gradle() { return; }

# ---- comparison helpers -----------------------------------------------------

ver_ge() {
    local a b
    a="$(printf '%s' "$1" | sed -E 's/[a-zA-Z].*$//')"
    b="$(printf '%s' "$2" | sed -E 's/[a-zA-Z].*$//')"
    [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -1)" = "$b" ]
}

int_ge() {
    # Tolerate strings like "21-ea", "21+35", "1.8.0_362" by taking leading integer.
    local x y
    x="$(printf '%s' "${1:-}" | sed -E 's/^([0-9]+).*$/\1/')"
    y="$(printf '%s' "${2:-}" | sed -E 's/^([0-9]+).*$/\1/')"
    case "$x" in ''|*[!0-9]*) return 1 ;; esac
    case "$y" in ''|*[!0-9]*) return 1 ;; esac
    [ "$x" -ge "$y" ]
}

# ---- evaluators: emit "<level>|<hint>" --------------------------------------

ev_unity() {
    [ -z "$UNITY" ] && { echo "UNKNOWN|Could not read ProjectVersion.txt"; return; }
    ver_ge "$UNITY" "$UNITY_MIN" && echo "PASS|" \
        || echo "FAIL|Install Unity $UNITY_MIN LTS via Unity Hub, then switch the project's editor version."
}

ev_java() {
    [ -z "$JAVA" ] && { echo "UNKNOWN|java not on PATH — install Adoptium Temurin $JAVA_MIN+ and ensure 'java' is on PATH."; return; }
    local m="${JAVA%%.*}"
    [ "$m" = "1" ] && m="$(echo "$JAVA" | awk -F. '{print $2}')"
    int_ge "$m" "$JAVA_MIN" && echo "PASS|" \
        || echo "FAIL|Install Adoptium Temurin $JAVA_MIN+ (or newer) and update JAVA_HOME / your PATH."
}

ev_max() {
    # MAX absence is policy-dependent; for SDK 2.4.0 absence is acceptable
    # (fresh-mode integration). When matrix gets a `max_required: true` field
    # we will distinguish here.
    [ -z "$MAX" ] && { echo "PASS|"; return; }
    ver_ge "$MAX" "$MAX_MIN" && echo "PASS|" \
        || echo "FAIL|Update AppLovin MAX to $MAX_MIN+ via Window > AppLovin > Integration Manager in Unity."
}

ev_api() {
    [ -z "$API" ] && { echo "UNKNOWN|Android minSdk not detected; using Unity built-in default"; return; }
    int_ge "$API" "$API_MIN" && echo "PASS|" \
        || echo "FAIL|Set AndroidMinSdkVersion: $API_MIN in ProjectSettings/ProjectSettings.asset, or Edit > Project Settings > Player > Android > Minimum API Level."
}

ev_gradle() {
    echo "UNKNOWN|Gradle version not read (no reliable source in current Unity project layout)"
}

ev_backend() {
    [ -z "$BACKEND" ] && { echo "UNKNOWN|Could not detect scripting backend"; return; }
    echo "PASS|"
}

ev_metica() {
    if [ -z "$METICA" ]; then
        echo "FAIL|Install MeticaSDK $VERSION: download $URL and double-click in Unity to import."
        return
    fi
    ver_ge "$METICA" "$VERSION" && echo "PASS|" \
        || echo "FAIL|MeticaSDK $METICA installed; need $VERSION or newer. Download $URL and re-import."
}

# ---- run detectors once -----------------------------------------------------

UNITY=$(detect_unity)
JAVA=$(detect_java)
MAX=$(detect_max)
API=$(detect_android_api)
GRADLE=$(detect_gradle)
BACKEND=$(detect_backend)
METICA=$(detect_metica)

R_UNITY=$(ev_unity)
R_JAVA=$(ev_java)
R_MAX=$(ev_max)
R_API=$(ev_api)
R_GRADLE=$(ev_gradle)
R_BACKEND=$(ev_backend)
R_METICA=$(ev_metica)

# ---- emit JSON --------------------------------------------------------------

STATUS="PASS"
for r in "$R_UNITY" "$R_JAVA" "$R_MAX" "$R_API" "$R_GRADLE" "$R_BACKEND" "$R_METICA"; do
    [ "${r%%|*}" = "FAIL" ] && STATUS="BLOCK"
done

emit_check() {
    # id detected required result
    # detected is nullable per contract; required and hint are always strings.
    local lvl="${4%%|*}" hint="${4#*|}"
    printf '    { "id": "%s", "detected": %s, "required": "%s", "level": "%s", "hint": "%s" }' \
        "$1" "$(jval "$2")" "$(json_escape "$3")" "$lvl" "$(json_escape "$hint")"
}

{
    printf '{\n'
    printf '  "schema": "compat-checker/1.0.0",\n'
    printf '  "status": "%s",\n' "$STATUS"
    printf '  "target_sdk": %s,\n' "$(jval "$VERSION")"
    printf '  "error": null,\n'
    printf '  "warnings": [],\n'
    printf '  "checks": [\n'
    emit_check "unity"             "$UNITY"   ">=$UNITY_MIN"   "$R_UNITY";   printf ',\n'
    emit_check "java"              "$JAVA"    ">=$JAVA_MIN"    "$R_JAVA";    printf ',\n'
    emit_check "max"               "$MAX"     ">=$MAX_MIN"     "$R_MAX";     printf ',\n'
    emit_check "android_api"       "$API"     ">=$API_MIN"     "$R_API";     printf ',\n'
    emit_check "gradle"            "$GRADLE"  ">=7.0"          "$R_GRADLE";  printf ',\n'
    emit_check "scripting_backend" "$BACKEND" "IL2CPP|Mono"    "$R_BACKEND"; printf ',\n'
    emit_check "metica_sdk"        "$METICA"  ">=$VERSION"     "$R_METICA"
    printf '\n  ]\n}\n'
}

[ "$STATUS" = "PASS" ] && exit 0 || exit 1
