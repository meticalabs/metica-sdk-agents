#!/bin/bash
# validate-integration.sh — verify a Unity project's MeticaSDK integration.
# Emits JSON per the validator/1.1.0 schema (see agents/contracts.md).
#
# Usage: validate-integration.sh --project=<path> [--mode=fresh|straight-swap|side-by-side]
# Exit:  0 = PASS, 1 = FAIL, 2 = invocation/structural error (still JSON).

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PROJECT=""
MODE=""

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
    printf '  "mode": "unknown",\n'
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
        --mode=*)    MODE="${arg#*=}" ;;
        -h|--help)
            sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) die_json "Unknown arg: $arg" ;;
    esac
done

[ -n "$PROJECT" ]            || die_json "Missing --project=<path>"
[ -d "$PROJECT" ]            || die_json "Project not found: $PROJECT"
[ -d "$PROJECT/Assets" ]     || die_json "Not a Unity project (no Assets/): $PROJECT"

case "$MODE" in
    ""|fresh|straight-swap|side-by-side) ;;
    *) die_json "Invalid --mode: $MODE (allowed: fresh, straight-swap, side-by-side)" ;;
esac

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

# Emit cleaned source for one file: strings (regular, verbatim, interpolated),
# line comments, block comments stripped. Line numbers preserved.
CLEAN_CS_AWK="$SCRIPT_DIR/lib/clean-cs.awk"
clean_cs() { awk -f "$CLEAN_CS_AWK" "$1"; }

files_with() {
    local pat="$1"
    while IFS= read -r f; do
        if clean_cs "$f" | grep -qF -- "$pat"; then
            printf '%s\n' "$f"
        fi
    done < "$CS_LIST"
}

count_lit() {
    local pat="$1" total=0 c
    while IFS= read -r f; do
        c="$(clean_cs "$f" | grep -cF -- "$pat" 2>/dev/null)" || c=0
        total=$((total + c))
    done < "$CS_LIST"
    printf '%d' "$total"
}

first_loc() {
    local pat="$1" n
    while IFS= read -r f; do
        n="$(clean_cs "$f" | grep -nF -- "$pat" | head -1 | awk -F: '{ print $1 }')"
        if [ -n "$n" ]; then
            printf '%s:%s' "$f" "$n"
            return
        fi
    done < "$CS_LIST"
}

line_in_file() {
    clean_cs "$2" | grep -nF -- "$1" | head -1 | awk -F: '{ print $1 }'
}

# ---- RAW helpers (no string/comment stripping) -----------------------------
# A few checks must inspect literal string values (placeholder keys, the userId
# argument). clean-cs.awk blanks string literals, so the cleaned helpers above
# can't see them — these scan the raw source instead.

raw_count() {
    local pat="$1" total=0 c
    while IFS= read -r f; do
        c="$(grep -cF -- "$pat" "$f" 2>/dev/null)" || c=0
        total=$((total + c))
    done < "$CS_LIST"
    printf '%d' "$total"
}

raw_first_loc() {
    local pat="$1" n
    while IFS= read -r f; do
        n="$(grep -nF -- "$pat" "$f" 2>/dev/null | head -1 | awk -F: '{ print $1 }')"
        if [ -n "$n" ]; then
            printf '%s:%s' "$f" "$n"
            return
        fi
    done < "$CS_LIST"
}

# Print the userId (3rd) argument of the first `new MeticaInitConfig(...)` across
# all sources, string-/multi-line-aware (see scripts/lib/extract-init-arg.awk).
EXTRACT_ARG_AWK="$SCRIPT_DIR/lib/extract-init-arg.awk"
extract_init_userid() {
    local f
    while IFS= read -r f; do
        if grep -qF -- 'new MeticaInitConfig(' "$f" 2>/dev/null; then
            awk -v WANT=3 -f "$EXTRACT_ARG_AWK" "$f"
            return
        fi
    done < "$CS_LIST"
}

# ---- mode detection ---------------------------------------------------------

HAS_MAX=0;    [ "$(count_lit 'MaxSdk.')"   != "0" ] && HAS_MAX=1
HAS_METICA=0; [ "$(count_lit 'MeticaSdk.')" != "0" ] && HAS_METICA=1
HAS_ROUTER=0; [ "$(count_lit 'AdServiceRouter')" != "0" ] && HAS_ROUTER=1

# Refuse to validate if there are no MeticaSdk references at all — this is not
# a Metica integration, just a Unity project. Emit a contract-shaped error.
if [ "$HAS_METICA" = "0" ]; then
    die_json "No MeticaSdk references found; project does not appear to have a MeticaSDK integration."
fi

if [ -z "$MODE" ]; then
    if [ "$HAS_ROUTER" = "1" ] || { [ "$HAS_MAX" = "1" ] && [ "$HAS_METICA" = "1" ]; }; then
        MODE="side-by-side"
    elif [ "$HAS_METICA" = "1" ]; then
        MODE="fresh"
    else
        MODE="unknown"
    fi
fi

# ---- check accumulator -----------------------------------------------------

CHECKS=""
add_check() {
    # rule location level detail
    local sep=""
    [ -n "$CHECKS" ] && sep=",\n"
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

# 2. privacy_before_init:
#    - In FRESH mode: validate same-file ordering of privacy calls before Initialize.
#    - In SIDE-BY-SIDE mode: find bootstrap files (those that reference
#      AdServiceRouter.Instance AND call .Initialize()) and verify line-ordering
#      of .SetHasUserConsent + .SetDoNotSell before .Initialize. If no bootstrap
#      file exists yet, ADVISORY (codegen just landed; user hasn't written the
#      bootstrap call sites).
INIT_FILE="${INIT_LOC%:*}"
if [ "$MODE" = "side-by-side" ]; then
    # Files using the router instance — these are bootstrap-style callsites.
    ROUTER_FILES=$(files_with 'AdServiceRouter.Instance')
    BOOTSTRAP_HIT=""
    BOOTSTRAP_BAD=""
    BOOTSTRAP_BAD_REASON=""
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        # Bootstrap = file with both AdServiceRouter.Instance and a .Initialize( call.
        if ! clean_cs "$f" | grep -qF -- '.Initialize('; then continue; fi
        BOOTSTRAP_HIT=1
        init_l=$(clean_cs "$f" | grep -nF -- '.Initialize(' | head -1 | awk -F: '{print $1}')
        consent_l=$(clean_cs "$f" | grep -nF -- '.SetHasUserConsent(' | head -1 | awk -F: '{print $1}')
        dns_l=$(clean_cs "$f" | grep -nF -- '.SetDoNotSell(' | head -1 | awk -F: '{print $1}')
        if [ -z "$consent_l" ] || [ -z "$dns_l" ]; then
            BOOTSTRAP_BAD="$f"
            BOOTSTRAP_BAD_REASON="missing SetHasUserConsent or SetDoNotSell"
            break
        fi
        if [ "$consent_l" -ge "$init_l" ] || [ "$dns_l" -ge "$init_l" ]; then
            BOOTSTRAP_BAD="$f"
            BOOTSTRAP_BAD_REASON="SetHasUserConsent/SetDoNotSell must precede .Initialize"
            break
        fi
    done <<< "$ROUTER_FILES"

    if [ -z "$BOOTSTRAP_HIT" ]; then
        add_check "privacy_before_init" "" "ADVISORY" \
            "No bootstrap file found yet (AdServiceRouter.Instance + .Initialize). When you write the bootstrap, call SetHasUserConsent and SetDoNotSell before Initialize."
    elif [ -n "$BOOTSTRAP_BAD" ]; then
        add_check "privacy_before_init" "$BOOTSTRAP_BAD" "FAIL" \
            "Side-by-side bootstrap: $BOOTSTRAP_BAD_REASON."
    else
        add_check "privacy_before_init" "" "PASS" \
            "Side-by-side bootstrap: privacy calls precede .Initialize."
    fi
elif [ -n "$INIT_FILE" ]; then
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

# 9. placeholder_ids_replaced (FAIL): the integrator emits YOUR_* placeholders
# when keys are not supplied. A shippable integration must replace them. Scanned
# on RAW source — the literals live inside string arguments that clean-cs blanks.
PLACEHOLDERS_FOUND=""
for ph in YOUR_METICA_API_KEY YOUR_METICA_APP_ID YOUR_MAX_SDK_KEY; do
    [ "$(raw_count "$ph")" != "0" ] && PLACEHOLDERS_FOUND="$PLACEHOLDERS_FOUND $ph"
done
if [ -n "$PLACEHOLDERS_FOUND" ]; then
    PH_FIRST="${PLACEHOLDERS_FOUND#" "}"; PH_FIRST="${PH_FIRST%% *}"
    add_check "placeholder_ids_replaced" "$(raw_first_loc "$PH_FIRST")" "FAIL" \
        "Unreplaced placeholder credential(s):${PLACEHOLDERS_FOUND}. Replace with real keys before shipping."
else
    add_check "placeholder_ids_replaced" "" "PASS" "No placeholder credential markers found."
fi

# 10. user_id_not_test (FAIL): the 3rd arg of new MeticaInitConfig(apiKey, appId,
# userId) must not be a hardcoded test literal. null/unset and variable
# expressions are acceptable (the value comes from the host app's identity). Only
# a literal test value fails. The arg is extracted from RAW source with a
# string-/multi-line-aware parser so commas inside string args and a constructor
# spanning multiple lines are handled.
if [ "$(raw_count 'new MeticaInitConfig(')" != "0" ]; then
    UID_ARG="$(extract_init_userid)"
    case "$UID_ARG" in @\"*) UID_ARG="${UID_ARG#@}" ;; esac   # verbatim @"…" → treat as string literal
    case "$UID_ARG" in
        ""|null)
            add_check "user_id_not_test" "" "PASS" "User ID is null/unset (acceptable; resolved from host identity)." ;;
        \"*\")
            UID_VAL="${UID_ARG%\"}"; UID_VAL="${UID_VAL#\"}"
            UID_LC="$(printf '%s' "$UID_VAL" | tr '[:upper:]' '[:lower:]')"
            if [ -z "$UID_VAL" ]; then
                add_check "user_id_not_test" "" "FAIL" "User ID is an empty string literal; pass the host app's real user identifier."
            elif printf '%s' "$UID_LC" | grep -qE 'test|debug|dummy'; then
                add_check "user_id_not_test" "" "FAIL" "User ID \"$UID_VAL\" looks like a test/debug literal; use the host app's real user identity."
            elif printf '%s' "$UID_VAL" | grep -qE '^[0-9]+$'; then
                add_check "user_id_not_test" "" "FAIL" "User ID \"$UID_VAL\" is a numeric test literal; use the host app's real user identity."
            else
                add_check "user_id_not_test" "" "PASS" "User ID is a non-test string literal."
            fi ;;
        *)
            add_check "user_id_not_test" "" "PASS" "User ID supplied from a variable/expression (not a hardcoded test value)." ;;
    esac
fi

# DEFERRED to a follow-up patch (tracked in Notion log §11):
#   - mediation_info_passed:        Initialize call must pass MeticaMediationInfo(MAX, sdkKey), not null
#   - load_while_showing (WARN):    flag LoadInterstitial/LoadRewarded invoked while an ad of the same
#                                   format is still showing. Needs call-graph/scope awareness to detect
#                                   without false positives; deferred until a reliable heuristic exists.
#   - banner_create_before_load:    CreateBanner precedes LoadBanner/ShowBanner
# Side-by-side mode additional rules:
#   - single_init_per_session:      MaxSdk.InitializeSdk gated by router; not called unconditionally
#   - iadservice_interface_present: an IAdService (or equivalent) interface exists
#   - max_adapter_present:          a MaxAdService (or equivalent) wraps Max calls
#   - metica_adapter_present:       a MeticaAdService (or equivalent) wraps Metica calls
#   - max_callsites_routed:         game code uses AdServiceRouter.Instance.AdService.* not MaxSdk.* directly
#
# REMOVED: ad_service_router_present — router presence is no longer a reliable
# signal. With the three-way matrix (fresh / straight-swap / side-by-side), the
# straight-swap path intentionally has no router, and mode auto-detection cannot
# distinguish straight-swap from side-by-side. The check produced false FAILs, so
# it was dropped; the router is only generated when remote-config drives an A/B.

# ---- determine status ------------------------------------------------------

STATUS="PASS"
# any FAIL → FAIL
if printf '%s' "$CHECKS" | grep -q '"level": "FAIL"'; then STATUS="FAIL"; fi

# ---- emit JSON --------------------------------------------------------------

printf '{\n'
printf '  "schema": "validator/1.1.0",\n'
printf '  "status": "%s",\n' "$STATUS"
printf '  "mode": "%s",\n' "$MODE"
printf '  "error": null,\n'
printf '  "warnings": [],\n'
printf '  "checks": [\n'
printf '%b' "$CHECKS"
printf '\n  ]\n}\n'

[ "$STATUS" = "PASS" ] && exit 0 || exit 1
