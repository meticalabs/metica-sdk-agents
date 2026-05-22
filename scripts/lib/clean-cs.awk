# clean-cs.awk — strip C# strings (regular, verbatim @"…", interpolated $"…"),
# line comments (// …), and block comments (/* … */) from a source file.
# Line numbers are preserved (one output line per input line, possibly empty).
# Block comments and verbatim strings are tracked across lines.
#
# Usage: awk -f clean-cs.awk <file>

BEGIN {
    in_block    = 0    # inside /* ... */
    in_verbatim = 0    # inside @"..." (or $@"...")
}

{
    out = ""; n = length($0); i = 1

    # Continue consuming a verbatim string that began on a previous line.
    if (in_verbatim) {
        while (i <= n) {
            c = substr($0, i, 1)
            if (c == "\"") {
                if (substr($0, i+1, 1) == "\"") { i += 2; continue }   # escaped ""
                i++; in_verbatim = 0; break
            }
            i++
        }
        # If still in_verbatim, the whole line was inside the string → emit blank line.
    }

    while (i <= n) {
        c = substr($0, i, 1)

        if (in_block) {
            if (c == "*" && substr($0, i+1, 1) == "/") { in_block = 0; i += 2 }
            else i++
            continue
        }

        # Verbatim string: @"..." or $@"..." or @$"..."
        if (c == "@" && substr($0, i+1, 1) == "\"") {
            i += 2; in_verbatim = 1
            while (i <= n) {
                cc = substr($0, i, 1)
                if (cc == "\"") {
                    if (substr($0, i+1, 1) == "\"") { i += 2; continue }
                    i++; in_verbatim = 0; break
                }
                i++
            }
            continue
        }
        if (c == "$" && substr($0, i+1, 1) == "@" && substr($0, i+2, 1) == "\"") {
            i += 3; in_verbatim = 1
            while (i <= n) {
                cc = substr($0, i, 1)
                if (cc == "\"") {
                    if (substr($0, i+1, 1) == "\"") { i += 2; continue }
                    i++; in_verbatim = 0; break
                }
                i++
            }
            continue
        }

        # Line / block comment
        if (c == "/" && substr($0, i+1, 1) == "/") break
        if (c == "/" && substr($0, i+1, 1) == "*") { in_block = 1; i += 2; continue }

        # Regular string (also handles $"..." interpolated)
        if (c == "\"") {
            i++
            while (i <= n) {
                cc = substr($0, i, 1)
                if (cc == "\\") { i += 2; continue }
                if (cc == "\"") { i++; break }
                i++
            }
            continue
        }

        out = out c
        i++
    }
    print out
}
