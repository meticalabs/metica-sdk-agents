# extract-init-arg.awk — print the WANT-th (1-based) top-level argument of the
# first `MARKER...)` call in the input, joined to one line and trimmed.
#
# Respects C# string literals — regular "..." (with \" escapes), verbatim @"..."
# (with "" escapes), and the $ prefix on interpolated strings — so commas and
# parens inside string literals do NOT split arguments, and the call may span
# multiple lines. Nested ()/[]/{} are tracked so commas inside them don't split.
#
# Usage: awk -v WANT=3 -f extract-init-arg.awk file.cs
#        (override the call prefix with -v MARKER='new Foo(')
#
# Limitation: braces inside interpolated strings ($"...{a,b}...") are not parsed
# specially; a comma inside an interpolation hole could mis-split. Rare for the
# arguments this is used on (SDK keys / user IDs).

BEGIN { if (MARKER == "") MARKER = "new MeticaInitConfig(" }
{ doc = doc $0 "\n" }
END {
    p = index(doc, MARKER)
    if (p == 0) exit
    i = p + length(MARKER)        # first char inside the opening paren
    n = length(doc)
    depth = 1                     # we are already inside MARKER's paren
    argn = 1
    arg = ""
    in_str = 0                    # inside a regular "..." string
    in_verb = 0                   # inside a verbatim @"..." string
    while (i <= n && depth > 0) {
        c = substr(doc, i, 1)
        d = (i < n) ? substr(doc, i + 1, 1) : ""
        if (in_verb) {
            if (c == "\"" && d == "\"") { arg = arg c d; i += 2; continue }  # "" escape
            if (c == "\"") { in_verb = 0; arg = arg c; i++; continue }
            arg = arg c; i++; continue
        }
        if (in_str) {
            if (c == "\\") { arg = arg c d; i += 2; continue }               # \ escape
            if (c == "\"") { in_str = 0; arg = arg c; i++; continue }
            arg = arg c; i++; continue
        }
        if (c == "@" && d == "\"") { in_verb = 1; arg = arg c d; i += 2; continue }
        if (c == "\"") { in_str = 1; arg = arg c; i++; continue }
        if (c == "(" || c == "[" || c == "{") { depth++; arg = arg c; i++; continue }
        if (c == ")" || c == "]" || c == "}") {
            depth--
            if (depth == 0) break                                           # end of MARKER call
            arg = arg c; i++; continue
        }
        if (c == "," && depth == 1) { args[argn++] = arg; arg = ""; i++; continue }
        arg = arg c; i++
    }
    args[argn] = arg
    val = args[WANT + 0]
    gsub(/^[[:space:]]+/, "", val)
    gsub(/[[:space:]]+$/, "", val)
    print val
}
