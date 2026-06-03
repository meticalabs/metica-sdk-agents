#!/bin/bash
# check-citation.sh — deterministic anti-hallucination guard for the validator's
# semantic-adjudication phase (validator/1.2.0+).
#
# The semantic phase (agent prose, LLM-driven) returns PASS/FAIL verdicts backed
# by line-cited evidence: { file, line, snippet }. An LLM can fabricate a PASS by
# citing a line that does not exist or does not say what it claims. This script is
# the cheap, deterministic insurance: for every citation, open the file at the
# cited line and confirm the snippet is really there. A citation that does not
# resolve must downgrade its rule to FAIL regardless of the LLM verdict — so this
# script's non-zero exit is the signal the agent uses to force that downgrade.
#
# This is the ONE piece of the semantic path that is deterministic, so it is the
# one piece that stays golden/unit-tested (tests/run-citation-tests.sh).
#
# Input  (stdin): one citation per line, TAB-separated: <file>\t<line>\t<snippet>
#                 - <file> is relative to --project (if given) or absolute/CWD.
#                 - <line> is 1-based.
#                 - <snippet> is the remainder of the line; may contain spaces.
# Args:   --project=<root>   base dir for relative <file> paths (optional). When
#                            given, every citation must resolve INSIDE this root —
#                            a path escaping via `../`, a symlink, or an absolute
#                            path elsewhere is rejected ("path escapes project
#                            root"), so the guard can't be satisfied with unrelated
#                            files. With no --project, absolute paths are allowed.
# Output: one record per citation on stdout, TAB-separated:
#                 OK\t<file>\t<line>
#                 MISMATCH\t<file>\t<line>\t<reason>
# Exit:   0 = every citation resolved; 1 = at least one MISMATCH; 2 = bad invocation.
#
# Matching is whitespace-tolerant: both the cited line and the snippet are trimmed
# and have internal whitespace runs collapsed to a single space, then the line must
# CONTAIN the snippet. This tolerates indentation/reflow differences and lets the
# agent cite either a whole line or a substring of it, while still catching a line
# that genuinely does not contain the claimed code.

set -u
set -o pipefail

PROJECT=""

usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; }

for arg in "$@"; do
    case $arg in
        --project=*) PROJECT="${arg#*=}" ;;
        -h|--help)   usage; exit 0 ;;
        *)           printf 'check-citation: unknown arg: %s\n' "$arg" >&2; exit 2 ;;
    esac
done

PROJ_CANON=""
if [ -n "$PROJECT" ]; then
    if [ ! -d "$PROJECT" ]; then
        printf 'check-citation: project not found: %s\n' "$PROJECT" >&2
        exit 2
    fi
    # Canonical project root (resolves symlinks + ..) for the containment check below.
    PROJ_CANON="$(cd "$PROJECT" 2>/dev/null && pwd -P)" || {
        printf 'check-citation: cannot resolve project: %s\n' "$PROJECT" >&2
        exit 2
    }
fi

# Normalize: strip leading/trailing whitespace, collapse internal runs to one space.
norm() {
    printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/[[:space:]]\{1,\}/ /g'
}

any_mismatch=0

emit_ok()       { printf 'OK\t%s\t%s\n' "$1" "$2"; }
emit_mismatch() { printf 'MISMATCH\t%s\t%s\t%s\n' "$1" "$2" "$3"; any_mismatch=1; }

while IFS=$'\t' read -r file line snippet || [ -n "${file:-}" ]; do
    # Skip wholly blank input lines.
    [ -z "${file:-}${line:-}${snippet:-}" ] && continue

    if [ -z "${file:-}" ] || [ -z "${line:-}" ]; then
        emit_mismatch "${file:-}" "${line:-}" "malformed citation (need <file>\\t<line>\\t<snippet>)"
        continue
    fi
    case "$line" in
        ''|*[!0-9]*) emit_mismatch "$file" "$line" "line is not a positive integer"; continue ;;
    esac
    if [ -z "$(norm "${snippet:-}")" ]; then
        emit_mismatch "$file" "$line" "empty snippet"
        continue
    fi

    # Resolve the path: absolute as-is; relative against --project when given.
    path="$file"
    case "$file" in
        /*) : ;;
        *)  [ -n "$PROJECT" ] && path="$PROJECT/$file" ;;
    esac

    if [ ! -f "$path" ]; then
        emit_mismatch "$file" "$line" "file not found"
        continue
    fi

    # When a project root is given, the evidence MUST live inside it. A citation
    # that escapes via `../`, a symlink, or an absolute path elsewhere is not
    # evidence about the integration under review — reject it so the guard can't
    # be satisfied with unrelated files. (With no --project, absolute paths are a
    # supported mode and this check is skipped.)
    if [ -n "$PROJ_CANON" ]; then
        real="$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)/$(basename "$path")"
        case "$real" in
            "$PROJ_CANON"/*) : ;;
            *) emit_mismatch "$file" "$line" "path escapes project root"; continue ;;
        esac
    fi

    # awk's NR is the true line count whether or not the file ends in a trailing
    # newline (the final partial line still counts as a record), so there is no
    # off-by-one to fudge: a line past EOF is reported as "out of range", not as a
    # confusing "snippet not found" on a phantom line.
    total="$(awk 'END { print NR }' "$path")"
    if [ "$line" -lt 1 ] || [ "$line" -gt "$total" ]; then
        emit_mismatch "$file" "$line" "line out of range (file has $total lines)"
        continue
    fi

    actual="$(awk -v n="$line" 'NR==n { print; exit }' "$path")"
    if [ -z "$actual" ]; then
        # Genuinely blank source line can never contain a non-empty snippet.
        emit_mismatch "$file" "$line" "cited line is blank"
        continue
    fi

    if printf '%s' "$(norm "$actual")" | grep -qF -- "$(norm "$snippet")"; then
        emit_ok "$file" "$line"
    else
        emit_mismatch "$file" "$line" "snippet not found on cited line"
    fi
done

[ "$any_mismatch" = "0" ] || exit 1
exit 0
