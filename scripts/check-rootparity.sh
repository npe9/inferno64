#!/bin/sh
# Everything in virtarm64's root is in virtarm64cloud's root.
#
# One board, two configuration files.  They are genuinely different
# products -- virtarm64 has the draw stack and screenarm, virtarm64cloud
# has ethergve, screennone and the cloud userland -- so they are not
# collapsible.  But the cloud one is a superset of the other's root, and
# it has twice been made not to be:
#
#   chantest went into virtarm64's root and not the cloud one, so an
#   arm64 measurement on a rented t2a printed "sh: chantest: file does
#   not exist" three times a cycle for ten minutes and measured shell
#   invocations instead of channel traffic;
#
#   and the same shape, one configuration gaining something the other
#   did not, put the fw_cfg reader inside screenarm.c and stopped the
#   cloud kernel linking at all.
#
# Neither is visible until something is rented.  The subset relation is
# checkable in a second, so it is checked here.
#
# Extras in the cloud root are the point of it and are reported, not
# failed.  An entry that is deliberately in virtarm64 alone goes in
# ONLY-PLAIN below, with a reason.
#
# usage: scripts/check-rootparity.sh
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
DIR=$ROOT/os/inferno/virtarm64
PLAIN=$DIR/virtarm64
CLOUD=$DIR/virtarm64cloud

for f in "$PLAIN" "$CLOUD"; do
	[ -f "$f" ] || { echo "check-rootparity: no $f" >&2; exit 1; }
done

# Deliberately in virtarm64 and not in virtarm64cloud.  Empty today: the
# framebuffer and the draw stack are device lines rather than root lines,
# so nothing the display needs shows up here.
ONLY_PLAIN=""

WORK=`mktemp -d`
trap 'st=$?; rm -rf "$WORK" || true; exit $st' 0

# The root section runs from the "root" line to the end; its file entries
# are the tab-indented paths.  A directory entry ("/mnt  /") carries a
# second field, and both forms matter -- a missing directory is as much a
# failure as a missing file -- so the whole line is compared with its
# trailing space collapsed.
rootlines() {
	awk '/^root/,0' "$1" | grep -E "^	/" | sed -e 's/[ 	]*$//' -e 's/	\{1,\}/ /g' | sort -u
}

rootlines "$PLAIN" >"$WORK/plain"
rootlines "$CLOUD" >"$WORK/cloud"

comm -23 "$WORK/plain" "$WORK/cloud" >"$WORK/missing"
if [ -n "$ONLY_PLAIN" ]; then
	printf '%s\n' "$ONLY_PLAIN" | sort -u >"$WORK/allowed"
	comm -23 "$WORK/missing" "$WORK/allowed" >"$WORK/unexplained"
else
	cp "$WORK/missing" "$WORK/unexplained"
fi

n=`wc -l <"$WORK/unexplained" | tr -d ' '`
extras=`comm -13 "$WORK/plain" "$WORK/cloud" | wc -l | tr -d ' '`
plain=`wc -l <"$WORK/plain" | tr -d ' '`

if [ "$n" -ne 0 ]; then
	echo "check-rootparity: FAIL -- $n entries in virtarm64's root are missing from virtarm64cloud's:" >&2
	sed 's/^/    | /' "$WORK/unexplained" >&2
	echo "check-rootparity: add them there too, or list them in ONLY_PLAIN with a reason" >&2
	exit 1
fi
echo "check-rootparity: ok -- all $plain of virtarm64's root entries are in virtarm64cloud, which adds $extras"
