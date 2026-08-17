#!/bin/sh
# gen-0intro — regenerate man/1/0intro from the section 1 man pages.
#
# Usage (from repo root):
#   sh scripts/gen-0intro.sh > man/1/0intro
#
# The output is a troff -man page with the Inferno introduction prose
# followed by an alphabetical index of all section 1 commands with
# one-line descriptions extracted from their NAME sections.
#
# This script uses only POSIX sh, sed, sort, and awk — no Python.

cd "$(dirname "$0")/.." || exit 1

# Emit the header and prose introduction.
cat man/1/intro

# Emit the Commands index heading.
cat <<'TROFF'
.SS Commands
.TP 5
TROFF

# For each man/1 page (excluding 0intro itself and INDEX),
# extract the NAME section and emit .TP entries.
#
# NAME section format:
#   name1, name2 \- one-line description
#
# We want one .TP block per page, listing the first name as the
# cross-reference and the description as the body.
awk '
BEGIN { in_name = 0; page = ""; names = ""; desc = "" }

FNR == 1 {
    if (page != "" && names != "" && desc != "")
        print names "\t" desc
    page = FILENAME
    sub(".*/", "", page)
    in_name = 0
    names = ""
    desc = ""
}

/^\.SH[[:space:]]+NAME/ { in_name = 1; next }
/^\.SH/ && in_name    { in_name = 0 }

in_name {
    line = $0
    if (line ~ /^\./)
        next
    if (line ~ /\\-/) {
        split(line, a, /\\-/)
        n = a[1]
        d = a[2]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", n)
        sub(/[,[:space:]].*/, "", n)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", d)
        if (n != "" && d != "") {
            names = n
            desc = d
        }
    }
}

END {
    if (page != "" && names != "" && desc != "")
        print names "\t" desc
}
' $(find man/1 -maxdepth 1 -type f ! -name '0intro' ! -name 'INDEX' | sort) \
| sort -f \
| awk -F'\t' '{
    d = $2
    if (length(d) > 64) d = substr(d, 1, 61) "..."
    print ".TP"
    print ".IR " $1 " (1)"
    print d
}'
