#!/bin/bash
# validate-keys.sh — input validation + escaping helper for agent-driven codegen.
# Replaces the upfront-validation half of the deleted codegen scripts' cs_escape.
# The agent is REQUIRED to call this for every key/ID it embeds in generated
# code, so the safety invariants stay testable from bash even though codegen
# itself now lives in agent prose.
#
# Usage:
#   validate-keys.sh --type=string-literal VALUE
#   validate-keys.sh --type=remote-config-key VALUE
#
# --type=string-literal:
#   Used for API_KEY, APP_ID, MAX_SDK_KEY before embedding inside a C#
#   double-quoted string literal. Rejects empty values and values containing
#   newline / CR / tab. Emits the C#-escaped form on stdout (\\ then \").
#   No sed-replacement layer (that was needed by the deleted sed-driven script;
#   the agent writes via the Write tool, so a single-stage escape is correct).
#
# --type=remote-config-key:
#   Used for REMOTE_CONFIG_KEY before embedding in a generated Bind() body.
#   Rejects empty, control chars, double-quote, backslash. Validates against
#   ^[A-Za-z0-9_.-]+$  (the relaxed character class that both Firebase Remote
#   Config and Unity Remote Config permit in parameter names). Emits the value
#   unchanged on stdout — the allowed character set is already string-literal-
#   safe so no escape is applied.
#
# Exit:
#   0  validation passed; escaped/passthrough value on stdout.
#   1  validation failed; reason on stderr.
#   2  invocation error (missing args, unknown type).

set -u

TYPE=""
VALUE=""
HAVE_VALUE=0
for arg in "$@"; do
    case "$arg" in
        --type=*) TYPE="${arg#*=}" ;;
        --help|-h)
            sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            if [ "$HAVE_VALUE" = "1" ]; then
                echo "ERROR: multiple positional values; pass exactly one." >&2
                exit 2
            fi
            VALUE="$arg"; HAVE_VALUE=1 ;;
    esac
done

[ -n "$TYPE" ]            || { echo "Missing --type (expected string-literal | remote-config-key)" >&2; exit 2; }
[ "$HAVE_VALUE" = "1" ]   || { echo "Missing value (positional arg)" >&2; exit 2; }

case "$TYPE" in
    string-literal)
        [ -n "$VALUE" ] || { echo "ERROR: value must be non-empty." >&2; exit 1; }
        case "$VALUE" in
            *$'\n'*|*$'\r'*|*$'\t'*)
                echo "ERROR: value must not contain newline, carriage return, or tab characters." >&2
                exit 1 ;;
        esac
        s="$VALUE"
        s="${s//\\/\\\\}"   # \  → \\
        s="${s//\"/\\\"}"   # "  → \"
        printf '%s' "$s"
        ;;
    remote-config-key)
        [ -n "$VALUE" ] || { echo "ERROR: REMOTE_CONFIG_KEY must be non-empty." >&2; exit 1; }
        case "$VALUE" in
            *$'\n'*|*$'\r'*|*$'\t'*)
                echo "ERROR: REMOTE_CONFIG_KEY must not contain control characters." >&2
                exit 1 ;;
            *\"*)
                echo "ERROR: REMOTE_CONFIG_KEY must not contain a double-quote character." >&2
                exit 1 ;;
            *\\*)
                echo "ERROR: REMOTE_CONFIG_KEY must not contain a backslash character." >&2
                exit 1 ;;
        esac
        # Whitelist: alphanumeric + _ . - (allowed by Firebase / Unity / AppMetrica dashboards).
        if ! [[ "$VALUE" =~ ^[A-Za-z0-9_.-]+$ ]]; then
            echo "ERROR: REMOTE_CONFIG_KEY must match ^[A-Za-z0-9_.-]+\$ (got: $VALUE)" >&2
            exit 1
        fi
        printf '%s' "$VALUE"
        ;;
    *)
        echo "Unknown --type: $TYPE (expected: string-literal | remote-config-key)" >&2
        exit 2 ;;
esac
