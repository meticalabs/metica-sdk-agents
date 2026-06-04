#!/bin/bash
# log-monitor-start.sh — Phase 1 of ad-log-monitor.
# Detect platform, gate the toolchain, kick off a background ad-log capture,
# verify it's actually streaming, and write a session file for stop.sh.
#
# Usage: log-monitor-start.sh --label=<slug> [--platform=auto|android|ios]
#                             [--app=<process-name>] [--output-dir=<dir>]
# Exit:  0 = capture started cleanly, 1 = invocation/toolchain/health failure.

set -u
set -o pipefail

LABEL=""
PLATFORM="auto"
APP=""
OUTPUT_DIR="$PWD"
OUTPUT_DIR_USER_PROVIDED=0

die() { printf 'FAIL\t%s\n' "$1" >&2; exit 1; }

for arg in "$@"; do
    case $arg in
        --label=*)      LABEL="${arg#*=}" ;;
        --platform=*)   PLATFORM="${arg#*=}" ;;
        --app=*)        APP="${arg#*=}" ;;
        --output-dir=*) OUTPUT_DIR="${arg#*=}"; OUTPUT_DIR_USER_PROVIDED=1 ;;
        -h|--help)
            sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) die "Unknown arg: $arg" ;;
    esac
done

[ -n "$LABEL" ] || die "Missing --label=<slug>"
printf '%s' "$LABEL" | grep -qE '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$' \
    || die "Label '$LABEL' is not kebab-case (lowercase letters, digits, dashes; no leading/trailing dash)."
[ -d "$OUTPUT_DIR" ] || die "Output dir not found: $OUTPUT_DIR"

case "$PLATFORM" in auto|android|ios) ;; *) die "Unknown --platform=$PLATFORM (auto|android|ios)" ;; esac

# Session-file no-clobber check runs BEFORE platform detection and the
# toolchain gate: a stale .session is a local-filesystem problem, doesn't
# need adb / idevicesyslog to diagnose, and we'd rather tell the user to
# clean up than confuse them with a toolchain hint.
SESSION_FILE="$OUTPUT_DIR/$LABEL.session"
# Atomically claim the session file using bash's noclobber (`set -C`):
# under noclobber, the `>` redirection refuses to overwrite an existing
# file and the subshell exits non-zero. Two near-simultaneous invocations
# can't both pass this check — file creation is atomic at the filesystem
# level, so only one wins the claim. (A plain `[ -e ]` check would have
# a TOCTOU window between the test and the eventual write.)
if ! ( set -C; : > "$SESSION_FILE" ) 2>/dev/null; then
    cleanup_hint="bash \"$(dirname "$0")/log-monitor-stop.sh\" --label=\"$LABEL\""
    [ "$OUTPUT_DIR_USER_PROVIDED" = "1" ] && cleanup_hint="$cleanup_hint --output-dir=\"$OUTPUT_DIR\""
    die "Session file already exists: $SESSION_FILE
  Either a concurrent capture is already running with this label, or an
  earlier capture for label '$LABEL' did not finish cleanly. Run
    $cleanup_hint
  to close it, or delete the stale .session and retry. (Old timestamped
  .log files don't conflict with a new run and can be left in place.)"
fi

# From the atomic claim onward, every failure path must clean up after
# itself: the empty .session we just created, the .log file once it's
# been opened, and the capture process once it's been launched. A single
# EXIT trap centralises that. The success path disarms the trap at the
# very end (just before `exit 0`).
cleanup_on_failure() {
    [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null || true
    [ -n "${LOG_FILE:-}" ] && rm -f "$LOG_FILE"
    rm -f "$SESSION_FILE"
}
trap cleanup_on_failure EXIT

# Reject control characters in --app before they reach the session file,
# where a newline would break the key=value parser in stop.sh.
case "$APP" in
    *$'\n'*|*$'\r'*|*$'\t'*) die "Invalid --app value: contains newline, carriage return, or tab." ;;
esac

# ---- platform detection -----------------------------------------------------

# probe_ios accepts either idevice_id (preferred, gives device list) OR
# idevicesyslog alone — otherwise an iOS-only host with just idevicesyslog
# installed gets mis-reported as "no device".
probe_android() { command -v adb >/dev/null 2>&1 && adb devices 2>/dev/null | awk 'NR>1 && $2=="device"' | grep -q .; }
probe_ios()     {
    if command -v idevice_id >/dev/null 2>&1; then
        idevice_id -l 2>/dev/null | grep -q .
    else
        command -v idevicesyslog >/dev/null 2>&1
    fi
}

if [ "$PLATFORM" = "auto" ]; then
    have_a=0; have_i=0
    probe_android && have_a=1
    probe_ios     && have_i=1
    if   [ $have_a = 1 ] && [ $have_i = 1 ]; then die "Both Android and iOS devices connected — pass --platform=android or --platform=ios to disambiguate."
    elif [ $have_a = 1 ]; then PLATFORM="android"
    elif [ $have_i = 1 ]; then PLATFORM="ios"
    else die "No Android or iOS device detected. Connect a device (and accept the USB-debug / Trust prompt) and retry."
    fi
fi

# Capture filename embeds an ISO-basic UTC timestamp so multiple runs with
# the same label (different days, different builds) don't clobber each other.
TIMESTAMP="$(date -u +"%Y%m%dT%H%M%SZ")"
LOG_FILE="$OUTPUT_DIR/$LABEL-$PLATFORM-$TIMESTAMP.log"

# Defensive: the timestamp is only second-resolution, so two captures
# started within the same second (after the previous session has been
# stopped) would land on identical $LOG_FILE paths. Catch that with a
# light existence check and tell the user the cause — they just need to
# wait one second and retry.
[ -e "$LOG_FILE" ] && die "Log file already exists at $LOG_FILE
  Two captures within the same second collided on the UTC timestamp.
  Wait one second and retry."

# ---- toolchain gate (hard BLOCK with install hint) --------------------------

case "$PLATFORM" in
android)
    command -v adb >/dev/null 2>&1 || die "adb not found on PATH.
  Install:
    macOS:        brew install android-platform-tools
    Debian/Ubuntu: apt install adb
    Windows:      https://developer.android.com/tools/releases/platform-tools" ;;
ios)
    command -v idevicesyslog >/dev/null 2>&1 || die "idevicesyslog not found on PATH.
  Install:
    macOS:  brew install libimobiledevice
    Linux:  apt install libimobiledevice-utils
    Windows is not supported by libimobiledevice; use a Mac or Linux host." ;;
esac

# ---- launch capture --------------------------------------------------------

case "$PLATFORM" in
android)
    # NOTE: `adb logcat -c` clears the device's main log buffer for ALL apps,
    # not just the target. This is intentional — it gives a clean capture
    # uncluttered by earlier sessions — but other debugging workflows on the
    # same device will lose their pre-existing log history. Agent prose
    # (Phase 1) is expected to flag this to the user before running.
    adb logcat -c >/dev/null 2>&1 || die "adb logcat -c failed. Check 'adb devices' output."
    adb logcat -v threadtime >"$LOG_FILE" 2>&1 &
    PID=$!
    ;;
ios)
    if [ -n "$APP" ]; then
        idevicesyslog -p "$APP" >"$LOG_FILE" 2>&1 &
    else
        idevicesyslog >"$LOG_FILE" 2>&1 &
    fi
    PID=$!
    ;;
esac

# ---- post-launch health checks ---------------------------------------------

sleep 0.3
if ! kill -0 "$PID" 2>/dev/null; then
    first="$(head -n 1 "$LOG_FILE" 2>/dev/null)"
    rm -f "$LOG_FILE"
    die "Capture process died immediately. Tool output:
  $first"
fi

# Give the device a couple of seconds to stream the first lines. iOS
# idevicesyslog needs longer than adb on a freshly-paired device — bump
# the iOS wait to 4s so we don't false-fail healthy captures.
case "$PLATFORM" in ios) sleep 4 ;; *) sleep 2 ;; esac

if [ ! -s "$LOG_FILE" ]; then
    kill "$PID" 2>/dev/null || true
    rm -f "$LOG_FILE"
    die "Capture wrote 0 bytes. Likely causes:
  - Android: device not authorized — accept the USB-debug RSA prompt on the device.
  - iOS:    pairing not trusted — accept the 'Trust this computer' prompt on the device.
  - Wrong device selected (multiple devices connected to the host)."
fi

# Patterns checked against real first lines from both tools — adb's normal
# opener "--------- beginning of main" and idevicesyslog's connect banner do
# NOT match any pattern here, so the happy path passes through cleanly.
first="$(head -n 1 "$LOG_FILE" 2>/dev/null)"
case "$first" in
    "error:"*|"ERROR:"*|"Could not"*|"No device"*|*"not found"*)
        kill "$PID" 2>/dev/null || true
        rm -f "$LOG_FILE"
        die "Capture started but the tool reported an error on the first line:
  $first" ;;
esac

# ---- session file ----------------------------------------------------------

started_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
# Plain key=value, one per line. Stop.sh parses this with a `read` loop
# against a whitelist of keys — it does NOT source the file, so values
# cannot inject shell code. Values cannot contain newlines: $LABEL is
# kebab, $PLATFORM is android|ios, $PID is numeric, $started_at is ISO,
# $LOG_FILE is a constructed path, and $APP was rejected above if it
# contained control chars.
{
    printf 'label=%s\n'       "$LABEL"
    printf 'platform=%s\n'    "$PLATFORM"
    printf 'pid=%s\n'         "$PID"
    printf 'log_file=%s\n'    "$LOG_FILE"
    printf 'app=%s\n'         "$APP"
    printf 'started_at=%s\n'  "$started_at"
} > "$SESSION_FILE"

# Capture is healthy and the session is fully populated. Disarm the
# EXIT trap so the cleanup function doesn't tear it all down on the
# normal `exit 0` below.
trap - EXIT

# ---- confirmation ----------------------------------------------------------

cat <<EOF
OK	capture started
  label:    $LABEL
  platform: $PLATFORM
  pid:      $PID
  log:      $LOG_FILE
  session:  $SESSION_FILE
  started:  $started_at

Now hand the device to QA and ask them to play the game.
For a meaningful trial-vs-holdout comparison, target ~5 interstitials and
~5 rewarded ads per route. When done, stop and analyse with:

  log-monitor-stop.sh --label=$LABEL

EOF
exit 0
