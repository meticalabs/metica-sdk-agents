#!/bin/bash
# scan-max-callsites.sh — find all MaxSdk usages in user game code that need
# to be rerouted through IAdService after side-by-side codegen.
#
# Excludes Assets/MaxSdk/ (the MaxSDK plugin itself), Assets/MeticaSdk/, and the
# generated Assets/Scripts/Metica/ adapter folder.
#
# Categories:
#   - bootstrap            SetSdkKey / InitializeSdk / SetHasUserConsent / SetDoNotSell
#   - method_call          Load* / Show* / Hide* / Destroy* / Create* / Is*Ready
#   - callback_subscription   MaxSdkCallbacks.<Format>.OnAd*Event += ...
#   - other                anything else under MaxSdk.* / MaxSdkCallbacks.*
#
# Usage: scan-max-callsites.sh --project=<path>
# Output: JSON per max-callsite-scan/1.0.0 schema (see agents/contracts.md).

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEAN_CS_AWK="$SCRIPT_DIR/lib/clean-cs.awk"

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
[ -d "$PROJECT/Assets" ] || { echo "Not a Unity project: $PROJECT" >&2; exit 1; }

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

classify() {
    case "$1" in
        *MaxSdkCallbacks.*) echo "callback_subscription" ;;
        *MaxSdk.SetSdkKey*|*MaxSdk.InitializeSdk*|*MaxSdk.SetHasUserConsent*|*MaxSdk.SetDoNotSell*)
            echo "bootstrap" ;;
        *MaxSdk.LoadInterstitial*|*MaxSdk.LoadBanner*|*MaxSdk.LoadRewardedAd*|\
        *MaxSdk.ShowInterstitial*|*MaxSdk.ShowBanner*|*MaxSdk.ShowRewardedAd*|\
        *MaxSdk.HideBanner*|*MaxSdk.DestroyBanner*|*MaxSdk.CreateBanner*|\
        *MaxSdk.IsInterstitialReady*|*MaxSdk.IsRewardedAdReady*)
            echo "method_call" ;;
        *MaxSdk.*) echo "other" ;;
        *) echo "" ;;
    esac
}

CS_LIST="$(mktemp -t maxscan-XXXXXX)"
trap 'rm -f "$CS_LIST"' EXIT
find "$PROJECT/Assets" "$PROJECT/Packages" -type f -name '*.cs' 2>/dev/null \
    | grep -v '/MaxSdk/' \
    | grep -v '/PackageCache/' \
    | grep -v '/Library/' \
    | grep -v '/Temp/' \
    | grep -v '/obj/' \
    | grep -v '/MeticaSdk/' \
    | grep -v '/Assets/Scripts/Metica/' \
    > "$CS_LIST"

RECORDS=""
add_record() {
    # file line category snippet
    local sep=""
    [ -n "$RECORDS" ] && sep=",\n"
    RECORDS="$RECORDS$sep    { \"file\": \"$(json_escape "$1")\", \"line\": $2, \"category\": \"$3\", \"snippet\": \"$(json_escape "$4")\" }"
}

while IFS= read -r f; do
    [ -z "$f" ] && continue
    rel="${f#$PROJECT/}"
    while IFS=: read -r line_no content; do
        [ -z "$content" ] && continue
        cat=$(classify "$content")
        [ -z "$cat" ] && continue
        # Trim leading whitespace from snippet for readability.
        snippet="$(printf '%s' "$content" | sed 's/^[[:space:]]*//')"
        add_record "$rel" "$line_no" "$cat" "$snippet"
    done < <(awk -f "$CLEAN_CS_AWK" "$f" | grep -nE 'MaxSdk\.|MaxSdkCallbacks\.')
done < "$CS_LIST"

printf '{\n'
printf '  "schema": "max-callsite-scan/1.0.0",\n'
printf '  "project": "%s",\n' "$(json_escape "$PROJECT")"
printf '  "callsites": [\n'
printf '%b' "$RECORDS"
printf '\n  ]\n}\n'
