#!/bin/sh
# Create the directories lib/emptydirs lists.
#
# git cannot track an empty directory, so this tree keeps a manifest of
# the ones the system expects -- mount points, mostly -- in
# lib/emptydirs.  Nothing applied it: 61 of the 303 listed were missing,
# including /mnt/registry, which is the mount point registry(4)'s own
# manual page uses in its only example.  "mount {ndb/registry}
# /mnt/registry" fails with "does not exist", which reads as a broken
# service rather than a missing directory.
#
# Idempotent; prints what it created and nothing when there is nothing
# to do.
#
# usage: scripts/mkemptydirs.sh [-n]      -n: say what is missing, create nothing
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
dryrun=
[ "$1" = -n ] && dryrun=1

n=0
while read d; do
	case "$d" in
	''|'#'*) continue;;
	esac
	if [ ! -d "$ROOT/$d" ]; then
		n=`expr $n + 1`
		if [ -n "$dryrun" ]; then
			echo "missing: $d"
		else
			mkdir -p "$ROOT/$d"
			echo "created: $d"
		fi
	fi
done < "$ROOT/lib/emptydirs"
[ $n -eq 0 ] && exit 0
if [ -n "$dryrun" ]; then
	echo "$n of the directories in lib/emptydirs are absent"
else
	echo "created $n directories from lib/emptydirs"
fi
exit 0
