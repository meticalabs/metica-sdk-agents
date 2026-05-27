# strip-comments.awk — remove C# line (// …) and block (/* … */) comments while
# PRESERVING string literals verbatim: regular "…", verbatim @"…" / $@"…", and
# interpolated $"…". Line numbers are preserved (one output line per input line).
#
# Use this when a check must still see literal string VALUES (credential keys,
# constructor arguments) but must ignore matches that live inside comments.
# clean-cs.awk blanks strings too, which would hide those values; this is its
# comment-only counterpart.
#
# Usage: awk -f strip-comments.awk <file>

BEGIN {
    in_block    = 0    # inside /* ... */
    in_verbatim = 0    # inside @"..." (or $@"...") spanning lines
}

{
    out = ""; n = length($0); i = 1

    # Continue a verbatim string opened on a previous line (contents preserved).
    if (in_verbatim) {
        while (i <= n) {
            c = substr($0, i, 1)
            if (c == "\"") {
                if (substr($0, i+1, 1) == "\"") { out = out "\"\""; i += 2; continue }  # "" escape
                out = out "\""; i++; in_verbatim = 0; break
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

        # Verbatim string: @"..." or $@"..." or @$"..."
        if (c == "@" && substr($0, i+1, 1) == "\"") {
            out = out "@\""; i += 2; in_verbatim = 1
            while (i <= n) {
                cc = substr($0, i, 1)
                if (cc == "\"") {
                    if (substr($0, i+1, 1) == "\"") { out = out "\"\""; i += 2; continue }
                    out = out "\""; i++; in_verbatim = 0; break
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
                    if (substr($0, i+1, 1) == "\"") { out = out "\"\""; i += 2; continue }
                    out = out "\""; i++; in_verbatim = 0; break
                }
                out = out cc; i++
            }
            continue
        }

        # Comments (only recognised outside strings).
        if (c == "/" && substr($0, i+1, 1) == "/") break
        if (c == "/" && substr($0, i+1, 1) == "*") { in_block = 1; i += 2; continue }

        # Regular string (also handles interpolated $"..."), copied verbatim.
        if (c == "\"") {
            out = out "\""; i++
            while (i <= n) {
                cc = substr($0, i, 1)
                if (cc == "\\") { out = out cc substr($0, i+1, 1); i += 2; continue }  # \ escape
                if (cc == "\"") { out = out "\""; i++; break }
                out = out cc; i++
            }
            continue
        }

        out = out c; i++
    }
    print out
}
