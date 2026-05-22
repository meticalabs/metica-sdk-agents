#!/bin/bash
# format-compat-report.sh — render compat-checker/1.0.0 JSON as a human summary.
# Reads JSON from stdin, writes the summary to stdout.
#
# Pure POSIX awk; same dependency profile as detect-compat.sh.

awk '
BEGIN {
    labels["unity"]             = "Unity"
    labels["java"]              = "Java"
    labels["max"]               = "MaxSDK"
    labels["android_api"]       = "Android API"
    labels["gradle"]            = "Gradle"
    labels["scripting_backend"] = "Backend"
}

/"target_sdk":/ { target_sdk = extract($0, "\"target_sdk\":") }
/"status":/     { status      = extract($0, "\"status\":")     }
/"error":/      { error_msg   = extract($0, "\"error\":")      }
/"id":/ {
    n++
    ids[n]      = extract($0, "\"id\":")
    detected[n] = extract($0, "\"detected\":")
    levels[n]   = extract($0, "\"level\":")
    hints[n]    = extract($0, "\"hint\":")
}

END {
    if (target_sdk == "") target_sdk = "?"
    printf "COMPAT REPORT — target MeticaSDK %s\n", target_sdk
    for (i = 1; i <= n; i++) {
        label = labels[ids[i]]; if (label == "") label = ids[i]
        det   = detected[i];    if (det == "")   det   = "n/a"
        # Truncate very long values so the [LEVEL] column stays aligned.
        if (length(det) > 22) det = substr(det, 1, 21) ">"
        if (levels[i] != "PASS" && hints[i] != "")
            printf "  %-13s %-22s [%-7s] %s\n", label, det, levels[i], hints[i]
        else
            printf "  %-13s %-22s [%-7s]\n",    label, det, levels[i]
    }
    print  "----"
    printf "Overall: %s\n", status
    if (error_msg != "") printf "Error: %s\n", error_msg
}

function extract(line, key,    pos, s, c, out, i, n, esc) {
    # Extract a JSON string or null value following <key> in <line>.
    # Walks chars to honor \" \\ escapes; returns "" for null.
    pos = index(line, key)
    if (pos == 0) return ""
    s = substr(line, pos + length(key))
    sub(/^[[:space:]]*/, "", s)
    if (substr(s, 1, 4) == "null") return ""
    if (substr(s, 1, 1) != "\"") return ""
    n = length(s); out = ""; esc = 0
    for (i = 2; i <= n; i++) {
        c = substr(s, i, 1)
        if (esc) {
            if      (c == "n")  out = out "\n"
            else if (c == "t")  out = out "\t"
            else                out = out c
            esc = 0
        } else if (c == "\\") {
            esc = 1
        } else if (c == "\"") {
            return out
        } else {
            out = out c
        }
    }
    return out
}
'
