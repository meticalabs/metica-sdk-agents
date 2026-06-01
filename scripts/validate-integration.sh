#!/bin/bash
# validate-integration.sh — verify a Unity project's MeticaSDK integration.
# Emits JSON per the validator/1.1.0 schema (see agents/contracts.md).
#
# Usage: validate-integration.sh --project=<path>
# Exit:  0 = PASS, 1 = FAIL, 2 = invocation/structural error (still JSON).
#
# Validation is uniform — it does not depend on whether MaxSDK is present.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PROJECT=""

# ---- JSON helpers -----------------------------------------------------------

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

die_json() {
    local msg="$1"
    printf '{\n'
    printf '  "schema": "validator/1.1.0",\n'
    printf '  "status": "FAIL",\n'
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
        -h|--help)
            sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) die_json "Unknown arg: $arg" ;;
    esac
done

[ -n "$PROJECT" ]            || die_json "Missing --project=<path>"
[ -d "$PROJECT" ]            || die_json "Project not found: $PROJECT"
[ -d "$PROJECT/Assets" ]     || die_json "Not a Unity project (no Assets/): $PROJECT"

WARNINGS=""

# ---- discover C# sources ---------------------------------------------------

CS_LIST="$(mktemp -t metica-cs-XXXXXX)"
trap 'rm -f "$CS_LIST"' EXIT
# Scan only USER game code. Exclude both vendored SDKs (MaxSdk, MeticaSdk) and
# Unity-managed dirs (PackageCache, Library, Temp, obj). The integrator-generated
# Assets/Scripts/Metica/ adapter folder IS user code and must remain in scope —
# it contains the legitimate MeticaSdk.Initialize call that init_count expects.
find "$PROJECT/Assets" "$PROJECT/Packages" -type f -name '*.cs' 2>/dev/null \
    | grep -v '/MaxSdk/' \
    | grep -v '/MeticaSdk/' \
    | grep -v '/PackageCache/' \
    | grep -v '/Library/' \
    | grep -v '/Temp/' \
    | grep -v '/obj/' \
    > "$CS_LIST"
[ -s "$CS_LIST" ] || die_json "No C# sources found under Assets/ or Packages/"

# ---- helpers (path-safe loops; strip strings + line/block comments) --------
# All matching is performed on cleaned C# lines so a pattern named inside a
# `// BUG: forgot Foo`, `/* commented out */`, or `"a string literal"` does
# not register as a real call. Line numbers are preserved (per-line cleanup).

# Cleaned source (strings — regular, verbatim, interpolated — plus line and
# block comments stripped; line numbers preserved) is read through the shared
# clean_source() accessor so the validator and the integrator's discovery scan
# byte-identical input (RFC v1.0 OQ4: the cleaned-source cache lands behind this
# seam later, with no caller changes). Self-test it before relying on it — a
# broken accessor must bail loudly, not silently return 0 matches everywhere
# (which would emit a misleading all-PASS report).
source "$SCRIPT_DIR/lib/clean-source.sh"
clean_source_selftest || die_json "clean-cs.awk failed self-test (awk error or syntax issue)"

files_with() {
    local pat="$1" c
    while IFS= read -r f; do
        # Count (don't short-circuit): a `grep -q` would close the pipe on the
        # first match and SIGPIPE the clean_source awk, which under `set -o
        # pipefail` makes the pipeline report failure and silently skips a
        # large file. `grep -cF` consumes the whole stream, so awk completes.
        c="$(clean_source "$f" | grep -cF -- "$pat" 2>/dev/null)" || c=0
        [ "${c:-0}" -gt 0 ] && printf '%s\n' "$f"
    done < "$CS_LIST"
}

count_lit() {
    local pat="$1" total=0 c
    while IFS= read -r f; do
        c="$(clean_source "$f" | grep -cF -- "$pat" 2>/dev/null)" || c=0
        total=$((total + c))
    done < "$CS_LIST"
    printf '%d' "$total"
}

first_loc() {
    local pat="$1" n
    while IFS= read -r f; do
        n="$(clean_source "$f" | grep -nF -- "$pat" | head -1 | awk -F: '{ print $1 }')"
        if [ -n "$n" ]; then
            printf '%s:%s' "$f" "$n"
            return
        fi
    done < "$CS_LIST"
}

# Regex-aware variants (ERE) of count_lit/first_loc — used by the reference-form
# checks (mediation enum qualification, SmartFloors property casing) where a
# fixed-string match isn't enough.
#
# These read COMMENT-stripped source (strings preserved) via strip-comments.awk,
# NOT clean_source. The reason is the SmartFloors access lives inside an
# interpolated string — `$"...{response.SmartFloors.IsForcedHoldout}..."` — and
# clean-cs.awk strips interpolated strings whole (interpolation holes included),
# which would hide the reference entirely. strip-comments.awk keeps string
# contents (so the interpolation hole survives) while still dropping comments, so
# a commented-out example can't false-positive. Same count-don't-short-circuit
# discipline as the literal helpers above.
__STRIP_COMMENTS_AWK="$SCRIPT_DIR/lib/strip-comments.awk"
strip_comments_source() { awk -f "$__STRIP_COMMENTS_AWK" "$1"; }

count_re() {
    local pat="$1" total=0 c
    while IFS= read -r f; do
        c="$(strip_comments_source "$f" | grep -cE -- "$pat" 2>/dev/null)" || c=0
        total=$((total + c))
    done < "$CS_LIST"
    printf '%d' "$total"
}

# first_re <pattern> [exclude_pattern]: first <file>:<line> matching <pattern>,
# skipping lines that ALSO match <exclude_pattern> (e.g. the already-qualified form).
first_re() {
    local pat="$1" exclude="${2:-}" n
    while IFS= read -r f; do
        if [ -n "$exclude" ]; then
            n="$(strip_comments_source "$f" | grep -nE -- "$pat" | grep -vE -- "$exclude" | head -1 | awk -F: '{ print $1 }')"
        else
            n="$(strip_comments_source "$f" | grep -nE -- "$pat" | head -1 | awk -F: '{ print $1 }')"
        fi
        if [ -n "$n" ]; then
            printf '%s:%s' "$f" "$n"
            return
        fi
    done < "$CS_LIST"
}

line_in_file() {
    clean_source "$2" | grep -nF -- "$1" | head -1 | awk -F: '{ print $1 }'
}

# ---- MeticaSDK presence guard ----------------------------------------------

# Refuse to validate if there are no MeticaSdk references at all — this is not
# a Metica integration, just a Unity project. Emit a contract-shaped error.
HAS_METICA=0; [ "$(count_lit 'MeticaSdk.')" != "0" ] && HAS_METICA=1
if [ "$HAS_METICA" = "0" ]; then
    die_json "No MeticaSdk references found; project does not appear to have a MeticaSDK integration."
fi

# ---- check accumulator -----------------------------------------------------

CHECKS=""
add_check() {
    # rule location level detail
    # Build with a real newline separator (not the literal "\n" + printf %b)
    # because %b interprets backslashes and breaks JSON when a field contains
    # an odd number of '\' chars (Windows paths, user-id values with escapes).
    local sep=""
    [ -n "$CHECKS" ] && sep=$',\n'
    CHECKS="$CHECKS$sep    { \"rule\": \"$1\", \"location\": \"$(json_escape "$2")\", \"level\": \"$3\", \"detail\": \"$(json_escape "$4")\" }"
}

# ---- rules ------------------------------------------------------------------

# 1. init_count: exactly one MeticaSdk.Initialize(
INIT_COUNT="$(count_lit 'MeticaSdk.Initialize(')"
INIT_LOC="$(first_loc 'MeticaSdk.Initialize(')"
case "$INIT_COUNT" in
    1) add_check "init_count" "$INIT_LOC" "PASS" "MeticaSdk.Initialize called exactly once." ;;
    0) add_check "init_count" ""          "FAIL" "MeticaSdk.Initialize(...) not found." ;;
    *) add_check "init_count" "$INIT_LOC" "FAIL" "MeticaSdk.Initialize called $INIT_COUNT times; expected exactly 1." ;;
esac

# 2. privacy_before_init: validate same-file ordering of privacy calls before
# Initialize (the rule is uniform regardless of whether MaxSDK is present).
INIT_FILE="${INIT_LOC%:*}"
if [ -n "$INIT_FILE" ]; then
    INIT_LINE="$(line_in_file 'MeticaSdk.Initialize(' "$INIT_FILE")"
    # Privacy calls may be in same file or another; check both files-set + line order when in-file.
    CONSENT_FILES="$(files_with 'SetHasUserConsent(')"
    DNS_FILES="$(files_with 'SetDoNotSell(')"

    if [ -z "$CONSENT_FILES" ]; then
        add_check "privacy_before_init" "" "FAIL" "SetHasUserConsent(...) not called."
    elif [ -z "$DNS_FILES" ]; then
        add_check "privacy_before_init" "" "FAIL" "SetDoNotSell(...) not called."
    else
        CONSENT_LINE="$(line_in_file 'SetHasUserConsent(' "$INIT_FILE")"
        DNS_LINE="$(line_in_file 'SetDoNotSell(' "$INIT_FILE")"
        if [ -z "$CONSENT_LINE" ] || [ -z "$DNS_LINE" ]; then
            # Privacy calls live in a different file from Initialize. Ordering
            # is undefined at runtime — fail with a clear hint.
            add_check "privacy_before_init" "$INIT_FILE:$INIT_LINE" "FAIL" \
                "Privacy calls (SetHasUserConsent/SetDoNotSell) must be in the same file as MeticaSdk.Initialize so line order is enforceable."
        else
            bad=0
            [ "$CONSENT_LINE" -ge "$INIT_LINE" ] && bad=1
            [ "$DNS_LINE"     -ge "$INIT_LINE" ] && bad=1
            if [ "$bad" = "1" ]; then
                add_check "privacy_before_init" "$INIT_FILE:$INIT_LINE" "FAIL" \
                    "Privacy call must precede MeticaSdk.Initialize (line ordering in $INIT_FILE)."
            else
                add_check "privacy_before_init" "$INIT_FILE:$INIT_LINE" "PASS" \
                    "SetHasUserConsent and SetDoNotSell called before Initialize."
            fi
        fi
    fi
fi

# Per-format check helper.
# Inputs: format, load_pattern, error_callback_pattern, success_callback_pattern
check_format_callbacks() {
    local fmt="$1" load_pat="$2" err_pat="$3" load_cb_pat="$4"
    local rule="${fmt}_callbacks_subscribed"
    local load_count; load_count="$(count_lit "$load_pat")"
    if [ "$load_count" = "0" ]; then
        add_check "$rule" "" "PASS" "$fmt ads not used; nothing to verify."
        return
    fi
    local err_count load_cb_count
    err_count="$(count_lit "$err_pat")"
    load_cb_count="$(count_lit "$load_cb_pat")"
    if [ "$err_count" = "0" ]; then
        add_check "$rule" "" "FAIL" "$fmt: $err_pat not subscribed."
    elif [ "$load_cb_count" = "0" ]; then
        add_check "$rule" "" "FAIL" "$fmt: $load_cb_pat not subscribed."
    else
        add_check "$rule" "" "PASS" "$fmt load + error callbacks subscribed."
    fi
}

# 3. banner_callbacks_subscribed
check_format_callbacks "banner" \
    "MeticaSdk.Ads.LoadBanner(" \
    "MeticaAdsCallbacks.Banner.OnAdLoadFailed" \
    "MeticaAdsCallbacks.Banner.OnAdLoadSuccess"

# 4. interstitial_callbacks_subscribed
check_format_callbacks "interstitial" \
    "MeticaSdk.Ads.LoadInterstitial(" \
    "MeticaAdsCallbacks.Interstitial.OnAdLoadFailed" \
    "MeticaAdsCallbacks.Interstitial.OnAdLoadSuccess"

# 5. rewarded_callbacks_subscribed
check_format_callbacks "rewarded" \
    "MeticaSdk.Ads.LoadRewarded(" \
    "MeticaAdsCallbacks.Rewarded.OnAdLoadFailed" \
    "MeticaAdsCallbacks.Rewarded.OnAdLoadSuccess"

# 5b. mrec_callbacks_subscribed — MRec is a persistent format like banner.
# Note: MeticaSDK casing is `Mrec` (lowercase r), not `MRec`.
check_format_callbacks "mrec" \
    "MeticaSdk.Ads.LoadMrec(" \
    "MeticaAdsCallbacks.Mrec.OnAdLoadFailed" \
    "MeticaAdsCallbacks.Mrec.OnAdLoadSuccess"

# 6. rewarded_reward_callback (conditional FAIL): if Rewarded used, OnAdRewarded subscribed
REWARDED_LOAD_COUNT="$(count_lit 'MeticaSdk.Ads.LoadRewarded(')"
if [ "$REWARDED_LOAD_COUNT" != "0" ]; then
    REWARDED_CB_COUNT="$(count_lit 'MeticaAdsCallbacks.Rewarded.OnAdRewarded')"
    if [ "$REWARDED_CB_COUNT" = "0" ]; then
        add_check "rewarded_reward_callback" "" "FAIL" "Rewarded ads used but OnAdRewarded not subscribed."
    else
        add_check "rewarded_reward_callback" "" "PASS" "Rewarded reward callback subscribed."
    fi
fi

# 7. load_show_parity: per format, if Load exists then Show exists somewhere
check_load_show_parity() {
    local fmt="$1" load_pat="$2" show_pat="$3"
    local rule="${fmt}_load_show_parity"
    local lc sc
    lc="$(count_lit "$load_pat")"
    sc="$(count_lit "$show_pat")"
    if [ "$lc" = "0" ]; then return; fi
    if [ "$sc" = "0" ]; then
        add_check "$rule" "" "FAIL" "$fmt: $load_pat exists but no $show_pat in project."
    else
        add_check "$rule" "" "PASS" "$fmt: load and show calls both present."
    fi
}
check_load_show_parity "banner"       "MeticaSdk.Ads.LoadBanner("       "MeticaSdk.Ads.ShowBanner("
check_load_show_parity "interstitial" "MeticaSdk.Ads.LoadInterstitial(" "MeticaSdk.Ads.ShowInterstitial("
check_load_show_parity "rewarded"     "MeticaSdk.Ads.LoadRewarded("     "MeticaSdk.Ads.ShowRewarded("
check_load_show_parity "mrec"         "MeticaSdk.Ads.LoadMrec("         "MeticaSdk.Ads.ShowMrec("

# 7b. reload_on_hidden: interstitial/rewarded must subscribe OnAdHidden so the
# next ad is loaded when the current one is dismissed (the canonical show →
# hidden → reload loop). Banners are persistent and are excluded.
check_reload_on_hidden() {
    local fmt="$1" load_pat="$2" hidden_pat="$3"
    local rule="${fmt}_reload_on_hidden"
    [ "$(count_lit "$load_pat")" = "0" ] && return
    if [ "$(count_lit "$hidden_pat")" = "0" ]; then
        add_check "$rule" "" "FAIL" "$fmt used but $hidden_pat not subscribed; load the next ad from the hidden callback (auto-reload)."
    else
        add_check "$rule" "" "PASS" "$fmt auto-reload-on-hidden callback subscribed."
    fi
}
check_reload_on_hidden "interstitial" "MeticaSdk.Ads.LoadInterstitial(" "MeticaAdsCallbacks.Interstitial.OnAdHidden"
check_reload_on_hidden "rewarded"     "MeticaSdk.Ads.LoadRewarded("     "MeticaAdsCallbacks.Rewarded.OnAdHidden"

# 7b2. show_failed_subscribed: interstitial/rewarded must subscribe OnAdShowFailed
# so the reload loop survives a failed-to-display ad. OnAdHidden does NOT fire on
# show-failure, so the reload-on-hidden loop alone is incomplete — without this
# subscription, the next ad never loads after a single show-failure (network
# blip, expired ad, mediated SDK failure). Per the docs.metica.com Unity SDK
# example, both Interstitial and Rewarded subscribe OnAdShowFailed.
check_show_failed_subscribed() {
    local fmt="$1" load_pat="$2" show_failed_pat="$3"
    local rule="${fmt}_show_failed_subscribed"
    [ "$(count_lit "$load_pat")" = "0" ] && return
    if [ "$(count_lit "$show_failed_pat")" = "0" ]; then
        add_check "$rule" "" "FAIL" "$fmt used but $show_failed_pat not subscribed; show-failure does not fire OnAdHidden, so the reload loop stalls. Subscribe and reload from this handler."
    else
        add_check "$rule" "" "PASS" "$fmt OnAdShowFailed subscribed."
    fi
}
check_show_failed_subscribed "interstitial" "MeticaSdk.Ads.LoadInterstitial(" "MeticaAdsCallbacks.Interstitial.OnAdShowFailed"
check_show_failed_subscribed "rewarded"     "MeticaSdk.Ads.LoadRewarded("     "MeticaAdsCallbacks.Rewarded.OnAdShowFailed"

# 7c. show_ready_guard (ADVISORY): when an interstitial/rewarded Show is called,
# an IsReady check should exist so Show() never fires on a not-loaded ad.
check_ready_guard() {
    local fmt="$1" show_pat="$2" ready_pat="$3"
    local rule="${fmt}_show_ready_guard"
    [ "$(count_lit "$show_pat")" = "0" ] && return
    if [ "$(count_lit "$ready_pat")" = "0" ]; then
        add_check "$rule" "" "ADVISORY" "$fmt Show called but $ready_pat never used; guard Show() with the ready check."
    else
        add_check "$rule" "" "PASS" "$fmt Show is guarded by a ready check."
    fi
}
check_ready_guard "interstitial" "MeticaSdk.Ads.ShowInterstitial(" "MeticaSdk.Ads.IsInterstitialReady("
check_ready_guard "rewarded"     "MeticaSdk.Ads.ShowRewarded("     "MeticaSdk.Ads.IsRewardedReady("

# 8. revenue_callback_subscribed (ADVISORY)
REV_COUNT="$(count_lit 'OnAdRevenuePaid')"
if [ "$REV_COUNT" = "0" ]; then
    add_check "revenue_callback_subscribed" "" "ADVISORY" "OnAdRevenuePaid not subscribed; attribution will be incomplete."
else
    add_check "revenue_callback_subscribed" "" "PASS" "Revenue callback subscribed."
fi

# 9. placeholder_ids_replaced — fail if YOUR_*/REPLACE_ME placeholders appear as
# STRING LITERAL VALUES in source. Comments are stripped via strip-comments.awk
# so commented-out examples don't false-positive. The pattern requires the
# placeholder to be enclosed in `"..."` so a user constant named
# `YOUR_METICA_API_KEY` holding a real key is not flagged.
STRIP_COMMENTS_AWK="$SCRIPT_DIR/lib/strip-comments.awk"
[ -f "$STRIP_COMMENTS_AWK" ]                          || die_json "Missing helper: $STRIP_COMMENTS_AWK"
awk -f "$STRIP_COMMENTS_AWK" /dev/null >/dev/null 2>&1 || die_json "strip-comments.awk failed self-test (awk error or syntax issue)"

PLACEHOLDER_PATTERN='"(YOUR_METICA_API_KEY|YOUR_METICA_APP_ID|YOUR_MAX_SDK_KEY|REPLACE_ME)"'
PLACEHOLDER_HITS=""
while IFS= read -r f; do
    hit="$(awk -f "$STRIP_COMMENTS_AWK" "$f" 2>/dev/null \
            | grep -nE "$PLACEHOLDER_PATTERN" \
            | head -1 \
            | awk -F: '{ print $1 }')"
    if [ -n "$hit" ]; then
        PLACEHOLDER_HITS="$f:$hit"
        break
    fi
done < "$CS_LIST"
if [ -n "$PLACEHOLDER_HITS" ]; then
    add_check "placeholder_ids_replaced" "$PLACEHOLDER_HITS" "FAIL" \
        "Placeholder credential leaked into source (YOUR_* / REPLACE_ME). Replace with real values before shipping."
else
    add_check "placeholder_ids_replaced" "" "PASS" "No YOUR_*/REPLACE_ME placeholders found."
fi

# 10. user_id_not_test_value — fail if the userId arg passed to
# MeticaInitConfig(api, app, userId) is null, empty string, or a test/debug/
# dummy/placeholder literal, or a digits-only string. Handles multi-line
# constructor calls via the awk parser. Object-initializer form
# (`new MeticaInitConfig { UserId = … }`) is NOT covered — the integrator
# emits the positional form; if it ever switches, extend check-init-userid.awk.
USERID_CHECK_AWK="$SCRIPT_DIR/lib/check-init-userid.awk"
# Same self-test pattern as clean-cs.awk / strip-comments.awk above. Without
# this, a missing/broken check-init-userid.awk silently makes USERID_HITS empty
# (errors are redirected to /dev/null in the pipeline below) and the rule
# falsely reports `user_id_not_test_value:PASS` on every project.
[ -f "$USERID_CHECK_AWK" ]                                       || die_json "Missing helper: $USERID_CHECK_AWK"
awk -v FNAME=/dev/null -f "$USERID_CHECK_AWK" </dev/null >/dev/null 2>&1 \
                                                                 || die_json "check-init-userid.awk failed self-test (awk error or syntax issue)"
USERID_HITS=""
while IFS= read -r f; do
    # Run the file through strip-comments first, then through the userId checker.
    out="$(awk -f "$STRIP_COMMENTS_AWK" "$f" 2>/dev/null \
            | awk -v FNAME="$f" -f "$USERID_CHECK_AWK" 2>/dev/null)"
    if [ -n "$out" ]; then
        USERID_HITS="$out"
        break
    fi
done < "$CS_LIST"
if [ -n "$USERID_HITS" ]; then
    # USERID_HITS format: <file>\t<line>\t<reason>\t<value>  (tab-delimited so file
    # paths containing ':' don't corrupt parsing).
    IFS=$'\t' read -r HIT_FILE HIT_LINE HIT_REASON HIT_VALUE <<< "$(printf '%s' "$USERID_HITS" | head -1)"
    add_check "user_id_not_test_value" "$HIT_FILE:$HIT_LINE" "FAIL" \
        "MeticaInitConfig userId argument is a $HIT_REASON value ($HIT_VALUE). Replace with your real user-identity source before shipping."
else
    add_check "user_id_not_test_value" "" "PASS" "MeticaInitConfig userId looks non-test."
fi

# 11. mediation_enum_qualified — MeticaMediationType is a NESTED enum inside
# MeticaMediationInfo, so it must be written `MeticaMediationInfo.MeticaMediationType.MAX`.
# The docs.metica.com Unity SDK example uses the bare `MeticaMediationType.MAX`, which
# does NOT compile (CS0103). Detect any bare reference not already qualified by
# `MeticaMediationInfo.`. Skipped when no mediation enum is referenced (no-Max projects).
MED_TOTAL="$(count_re 'MeticaMediationType\.')"
if [ "$MED_TOTAL" != "0" ]; then
    MED_QUALIFIED="$(count_re 'MeticaMediationInfo\.MeticaMediationType\.')"
    if [ "$MED_TOTAL" -gt "$MED_QUALIFIED" ]; then
        MED_LOC="$(first_re 'MeticaMediationType\.' 'MeticaMediationInfo\.MeticaMediationType\.')"
        add_check "mediation_enum_qualified" "$MED_LOC" "FAIL" \
            "Bare MeticaMediationType.MAX does not compile (CS0103) — it is a nested enum. Qualify it: MeticaMediationInfo.MeticaMediationType.MAX."
    else
        add_check "mediation_enum_qualified" "$(first_re 'MeticaMediationInfo\.MeticaMediationType\.')" "PASS" \
            "Mediation enum is correctly qualified (MeticaMediationInfo.MeticaMediationType.*)."
    fi
fi

# 12. smartfloors_property_case — MeticaSmartFloors.IsForcedHoldout is PascalCase.
# The docs.metica.com example uses camelCase `isForcedHoldout`, which does NOT
# compile (CS1061). Detect the camelCase form. Skipped when SmartFloors is not referenced.
if [ "$(count_re 'SmartFloors\.')" != "0" ]; then
    if [ "$(count_re 'SmartFloors\.isForcedHoldout')" != "0" ]; then
        add_check "smartfloors_property_case" "$(first_re 'SmartFloors\.isForcedHoldout')" "FAIL" \
            "SmartFloors.isForcedHoldout does not compile (CS1061) — the property is PascalCase. Use SmartFloors.IsForcedHoldout."
    else
        add_check "smartfloors_property_case" "$(first_re 'SmartFloors\.')" "PASS" \
            "SmartFloors property access uses correct PascalCase casing."
    fi
fi

# DEFERRED to a future patch (known validator gaps):
#   - mediation_info_passed:        Initialize call must pass MeticaMediationInfo(MAX, sdkKey), not null
#   - compiles_cleanly:             invoke Unity batch-mode (or csc/dotnet) against the adapter folder +
#                                   SDK and surface real CS errors. Heavy + environment-dependent; the
#                                   string-level reference checks above (mediation_enum_qualified,
#                                   smartfloors_property_case) catch the known docs-transcription bugs
#                                   without a toolchain.
#   - load_while_showing (WARN):    flag LoadInterstitial/LoadRewarded invoked while an ad of the same
#                                   format is still showing. Needs call-graph/scope awareness to detect
#                                   without false positives; deferred until a reliable heuristic exists.
#   - banner_create_before_load:    CreateBanner precedes LoadBanner/ShowBanner

# ---- determine status ------------------------------------------------------

STATUS="PASS"
# any FAIL → FAIL
if printf '%s' "$CHECKS" | grep -q '"level": "FAIL"'; then STATUS="FAIL"; fi

# ---- emit JSON --------------------------------------------------------------

printf '{\n'
printf '  "schema": "validator/1.1.0",\n'
printf '  "status": "%s",\n' "$STATUS"
printf '  "error": null,\n'
printf '  "warnings": [%s],\n' "$WARNINGS"
printf '  "checks": [\n'
printf '%s' "$CHECKS"
printf '\n  ]\n}\n'

[ "$STATUS" = "PASS" ] && exit 0 || exit 1
