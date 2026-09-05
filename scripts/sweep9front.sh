#!/usr/bin/env bash
#
# sweep9front.sh -- build every 9front command directory on its own
# and say which ones came out.
#
# "mk install" in sys/src/cmd stops at the first directory that fails,
# so it answers "does everything build" and nothing else.  This builds
# each directory separately and keeps going, which answers the
# question worth asking while the port is unfinished: how much of the
# userland is there, and what exactly is missing.
#
# Each directory's output goes to a log under the sweep directory, and
# the summary lists the failures with the first error line from each.
#
# Usage: scripts/sweep9front.sh [-o objtype] [sweep-directory]
# Default sweep directory: 9front/sweep.

set -eu

cd "$(dirname "$0")/.."
ROOT=$PWD

objtype=amd64
if [ "${1:-}" = "-o" ]; then objtype=$2; shift 2; fi
out=${1:-$ROOT/9front/sweep}
mkdir -p "$out"

src=$ROOT/9front-src/sys/src/cmd
dirs=$(cd "$src" && for d in */; do [ -f "$d/mkfile" ] && echo "${d%/}"; done)

ok=0
bad=0
: > "$out/failed"
: > "$out/ok"

# the single-file programs the cmd mkfile builds itself, then every
# directory under it
for d in . $dirs; do
	name=$(echo "$d" | tr / _)
	if bash "$ROOT/scripts/mk9front.sh" -o "$objtype" "9front-src/sys/src/cmd/$d" install \
			> "$out/$name.log" 2>&1; then
		ok=$((ok + 1))
		echo "$d" >> "$out/ok"
	else
		bad=$((bad + 1))
		echo "$d" >> "$out/failed"
	fi
done

echo
echo "directories built: $ok  failed: $bad"
echo "programs installed: $(find "$ROOT/9front/$objtype/bin" -type f | wc -l | tr -d ' ')"
echo
if [ "$bad" -gt 0 ]; then
	echo "failures:"
	while read -r d; do
		name=$(echo "$d" | tr / _)
		first=$(grep -E '^mk: |error:|cannot open|No such file' "$out/$name.log" 2>/dev/null | tail -1 | cut -c1-100)
		printf '\t%-16s %s\n' "$d" "$first"
	done < "$out/failed"
fi
