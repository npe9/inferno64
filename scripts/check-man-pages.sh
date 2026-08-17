#!/usr/bin/env bash
# check-man-pages.sh — ensure newly-added programs have man pages.
#
# Usage:
#   scripts/check-man-pages.sh [base-ref]
#
# base-ref defaults to origin/main.  The script finds every .b source
# file added in the diff between base-ref and HEAD, maps its basename
# to the documented program names extracted from ALL man pages' NAME
# sections (which may cover multiple programs per page), and fails if
# any new program is not mentioned anywhere.
#
# Exempt paths (covered by a group page or not user-invokable):
#   appl/temple/*  — bulk demo ports covered by temple(1)

set -euo pipefail

BASE="${1:-origin/main}"

cd "$(dirname "$0")/.."

# ---------------------------------------------------------------------------
# Build the set of documented program names by parsing every man page's
# NAME section.  The NAME line looks like:
#   prog1, prog2 \- short description
# We extract everything before the \- delimiter and split on commas/spaces.
# ---------------------------------------------------------------------------
build_documented() {
    find man -type f ! -name 'INDEX' ! -name '0intro' \
    | sort \
    | xargs awk '
        /^\.SH[[:space:]]+NAME/ { in_name=1; next }
        /^\.SH/ && in_name      { in_name=0 }
        in_name && /\\-/ {
            n = $0
            sub(/\\-.*/,"",n)
            gsub(/\.[A-Z].*/,"",n)
            gsub(/[,[:space:]]+/,"\n",n)
            print n
        }
    ' \
    | grep -v '^$' \
    | sort -u
}

# ---------------------------------------------------------------------------
# Find .b files added (status A) in this branch relative to base.
# ---------------------------------------------------------------------------
mapfile -t ADDED < <(
    git diff --name-status "$BASE"...HEAD 2>/dev/null \
        | awk '$1 == "A" { print $2 }' \
        | grep '\.b$' \
        | sort -u
)

if [[ ${#ADDED[@]} -eq 0 ]]; then
    echo "No new .b files relative to $BASE — man page check skipped."
    exit 0
fi

# Directories whose programs must be documented.
CHECKED_DIRS=(appl/wm appl/cmd appl/lib)

errors=0

mapfile -t DOCUMENTED < <(build_documented)
declare -A DOC_SET
for name in "${DOCUMENTED[@]}"; do
    DOC_SET["$name"]=1
done

for file in "${ADDED[@]}"; do
    # Only check the declared directories.
    matched=0
    for dir in "${CHECKED_DIRS[@]}"; do
        [[ "$file" == "$dir"/* ]] && { matched=1; break; }
    done
    [[ $matched -eq 0 ]] && continue

    # appl/temple/* is exempt — covered by the temple(1) group page.
    [[ "$file" == appl/temple/* ]] && continue

    prog="$(basename "$file" .b)"

    if [[ -z "${DOC_SET[$prog]+x}" ]]; then
        echo "MISSING MAN PAGE: $file  (program name '$prog' not found in any NAME section)" >&2
        errors=1
    fi
done

if [[ $errors -ne 0 ]]; then
    cat >&2 <<'MSG'

Each new program in appl/wm/, appl/cmd/, or appl/lib/ needs to be
listed in the NAME section of a man page (any section).  A single page
can cover multiple programs — see man/1/wm-misc for an example.

Temple demo programs (appl/temple/*) are exempt: they are covered by
the temple(1) overview page.
MSG
    exit 1
fi

echo "Man page check passed (${#ADDED[@]} new file(s) checked)."

