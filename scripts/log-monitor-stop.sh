#!/bin/bash
# log-monitor-stop.sh — Phase 2 of ad-log-monitor.
# Stop the capture identified by --label, run runtime ad-logic rule checks
# against the captured log, and emit a Markdown analysis report.
#
# Usage: log-monitor-stop.sh --label=<slug> [--output-dir=<dir>]
# Exit:  0 = report written (regardless of rule levels), 1 = invocation/missing-session.

set -u
set -o pipefail

LABEL=""
OUTPUT_DIR="$PWD"

die() { printf 'FAIL\t%s\n' "$1" >&2; exit 1; }

for arg in "$@"; do
    case $arg in
        --label=*)      LABEL="${arg#*=}" ;;
        --output-dir=*) OUTPUT_DIR="${arg#*=}" ;;
        -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown arg: $arg" ;;
    esac
done

[ -n "$LABEL" ] || die "Missing --label=<slug>"
[ -d "$OUTPUT_DIR" ] || die "Output dir not found: $OUTPUT_DIR"

SESSION_FILE="$OUTPUT_DIR/$LABEL.session"
[ -f "$SESSION_FILE" ] || die "No session file for label '$LABEL' at $SESSION_FILE.
  Run log-monitor-start.sh --label=$LABEL first."

# shellcheck disable=SC1090
. "$SESSION_FILE"
: "${label:?session file missing label}"
: "${platform:?session file missing platform}"
: "${pid:?session file missing pid}"
: "${log_file:?session file missing log_file}"
[ -f "$log_file" ] || die "Captured log file not found: $log_file"

# ---- stop capture ----------------------------------------------------------

if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    sleep 0.3
    kill -9 "$pid" 2>/dev/null || true
fi
# Fallback: kill any leftover capture writing to our log file.
pkill -f "$log_file" 2>/dev/null || true

LOG="$log_file"
TOTAL_LINES=$(wc -l < "$LOG" | tr -d ' ')

# ---- helpers ---------------------------------------------------------------

# Count grep -E matches in $LOG (case-insensitive). Empty pattern → 0.
# grep -c prints the count AND exits 1 on zero matches, so we capture stdout
# and discard the failure with || true rather than echoing a second zero.
gcount() {
    local n=0
    if [ -n "${1:-}" ]; then
        n=$(grep -cEi "$1" "$LOG" 2>/dev/null) || n=0
    fi
    printf '%s' "${n:-0}"
}

# First match (line number + content) for the given regex.
first_line() { grep -nEi "$1" "$LOG" 2>/dev/null | head -n 1 || true; }

# Line number only (first occurrence), or empty.
first_lineno() { first_line "$1" | cut -d: -f1; }

# Emit a rule row: name, level, evidence (one line, pipes/backslashes/newlines stripped for table safety).
rule_row() {
    local name="$1" level="$2" evidence="$3"
    evidence="${evidence//$'\n'/ }"
    evidence="${evidence//|/\\|}"
    printf '| %s | %s | %s |\n' "$name" "$level" "$evidence"
}

# ---- format detection ------------------------------------------------------

has_interstitial=0; has_rewarded=0; has_banner=0; has_mrec=0
[ "$(gcount 'MaxInterstitialAd|Metica.*[Ii]nterstitial')" -gt 0 ] && has_interstitial=1
[ "$(gcount 'MaxRewardedAd|Metica.*[Rr]ewarded')" -gt 0 ]         && has_rewarded=1
[ "$(gcount 'MaxBannerAd|Metica.*[Bb]anner')" -gt 0 ]             && has_banner=1
[ "$(gcount 'MaxMRecAd|Metica.*[Mm]rec')" -gt 0 ]                 && has_mrec=1

has_max=0
[ "$(gcount 'MaxSdk|MaxInterstitialAd|MaxRewardedAd|MaxBannerAd|MaxMRecAd|AppLovin')" -gt 0 ] && has_max=1

formats=""
[ $has_interstitial = 1 ] && formats="${formats}interstitial,"
[ $has_rewarded = 1 ]     && formats="${formats}rewarded,"
[ $has_banner = 1 ]       && formats="${formats}banner,"
[ $has_mrec = 1 ]         && formats="${formats}mrec,"
formats="${formats%,}"
[ -z "$formats" ] && formats="(none observed)"

# ---- output paths ----------------------------------------------------------

REPORT="$OUTPUT_DIR/$LABEL-analysis.md"

# ---- init checks -----------------------------------------------------------

init_count=$(gcount 'MeticaSdk\.Initialize|MeticaSdk\s*=.*Initialize|\[Metica\].*[Ii]nitializ')
consent_ln=$(first_lineno 'SetHasUserConsent')
dns_ln=$(first_lineno 'SetDoNotSell')
init_ln=$(first_lineno 'MeticaSdk\.Initialize')
on_init_evidence=$(first_line 'OnInitialized|SmartFloors.*(group|userId)|Metica.*initialized.*group')

init_count_level="PASS"; init_count_ev="found $init_count Initialize line(s) (expected 1)"
[ "$init_count" = "1" ] || init_count_level="FAIL"

if [ -n "$init_ln" ]; then
    if [ -n "$consent_ln" ] && [ -n "$dns_ln" ] \
        && [ "$consent_ln" -lt "$init_ln" ] && [ "$dns_ln" -lt "$init_ln" ]; then
        privacy_level="PASS"
        privacy_ev="SetHasUserConsent@$consent_ln + SetDoNotSell@$dns_ln before Initialize@$init_ln"
    else
        privacy_level="FAIL"
        privacy_ev="consent@${consent_ln:-MISSING} doNotSell@${dns_ln:-MISSING} init@$init_ln — both privacy calls must precede init"
    fi
else
    privacy_level="ADVISORY"
    privacy_ev="no Initialize line observed — privacy ordering cannot be checked"
fi

if [ -n "$on_init_evidence" ]; then
    init_cb_level="PASS"; init_cb_ev="$on_init_evidence"
else
    init_cb_level="FAIL"; init_cb_ev="no OnInitialized / SmartFloors group line found — Metica config did not load"
fi

# ---- per-format checks -----------------------------------------------------

# Args: $1=format name, $2=ad-class regex (eg MaxInterstitialAd), $3=hidden-event regex,
#       $4=show-failed regex (or empty if N/A — banner/mrec).
emit_format_block() {
    local fmt="$1" cls="$2" hide="$3" failed="${4:-}" extra="${5:-}"

    # Portable title-case for the format name (bash 3.2 has no ${var^}).
    local fmt_cap
    case "$fmt" in
        interstitial) fmt_cap="Interstitial" ;;
        rewarded)     fmt_cap="Rewarded" ;;
        banner)       fmt_cap="Banner" ;;
        mrec)         fmt_cap="MRec" ;;
        *)            fmt_cap="$fmt" ;;
    esac

    local loads loaded nofill shows hidden showfail
    loads=$(gcount "${cls}.*loadAd\\(\\)")
    loaded=$(gcount "${cls}.*Transitioning from LOADING to READY")
    nofill=$(gcount "${cls}.*Transitioning from LOADING to IDLE")
    shows=$(gcount "${cls}.*Transitioning from READY to SHOWING")
    hidden=$(gcount "$hide")
    showfail=0
    [ -n "$failed" ] && showfail=$(gcount "$failed")

    {
        printf '\n## %s\n\n' "$fmt_cap"
        printf '### Metrics\n\n'
        printf '| Metric | Value |\n|---|---|\n'
        printf '| Load requests | %s |\n' "$loads"
        printf '| Loaded (READY) | %s |\n' "$loaded"
        printf '| No-fill (IDLE) | %s |\n' "$nofill"
        printf '| Shows | %s |\n' "$shows"
        [ -n "$failed" ] && printf '| Show failed | %s |\n' "$showfail"
        printf '| Hidden | %s |\n' "$hidden"
        printf '\n### Rules\n\n'
        printf '| Rule | Level | Evidence |\n|---|---|---|\n'
    } >> "$REPORT"

    # load_lifecycle_clean — every loadAd should reach READY or IDLE.
    local terminal=$((loaded + nofill))
    if [ "$loads" = "0" ]; then
        rule_row "load_lifecycle_clean" "ADVISORY" "no loadAd() calls observed for $fmt" >> "$REPORT"
    elif [ "$terminal" -ge "$loads" ]; then
        rule_row "load_lifecycle_clean" "PASS" "$loads loadAd → $loaded READY + $nofill IDLE = $terminal terminal" >> "$REPORT"
    else
        local stuck=$((loads - terminal))
        rule_row "load_lifecycle_clean" "FAIL" "$stuck loadAd never reached READY/IDLE (loads=$loads, terminal=$terminal)" >> "$REPORT"
    fi

    # show_after_ready — any non-READY→SHOWING transition is suspicious.
    local non_ready_show
    non_ready_show=$(gcount "${cls}.*Transitioning from (LOADING|IDLE|DESTROYED) to SHOWING")
    if [ "$shows" = "0" ]; then
        rule_row "show_after_ready" "ADVISORY" "no shows observed for $fmt" >> "$REPORT"
    elif [ "$non_ready_show" = "0" ]; then
        rule_row "show_after_ready" "PASS" "all $shows shows entered SHOWING from READY" >> "$REPORT"
    else
        rule_row "show_after_ready" "FAIL" "$non_ready_show show(s) bypassed READY — IsReady was not checked" >> "$REPORT"
    fi

    # hide_after_show — every show should produce a hide.
    if [ "$shows" = "0" ]; then
        rule_row "hide_after_show" "ADVISORY" "no shows observed" >> "$REPORT"
    elif [ "$hidden" -ge "$shows" ]; then
        rule_row "hide_after_show" "PASS" "$shows shows → $hidden hides" >> "$REPORT"
    else
        rule_row "hide_after_show" "FAIL" "$((shows - hidden)) show(s) never reached Hidden — listener bug" >> "$REPORT"
    fi

    # auto_reload_on_hidden — for interstitial/rewarded only; banner/mrec self-refresh.
    if [ "$fmt" = "interstitial" ] || [ "$fmt" = "rewarded" ]; then
        if [ "$hidden" = "0" ]; then
            rule_row "auto_reload_on_hidden" "ADVISORY" "no hide events to evaluate reload" >> "$REPORT"
        elif [ "$loads" -ge $((hidden + 1)) ]; then
            rule_row "auto_reload_on_hidden" "PASS" "$loads loads ≥ $hidden hides + 1 initial" >> "$REPORT"
        else
            rule_row "auto_reload_on_hidden" "FAIL" "$loads loads < $hidden hides + 1 — reload loop is broken" >> "$REPORT"
        fi
    fi

    # on_show_failed_recovers — only for interstitial/rewarded.
    if [ -n "$failed" ]; then
        if [ "$showfail" = "0" ]; then
            rule_row "on_show_failed_recovers" "PASS" "no show failures observed" >> "$REPORT"
        elif [ "$loads" -gt "$shows" ]; then
            rule_row "on_show_failed_recovers" "PASS" "$showfail show fail(s); loads exceed shows so recovery loadAd is presumed to have fired" >> "$REPORT"
        else
            rule_row "on_show_failed_recovers" "FAIL" "$showfail show fail(s) but loads=$loads ≤ shows=$shows — reload loop stalled on show-fail" >> "$REPORT"
        fi
    fi

    # no_concurrent_loads — loads should not exceed terminals by more than 1.
    if [ "$loads" = "0" ]; then
        :  # nothing to evaluate
    elif [ "$loads" -le $((terminal + 1)) ]; then
        rule_row "no_concurrent_loads" "PASS" "$loads loads vs $terminal terminals (≤ +1 in-flight)" >> "$REPORT"
    else
        rule_row "no_concurrent_loads" "ADVISORY" "$loads loads vs $terminal terminals — possible duplicate-load race ($((loads - terminal)) in flight)" >> "$REPORT"
    fi

    # Inline any format-specific extra rule rows.
    [ -n "$extra" ] && printf '%s' "$extra" >> "$REPORT"
}

# ---- rewarded_reward_before_hidden (special: ordering check) ---------------

rewarded_order_row=""
if [ $has_rewarded = 1 ]; then
    reward_ln=$(first_lineno 'OnRewardedAdReceivedRewardEvent|OnRewarded.*RewardEvent|OnUserReceivedReward')
    rew_hide_ln=$(first_lineno 'OnRewardedAdHiddenEvent|OnRewarded.*HiddenEvent')
    if [ -z "$reward_ln" ] && [ -z "$rew_hide_ln" ]; then
        rewarded_order_row="$(rule_row 'rewarded_reward_before_hidden' 'ADVISORY' 'no rewarded reward/hide events observed')"
    elif [ -z "$reward_ln" ]; then
        rewarded_order_row="$(rule_row 'rewarded_reward_before_hidden' 'FAIL' "OnRewardedAdHiddenEvent@$rew_hide_ln fired but no reward callback — reward sequencing broken")"
    elif [ -z "$rew_hide_ln" ]; then
        rewarded_order_row="$(rule_row 'rewarded_reward_before_hidden' 'ADVISORY' "reward@$reward_ln but no Hidden event yet")"
    elif [ "$reward_ln" -lt "$rew_hide_ln" ]; then
        rewarded_order_row="$(rule_row 'rewarded_reward_before_hidden' 'PASS' "reward@$reward_ln before Hidden@$rew_hide_ln")"
    else
        rewarded_order_row="$(rule_row 'rewarded_reward_before_hidden' 'FAIL' "reward@$reward_ln AFTER Hidden@$rew_hide_ln — reward sequencing broken")"
    fi
    rewarded_order_row="$(printf '%s\n' "$rewarded_order_row")"
fi

# ---- Metica → MAX handoff --------------------------------------------------

floor_set_first=$(first_lineno 'setLocalExtraParameter|setExtraParameter|dynamicBidFloor|dynamicKeyName|cpmFloorAdUnitId')
first_load_ln=$(first_lineno 'MaxInterstitialAd.*loadAd\(\)|MaxRewardedAd.*loadAd\(\)|MaxBannerAd.*loadAd\(\)|MaxMRecAd.*loadAd\(\)')

handoff_set_level="ADVISORY"; handoff_set_ev="MAX not present in log"
handoff_val_level="ADVISORY"; handoff_val_ev="MAX not present in log"
if [ $has_max = 1 ]; then
    if [ -z "$first_load_ln" ]; then
        handoff_set_level="ADVISORY"; handoff_set_ev="no MAX loadAd observed"
    elif [ -z "$floor_set_first" ]; then
        handoff_set_level="ADVISORY"; handoff_set_ev="no Metica floor parameters observed — handoff not exercised this session"
    elif [ "$floor_set_first" -lt "$first_load_ln" ]; then
        handoff_set_level="PASS"; handoff_set_ev="floor params first set@$floor_set_first before first MAX loadAd@$first_load_ln"
    else
        handoff_set_level="FAIL"; handoff_set_ev="floor params first set@$floor_set_first AFTER first MAX loadAd@$first_load_ln — MAX auctioned without the floor"
    fi

    if [ -n "$floor_set_first" ]; then
        # Pull numeric floor values and check ranges.
        bad_floor=$(grep -oEi 'dynamicBidFloor[^0-9]*[0-9]+(\.[0-9]+)?' "$LOG" 2>/dev/null \
                    | grep -oE '[0-9]+(\.[0-9]+)?' \
                    | awk '{ if ($1 <= 0 || $1 > 100) { print; exit } }')
        if [ -n "$bad_floor" ]; then
            handoff_val_level="FAIL"; handoff_val_ev="implausible floor value: $bad_floor (expected 0 < value ≤ 100 eCPM)"
        else
            handoff_val_level="PASS"; handoff_val_ev="all observed floor values in (0, 100] eCPM"
        fi
    else
        handoff_val_level="ADVISORY"; handoff_val_ev="no floor values to evaluate"
    fi
fi

# ---- error extraction ------------------------------------------------------

ERR_PATTERN='metica.*(error|exception|fail)|applovin.*error|MAX.*error|MaxSdk.*error|loadAd.*fail|sdk.*not initialized|invalid.*(api.?key|app.?id)|HTTP [45][0-9][0-9]|FATAL EXCEPTION'

# ---- write report ----------------------------------------------------------

{
    printf '# Ad Log Analysis — %s (%s)\n\n' "$LABEL" "$platform"
    printf '**Session started:** %s  \n' "$started_at"
    printf '**Source log:** `%s` (%s lines)  \n' "$LOG" "$TOTAL_LINES"
    printf '**Formats observed:** %s  \n' "$formats"
    [ $has_max = 1 ] && printf '**MAX present:** yes  \n' || printf '**MAX present:** no  \n'
    printf '\n---\n\n## Init checks\n\n'
    printf '| Rule | Level | Evidence |\n|---|---|---|\n'
    rule_row "init_count" "$init_count_level" "$init_count_ev"
    rule_row "privacy_before_init" "$privacy_level" "$privacy_ev"
    rule_row "initialized_callback_fired" "$init_cb_level" "$init_cb_ev"
} > "$REPORT"

[ $has_interstitial = 1 ] && emit_format_block "interstitial" "MaxInterstitialAd"           'OnInterstitialHiddenEvent|OnAdHiddenEvent.*[Ii]nterstitial' \
                                                'OnInterstitialAdLoadFailedEvent|OnAdShowFailed.*[Ii]nterstitial|OnInterstitialAdFailedToDisplayEvent'
[ $has_rewarded = 1 ]     && emit_format_block "rewarded"     "MaxRewardedAd"               'OnRewardedAdHiddenEvent|OnRewarded.*HiddenEvent' \
                                                'OnRewardedAdFailedToDisplayEvent|OnAdShowFailed.*[Rr]ewarded' \
                                                "$rewarded_order_row"
[ $has_banner = 1 ]       && emit_format_block "banner"       "MaxBannerAd"                 'OnBannerAdHiddenEvent|OnAdHiddenEvent.*[Bb]anner' ""
[ $has_mrec = 1 ]         && emit_format_block "mrec"         "MaxMRecAd"                   'OnMRecAdHiddenEvent|OnAdHiddenEvent.*[Mm]rec' ""

{
    printf '\n## Metica → MAX handoff\n\n'
    printf '| Rule | Level | Evidence |\n|---|---|---|\n'
    rule_row "floor_set_before_load" "$handoff_set_level" "$handoff_set_ev"
    rule_row "floor_value_sane"      "$handoff_val_level" "$handoff_val_ev"

    printf '\n## Errors & warnings\n\n'
    err_count=$(grep -cEi "$ERR_PATTERN" "$LOG" 2>/dev/null || printf '0')
    printf 'Matched %s error/warning line(s) (regex: metica/applovin/MAX errors, loadAd failures, invalid keys, HTTP 4xx/5xx, FATAL EXCEPTION).\n\n' "$err_count"
    if [ "$err_count" -gt 0 ]; then
        printf '### Unique signatures (count × line)\n\n'
        printf '```\n'
        grep -Ei "$ERR_PATTERN" "$LOG" 2>/dev/null \
            | sed -E 's/^[A-Za-z]{3}[[:space:]]+[0-9]+[[:space:]]+[0-9:]+[[:space:]]+[^[:space:]]+[[:space:]]+//' \
            | sed -E 's/^[0-9-]+[[:space:]]+[0-9:.]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+[A-Z][[:space:]]+//' \
            | sort | uniq -c | sort -rn | head -n 30
        printf '\n```\n'
    fi
    printf '\n---\n\n'
    printf '_Generated by ad-log-monitor. PASS/FAIL/ADVISORY are mechanical rule outputs; the agent prose interprets them and compares against the other route if both holdout and trial captures are present._\n'
} >> "$REPORT"

# ---- console summary -------------------------------------------------------

printf 'OK\treport written: %s\n' "$REPORT"
printf '  total lines: %s\n' "$TOTAL_LINES"
printf '  formats:     %s\n' "$formats"

# Clean up session.
rm -f "$SESSION_FILE"

exit 0
