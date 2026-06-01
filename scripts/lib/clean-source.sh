#!/bin/bash
# clean-source.sh — shared accessor for reading C# source with string literals
# and line/block comments stripped (line numbers preserved). Sourced by BOTH the
# validator (validate-integration.sh) and the integrator's discovery Bash steps
# so the two scan byte-identical cleaned input.
#
# v1.0 (RFC OQ4 — "seam now, cache later"): the body shells clean-cs.awk per file,
# inline, exactly as before. The materialized cleaned-source cache that amortises
# the awk passes is a later, localized drop-in BEHIND this accessor — no caller
# changes when it lands, because every consumer already goes through clean_source.
#
# Usage (after `source`-ing this file):
#   clean_source <file>      # prints cleaned source for <file> to stdout
#   clean_source_selftest    # returns 0 if usable, non-zero if awk/script broken
#
# clean-cs.awk is resolved relative to THIS lib's own location, so it works
# regardless of the caller's CWD. A pre-set $CLEAN_CS_AWK (e.g. a dev override)
# takes precedence.

# Guard against double-sourcing (a consumer may source this lib more than once).
if [ -z "${__METICA_CLEAN_SOURCE_SH:-}" ]; then
__METICA_CLEAN_SOURCE_SH=1

__CLEAN_SOURCE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEAN_CS_AWK="${CLEAN_CS_AWK:-$__CLEAN_SOURCE_LIB_DIR/clean-cs.awk}"

clean_source() { awk -f "$CLEAN_CS_AWK" "$1"; }

# Smoke-test the accessor before relying on it. A broken accessor must be caught
# loudly by the caller — a silent failure would return zero matches everywhere
# and produce a misleading all-PASS report.
clean_source_selftest() {
    [ -f "$CLEAN_CS_AWK" ]              || return 1
    clean_source /dev/null >/dev/null 2>&1 || return 1
    # The checks above pass even for a degenerate accessor that returns EMPTY for
    # ALL input — which would make every grep find nothing and yield a misleading
    # all-PASS report. Pipe a known bare-code token through and assert it survives
    # the cleaning pass (it is neither a string literal nor a comment).
    local probe
    probe="$(printf 'MeticaSdk.Initialize(config);\n' | awk -f "$CLEAN_CS_AWK" 2>/dev/null)" || return 1
    case "$probe" in
        *"MeticaSdk.Initialize(config)"*) ;;   # token survived → accessor is live
        *) return 1 ;;
    esac
    # And the inverse: a token that lives ONLY inside a comment must be stripped,
    # so a no-op accessor (passes everything through unchanged) is also rejected.
    local probe_comment
    probe_comment="$(printf '// MeticaSdk.Initialize(commented);\n' | awk -f "$CLEAN_CS_AWK" 2>/dev/null)" || return 1
    case "$probe_comment" in
        *"MeticaSdk.Initialize"*) return 1 ;;   # comment NOT stripped → accessor is broken
    esac
    return 0
}

fi
