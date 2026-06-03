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

die() { printf 'FAIL\t%s\n' "$1" >&2; exit 1; }

for arg in "$@"; do
    case $arg in
        --label=*)      LABEL="${arg#*=}" ;;
        --platform=*)   PLATFORM="${arg#*=}" ;;
        --app=*)        APP="${arg#*=}" ;;
        --output-dir=*) OUTPUT_DIR="${arg#*=}" ;;
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

# ---- platform detection -----------------------------------------------------

probe_android() { command -v adb >/dev/null 2>&1 && adb devices 2>/dev/null | awk 'NR>1 && $2=="device"' | grep -q .; }
probe_ios()     { command -v idevice_id >/dev/null 2>&1 && idevice_id -l 2>/dev/null | grep -q .; }

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

# ---- output paths + no-clobber + no-stale-capture ---------------------------

LOG_FILE="$OUTPUT_DIR/$LABEL-$PLATFORM.log"
SESSION_FILE="$OUTPUT_DIR/$LABEL.session"

[ -e "$LOG_FILE" ]     && die "Log file already exists: $LOG_FILE
  Pick a different --label, or remove the old file (and its .session) and retry."
[ -e "$SESSION_FILE" ] && die "Session file already exists: $SESSION_FILE
  An earlier capture for label '$LABEL' did not finish cleanly. Run
    bash $(dirname "$0")/log-monitor-stop.sh --label=$LABEL
  to close it, or delete the stale .session and .log and retry."

# ---- launch capture --------------------------------------------------------

case "$PLATFORM" in
android)
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

# Give the device a couple of seconds to stream the first lines.
sleep 2

if [ ! -s "$LOG_FILE" ]; then
    kill "$PID" 2>/dev/null || true
    rm -f "$LOG_FILE"
    die "Capture wrote 0 bytes in 2s. Likely causes:
  - Android: device not authorized — accept the USB-debug RSA prompt on the device.
  - iOS:    pairing not trusted — accept the 'Trust this computer' prompt on the device.
  - Wrong device selected (multiple devices connected to the host)."
fi

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
# Shell-escape every value via %q so the file remains safely sourceable by
# log-monitor-stop.sh even when --app or --output-dir contains spaces / quotes.
{
    printf 'label=%q\n'       "$LABEL"
    printf 'platform=%q\n'    "$PLATFORM"
    printf 'pid=%q\n'         "$PID"
    printf 'log_file=%q\n'    "$LOG_FILE"
    printf 'app=%q\n'         "$APP"
    printf 'started_at=%q\n'  "$started_at"
} > "$SESSION_FILE"

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
