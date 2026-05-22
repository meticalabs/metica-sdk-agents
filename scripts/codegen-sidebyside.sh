#!/bin/bash
# codegen-sidebyside.sh — generate the side-by-side adapter architecture from
# the migration guide. Produces four files under Assets/Scripts/Metica/:
#   IAdService.cs           — interface + shared types
#   MaxAdService.cs         — MaxSdk adapter (does not modify existing MaxSdk usage)
#   MeticaAdService.cs      — MeticaSdk adapter
#   AdServiceRouter.cs      — picks adapter at startup
#
# Usage: codegen-sidebyside.sh --project=<path> --api-key=KEY --app-id=ID --max-sdk-key=KEY [--force]
# Exit: 0 on success.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/templates/sidebyside"

PROJECT=""
API_KEY=""
APP_ID=""
MAX_SDK_KEY=""
FORCE=0

for arg in "$@"; do
    case $arg in
        --project=*)     PROJECT="${arg#*=}" ;;
        --api-key=*)     API_KEY="${arg#*=}" ;;
        --app-id=*)      APP_ID="${arg#*=}" ;;
        --max-sdk-key=*) MAX_SDK_KEY="${arg#*=}" ;;
        --force)         FORCE=1 ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown arg: $arg" >&2; exit 1 ;;
    esac
done

[ -n "$PROJECT" ]        || { echo "Missing --project" >&2; exit 1; }
[ -d "$PROJECT/Assets" ] || { echo "Not a Unity project: $PROJECT" >&2; exit 1; }
[ -n "$API_KEY" ]        || { echo "Missing --api-key" >&2; exit 1; }
[ -n "$APP_ID" ]         || { echo "Missing --app-id" >&2; exit 1; }
[ -n "$MAX_SDK_KEY" ]    || { echo "Missing --max-sdk-key" >&2; exit 1; }

# Reject control chars in keys (same hardening as fresh-mode codegen).
for v in "$API_KEY" "$APP_ID" "$MAX_SDK_KEY"; do
    case "$v" in
        *$'\n'*|*$'\r'*|*$'\t'*) echo "ERROR: keys must not contain control chars." >&2; exit 1 ;;
    esac
done

# Two-stage escape: first produce a valid C# string-literal value, then escape
# THAT result for sed's replacement field. Both stages double backslashes —
# input `x\y` becomes `x\\y` (valid C# for runtime `\`) and that becomes
# `x\\\\y` in the sed replacement so sed emits the intended `x\\y`.
cs_escape() {
    local s="$1"
    # Stage 1: escape for C# string literal.
    s="${s//\\/\\\\}"      # \ → \\  (so C# decodes back to one \)
    s="${s//\"/\\\"}"      # " → \"  (close-quote escape)
    # Stage 2: escape the C#-escaped result for sed's REPLACEMENT field.
    s="${s//\\/\\\\}"      # each \ in the C# output → \\ for sed
    s="${s//\&/\\&}"       # & has special meaning in sed replacement
    s="${s//\//\\/}"       # / is the sed delimiter
    printf '%s' "$s"
}

OUT_DIR="$PROJECT/Assets/Scripts/Metica"
mkdir -p "$OUT_DIR"

emit_template() {
    local tmpl="$1" out="$2"
    if [ -f "$out" ] && [ "$FORCE" != "1" ]; then
        echo "ERROR: $out already exists. Pass --force to overwrite." >&2
        return 2
    fi
    # Substitute placeholders.
    local k1 k2 k3
    k1=$(cs_escape "$API_KEY")
    k2=$(cs_escape "$APP_ID")
    k3=$(cs_escape "$MAX_SDK_KEY")
    sed -e "s/__METICA_API_KEY__/$k1/g" \
        -e "s/__METICA_APP_ID__/$k2/g"  \
        -e "s/__MAX_SDK_KEY__/$k3/g"    \
        "$tmpl" > "$out"
}

declare -a TARGETS=(
    "IAdService.cs.tmpl:IAdService.cs"
    "MaxAdService.cs.tmpl:MaxAdService.cs"
    "MeticaAdService.cs.tmpl:MeticaAdService.cs"
    "AdServiceRouter.cs.tmpl:AdServiceRouter.cs"
)

# Pre-check: refuse if any target file exists without --force.
if [ "$FORCE" != "1" ]; then
    for pair in "${TARGETS[@]}"; do
        out="$OUT_DIR/${pair##*:}"
        if [ -f "$out" ]; then
            echo "ERROR: $out already exists. Pass --force to overwrite." >&2
            exit 1
        fi
    done
fi

for pair in "${TARGETS[@]}"; do
    tmpl="$TEMPLATE_DIR/${pair%%:*}"
    out="$OUT_DIR/${pair##*:}"
    [ -f "$tmpl" ] || { echo "ERROR: template not found: $tmpl" >&2; exit 1; }
    emit_template "$tmpl" "$out"
    echo "Generated: $out"
done

echo
echo "Next step (manual): replace MaxSdk.* callsites in your game code with"
echo "  AdServiceRouter.Instance.AdService.*"
echo "Then call ads.SetHasUserConsent / ads.SetDoNotSell BEFORE ads.Initialize"
echo "in your game's bootstrap. See references/max-vs-metica-2.4.0-api.md for the parity table."
