# check-init-userid.awk — locate every MeticaInitConfig(...) constructor call
# in a C# source and flag any whose 3rd positional argument (userId) is a
# null / empty / test / debug / dummy / placeholder / digits-only literal.
#
# Handles multi-line constructor calls by accumulating until the matching ')'.
# Does NOT cover the object-initializer form (`new MeticaInitConfig { UserId = ... }`)
# — that's a documented limitation; the integrator emits the positional form.
#
# Each emitted line:
#   <FNAME>:<start_line>:<reason>:<arg_value>
# reason ∈ {null, empty, test-value, digits-only}. Empty output = no problems.
#
# Input MUST be the source AFTER strip-comments.awk so commented-out test
# values do not trigger false positives. Caller passes the original filename
# via -v FNAME=… because the awk reads from stdin.
#
# Usage: awk -f strip-comments.awk file.cs | awk -v FNAME=file.cs -f check-init-userid.awk

BEGIN { collecting = 0; depth = 0; buf = ""; start_line = 0 }

function trim(s) {
    sub(/^[[:space:]]+/, "", s)
    sub(/[[:space:]]+$/, "", s)
    return s
}

function flag(arg, line,    a) {
    a = trim(arg)
    if (a == "null") {
        printf "%s:%d:null:null\n", FNAME, line
    } else if (a == "\"\"") {
        printf "%s:%d:empty:\"\"\n", FNAME, line
    } else if (a ~ /^"[^"]*([Tt][Ee][Ss][Tt]|[Dd][Ee][Bb][Uu][Gg]|[Dd][Uu][Mm][Mm][Yy]|[Pp][Ll][Aa][Cc][Ee][Hh][Oo][Ll][Dd][Ee][Rr])[^"]*"$/) {
        printf "%s:%d:test-value:%s\n", FNAME, line, a
    } else if (a ~ /^"[0-9]+"$/) {
        printf "%s:%d:digits-only:%s\n", FNAME, line, a
    }
}

# Split the captured arg-list on top-level commas (respect nested parens and
# string literals). Flag the 3rd arg if it looks like a test value.
function parse_args(s,    j, ch, d, in_str, n, args, prev) {
    n = 1
    args[1] = ""
    d = 0
    in_str = 0
    prev = ""
    for (j = 1; j <= length(s); j++) {
        ch = substr(s, j, 1)
        if (in_str) {
            args[n] = args[n] ch
            if (ch == "\\") {
                # consume escaped char
                args[n] = args[n] substr(s, j+1, 1)
                j++
            } else if (ch == "\"") {
                in_str = 0
            }
        } else if (ch == "\"") {
            args[n] = args[n] ch
            in_str = 1
        } else if (ch == "(") {
            d++; args[n] = args[n] ch
        } else if (ch == ")") {
            d--; args[n] = args[n] ch
        } else if (ch == "," && d == 0) {
            n++; args[n] = ""
        } else {
            args[n] = args[n] ch
        }
    }
    if (n >= 3) flag(args[3], start_line)
}

{
    pos = 1
    while (pos <= length($0)) {
        if (!collecting) {
            rest = substr($0, pos)
            idx = index(rest, "MeticaInitConfig(")
            if (idx == 0) break
            pos = pos + idx + length("MeticaInitConfig(") - 1
            collecting = 1
            depth = 1
            buf = ""
            start_line = NR
        } else {
            c = substr($0, pos, 1)
            pos++
            if (c == "(") { depth++; buf = buf c }
            else if (c == ")") {
                depth--
                if (depth == 0) {
                    parse_args(buf)
                    collecting = 0
                    buf = ""
                } else { buf = buf c }
            } else {
                buf = buf c
            }
        }
    }
    if (collecting) buf = buf " "  # newline → space when accumulating across lines
}
