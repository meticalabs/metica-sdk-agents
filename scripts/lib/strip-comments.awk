# strip-comments.awk — strip C# line comments (// …) and block comments
# (/* … */) from a source file while PRESERVING string literal contents.
# Line numbers are preserved (one output line per input line, possibly empty).
# Block comments AND verbatim string literals are tracked across lines.
#
# Companion to clean-cs.awk: clean-cs.awk also strips strings (for token
# detection that should ignore matches inside literals). strip-comments.awk
# is used when you need to *read* the string contents — e.g. checking whether
# the userId argument of MeticaInitConfig("k","a","test") is a test value, or
# whether a YOUR_METICA_API_KEY placeholder leaked into production code.
#
# Usage: awk -f strip-comments.awk <file>

BEGIN {
    in_block    = 0     # inside /* ... */
    in_verbatim = 0     # inside @"..." that opened on a previous line
}

{
    out = ""; n = length($0); i = 1

    # Continue consuming a verbatim string that began on a previous line.
    # Contents stay in the output (this awk preserves string text).
    if (in_verbatim) {
        while (i <= n) {
            c = substr($0, i, 1)
            if (c == "\"") {
                if (substr($0, i+1, 1) == "\"") {
                    out = out "\"\""; i += 2; continue
                }
                out = out c; i++; in_verbatim = 0; break
            }
            out = out c; i++
        }
    }

    while (i <= n) {
        c = substr($0, i, 1)

        if (in_block) {
            if (c == "*" && substr($0, i+1, 1) == "/") { in_block = 0; i += 2 }
            else i++
            continue
        }

        # Verbatim string: @"..." or $@"..." or @$"..." — body preserved.
        # Sets in_verbatim if the literal does not close on this line, so the
        # parser keeps consuming on subsequent lines.
        if (c == "@" && substr($0, i+1, 1) == "\"") {
            out = out "@\""; i += 2; in_verbatim = 1
            while (i <= n) {
                cc = substr($0, i, 1)
                if (cc == "\"") {
                    if (substr($0, i+1, 1) == "\"") {
                        out = out "\"\""; i += 2; continue
                    }
                    out = out cc; i++; in_verbatim = 0; break
                }
                out = out cc; i++
            }
            continue
        }
        if (c == "$" && substr($0, i+1, 1) == "@" && substr($0, i+2, 1) == "\"") {
            out = out "$@\""; i += 3; in_verbatim = 1
            while (i <= n) {
                cc = substr($0, i, 1)
                if (cc == "\"") {
                    if (substr($0, i+1, 1) == "\"") {
                        out = out "\"\""; i += 2; continue
                    }
                    out = out cc; i++; in_verbatim = 0; break
                }
                out = out cc; i++
            }
            continue
        }
        if (c == "@" && substr($0, i+1, 1) == "$" && substr($0, i+2, 1) == "\"") {
            out = out "@$\""; i += 3; in_verbatim = 1
            while (i <= n) {
                cc = substr($0, i, 1)
                if (cc == "\"") {
                    if (substr($0, i+1, 1) == "\"") {
                        out = out "\"\""; i += 2; continue
                    }
                    out = out cc; i++; in_verbatim = 0; break
                }
                out = out cc; i++
            }
            continue
        }

        # Char literal: '?' where ? is one char or \-escape sequence. We have to
        # match this BEFORE the string-literal branch so a char like '"' or '\''
        # does not pull the parser into string-mode by accident. Emit verbatim.
        if (c == "'") {
            out = out c; i++
            if (i <= n && substr($0, i, 1) == "\\") {
                # \" \\ \' \n \t \uXXXX etc. — copy the backslash + the rest of
                # the escape up to (and including) the closing quote.
                out = out substr($0, i, 1); i++
                # Unicode escape \uXXXX or \xXXXXXXXX — copy the hex digits.
                if (i <= n && (substr($0, i, 1) == "u" || substr($0, i, 1) == "x" \
                            || substr($0, i, 1) == "U")) {
                    out = out substr($0, i, 1); i++
                    while (i <= n && substr($0, i, 1) ~ /[0-9A-Fa-f]/) {
                        out = out substr($0, i, 1); i++
                    }
                } else if (i <= n) {
                    # single escaped char: \" \\ \n \t etc.
                    out = out substr($0, i, 1); i++
                }
            } else if (i <= n) {
                # single non-escape char (incl. ")
                out = out substr($0, i, 1); i++
            }
            # closing '
            if (i <= n && substr($0, i, 1) == "'") {
                out = out "'"; i++
            }
            continue
        }

        # Line / block comment start
        if (c == "/" && substr($0, i+1, 1) == "/") break
        if (c == "/" && substr($0, i+1, 1) == "*") { in_block = 1; i += 2; continue }

        # Regular string literal (also handles $"..." interpolated) — copy
        # contents verbatim; close at first non-escaped ".
        if (c == "\"") {
            out = out c; i++
            while (i <= n) {
                cc = substr($0, i, 1)
                if (cc == "\\") {
                    # consume \ + next char as a unit
                    out = out cc
                    if (i+1 <= n) { out = out substr($0, i+1, 1) }
                    i += 2; continue
                }
                if (cc == "\"") { out = out cc; i++; break }
                out = out cc; i++
            }
            continue
        }

        out = out c
        i++
    }
    print out
}
