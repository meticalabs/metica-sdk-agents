# strip-comments.awk — strip C# line comments (// …) and block comments
# (/* … */) from a source file while PRESERVING string literal contents.
# Line numbers are preserved (one output line per input line, possibly empty).
#
# Companion to clean-cs.awk: clean-cs.awk also strips strings (for token
# detection that should ignore matches inside literals). strip-comments.awk
# is used when you need to *read* the string contents — e.g. checking whether
# the userId argument of MeticaInitConfig("k","a","test") is a test value, or
# whether a YOUR_METICA_API_KEY placeholder leaked into production code.
#
# Usage: awk -f strip-comments.awk <file>

BEGIN { in_block = 0 }

{
    out = ""; n = length($0); i = 1

    while (i <= n) {
        c = substr($0, i, 1)

        if (in_block) {
            if (c == "*" && substr($0, i+1, 1) == "/") { in_block = 0; i += 2 }
            else i++
            continue
        }

        # Line / block comment start
        if (c == "/" && substr($0, i+1, 1) == "/") break
        if (c == "/" && substr($0, i+1, 1) == "*") { in_block = 1; i += 2; continue }

        # String literal — copy contents verbatim (handles regular, verbatim @"…",
        # and interpolated $"…" by treating " as the delimiter and \" as escape).
        if (c == "\"") {
            out = out c; i++
            # Detect verbatim by looking back: if previous char was @, treat "" as escape.
            verbatim = (i >= 3 && substr($0, i-2, 1) == "@")
            while (i <= n) {
                cc = substr($0, i, 1)
                if (verbatim) {
                    if (cc == "\"") {
                        if (substr($0, i+1, 1) == "\"") { out = out "\"\""; i += 2; continue }
                        out = out cc; i++; break
                    }
                    out = out cc; i++
                } else {
                    if (cc == "\\") {
                        out = out cc substr($0, i+1, 1); i += 2; continue
                    }
                    if (cc == "\"") { out = out cc; i++; break }
                    out = out cc; i++
                }
            }
            continue
        }

        out = out c
        i++
    }
    print out
}
