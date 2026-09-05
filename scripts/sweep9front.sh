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
# A directory whose mkfile has no install rule is counted apart from
# both.  cmd/test is one: it is a suite of tests to run, installs
# nothing, and the cmd mkfile leaves it out of its own DIRS for that
# reason (NOMK).  Calling that a failure would be wrong, and skipping
# it by name would hide the next such directory, so it is recognised
# by what mk says.
#
# Failures are tried once more after the sweep has been round once.
# A few directories build a library where they sit rather than
# installing it -- bzip2's libbzip2 is the one this tree has -- and a
# directory that links it fails on name order alone if it comes
# first, which bzfs does.  A second pass costs a rebuild of what
# failed and nothing else, and it tells the ordering failures apart
# from the real ones without anybody having to know which is which.
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
none=0
: > "$out/failed"
: > "$out/ok"
: > "$out/noinstall"
: > "$out/ordering"

# the single-file programs the cmd mkfile builds itself, then every
# directory under it
for d in . $dirs; do
	name=$(echo "$d" | tr / _)
	if bash "$ROOT/scripts/mk9front.sh" -o "$objtype" "9front-src/sys/src/cmd/$d" install \
			> "$out/$name.log" 2>&1; then
		ok=$((ok + 1))
		echo "$d" >> "$out/ok"
	elif grep -q "^mk: don't know how to make 'install'\$" "$out/$name.log"; then
		none=$((none + 1))
		echo "$d" >> "$out/noinstall"
	else
		bad=$((bad + 1))
		echo "$d" >> "$out/failed"
	fi
done

#
# the second pass: whatever failed, once more, now that everything
# that does build has been built
#
if [ "$bad" -gt 0 ]; then
	mv "$out/failed" "$out/failed.1"
	: > "$out/failed"
	bad=0
	while read -r d; do
		name=$(echo "$d" | tr / _)
		if bash "$ROOT/scripts/mk9front.sh" -o "$objtype" "9front-src/sys/src/cmd/$d" install \
				> "$out/$name.log" 2>&1; then
			ok=$((ok + 1))
			echo "$d" >> "$out/ok"
			echo "$d" >> "$out/ordering"
		else
			bad=$((bad + 1))
			echo "$d" >> "$out/failed"
		fi
	done < "$out/failed.1"
fi

echo
echo "directories built: $ok  failed: $bad  nothing to install: $none"
echo "programs installed: $(find "$ROOT/9front/$objtype/bin" -type f | wc -l | tr -d ' ')"
echo
if [ -s "$out/ordering" ]; then
	echo "built only on the second pass, so they failed on order alone:"
	while read -r d; do printf '\t%s\n' "$d"; done < "$out/ordering"
	echo
fi
if [ "$none" -gt 0 ]; then
	echo "nothing to install:"
	while read -r d; do printf '\t%s\n' "$d"; done < "$out/noinstall"
	echo
fi
if [ "$bad" -gt 0 ]; then
	echo "failures:"
	while read -r d; do
		name=$(echo "$d" | tr / _)
		first=$(grep -E '^mk: |error:|cannot open|No such file' "$out/$name.log" 2>/dev/null | tail -1 | cut -c1-100)
		printf '\t%-16s %s\n' "$d" "$first"
	done < "$out/failed"
fi
