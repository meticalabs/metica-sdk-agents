# check-init-userid.awk — locate every MeticaInitConfig(...) constructor call
# in a C# source and flag any whose 3rd positional argument (userId) is a
# null / empty / test / debug / dummy / placeholder / digits-only literal.
#
# Handles multi-line constructor calls by accumulating until the matching ')'.
# Does NOT cover the object-initializer form (`new MeticaInitConfig { UserId = ... }`)
# — that's a documented limitation; the integrator emits the positional form.
#
# Each emitted line is TAB-separated (so file paths containing ':' do not
# corrupt downstream parsing):
#   <FNAME>\t<start_line>\t<reason>\t<arg_value>
# reason ∈ {null, empty, test-value, digits-only}. Empty output = no problems.
#
# Input MUST be the source AFTER strip-comments.awk so commented-out test
# values do not trigger false positives. Caller passes the original filename
# via -v FNAME=… because the awk reads from stdin.
#
# Usage: awk -f strip-comments.awk file.cs | awk -v FNAME=file.cs -f check-init-userid.awk

BEGIN { collecting = 0; depth = 0; buf = ""; start_line = 0; coll_in_str = 0 }

function trim(s) {
    sub(/^[[:space:]]+/, "", s)
    sub(/[[:space:]]+$/, "", s)
    return s
}

function flag(arg, line,    a) {
    a = trim(arg)
    if (a == "null") {
        printf "%s\t%d\tnull\tnull\n", FNAME, line
    } else if (a == "\"\"") {
        printf "%s\t%d\tempty\t\"\"\n", FNAME, line
    } else if (a ~ /^"(.*[-_])?([Tt][Ee][Ss][Tt]|[Dd][Ee][Bb][Uu][Gg]|[Dd][Uu][Mm][Mm][Yy]|[Pp][Ll][Aa][Cc][Ee][Hh][Oo][Ll][Dd][Ee][Rr])([-_].*)?"$/) {
        # 'test'/'debug'/'dummy'/'placeholder' as a standalone word — bounded by
        # the surrounding quotes or by - / _ separators. Avoids false positives
        # on legitimate ids like "contest-user-42" or "latest-build".
        printf "%s\t%d\ttest-value\t%s\n", FNAME, line, a
    } else if (a ~ /^"[0-9]+"$/) {
        printf "%s\t%d\tdigits-only\t%s\n", FNAME, line, a
    }
}

# Split the captured arg-list on top-level commas (respect nested parens and
# string literals). Flag the 3rd arg if it looks like a test value.
function parse_args(s,    j, ch, d, in_str, n, args) {
    n = 1
    args[1] = ""
    d = 0
    in_str = 0
    for (j = 1; j <= length(s); j++) {
        ch = substr(s, j, 1)
        if (in_str) {
            args[n] = args[n] ch
            if (ch == "\\") {
                # consume escaped char (\\, \", etc.)
                args[n] = args[n] substr(s, j+1, 1)
                j++
            } else if (ch == "\"") {
                # C# verbatim "" escape: a doubled quote inside a verbatim
                # string stays in-string. We don't distinguish verbatim from
                # regular here because the outer collector strips the leading
                # @, so verbatim "" can appear at this layer too.
                if (substr(s, j+1, 1) == "\"") {
                    args[n] = args[n] "\""
                    j++
                } else {
                    in_str = 0
                }
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

# Identifier-boundary check: the char preceding the M of MeticaInitConfig must
# not be an identifier char ([A-Za-z0-9_]) — otherwise we'd match wrappers like
# OtherMeticaInitConfig(.
function is_identifier_start(line, p,    prev) {
    if (p <= 1) return 1
    prev = substr(line, p - 1, 1)
    return (prev !~ /[A-Za-z0-9_]/)
}

{
    pos = 1
    while (pos <= length($0)) {
        if (!collecting) {
            rest = substr($0, pos)
            idx = index(rest, "MeticaInitConfig(")
            if (idx == 0) break
            # absolute column where the 'M' starts in the original line
            mpos = pos + idx - 1
            if (!is_identifier_start($0, mpos)) {
                # advance past this hit and keep looking
                pos = mpos + 1
                continue
            }
            pos = mpos + length("MeticaInitConfig(")
            collecting = 1
            depth = 1
            buf = ""
            coll_in_str = 0
            start_line = NR
        } else {
            c = substr($0, pos, 1)
            pos++
            if (coll_in_str) {
                buf = buf c
                if (c == "\\") {
                    # consume the escaped character (\\, \", etc.)
                    buf = buf substr($0, pos, 1)
                    pos++
                } else if (c == "\"") {
                    # C# verbatim doubled "" → stay in string
                    if (substr($0, pos, 1) == "\"") {
                        buf = buf "\""
                        pos++
                    } else {
                        coll_in_str = 0
                    }
                }
            } else if (c == "\"") {
                coll_in_str = 1
                buf = buf c
            } else if (c == "(") {
                depth++; buf = buf c
            } else if (c == ")") {
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
