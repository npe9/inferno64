#!/bin/sh
#
# Hammer dossrv and then ask an outside tool whether the filesystem it
# leaves behind is sound.
#
# The Pi's own card was the first thing that found dossrv's FAT32 bugs,
# one boot and one card swap at a time: a rename that kept only the low
# half of a start cluster, a FAT32 root directory that could not grow,
# and a rename onto an existing name that removed the source before
# finding out it could not finish.  Each of those corrupted a card that
# still mounted and still listed, which is the point: reading the files
# back through the same code that wrote them is not enough.  fsck_msdos
# walks the chains and the directories with its own opinions, and it is
# the check that matters here.
#
# Three filesystems, because the bugs were all in the differences:
#
#	fat16	512-byte clusters, a fixed root directory
#	fat32	512-byte clusters, a root that is a cluster chain, and
#		a 34MB filler so that files land above cluster 65535 --
#		where the top half of a start cluster stops being zero
#	fat32b	4KB clusters, no filler: ordinary numbers, for contrast
#
set -e
ROOT=${ROOT:-`cd \`dirname $0\`/.. && pwd`}
EMU=${EMU:-$ROOT/MacOSX/arm64/bin/emu}
OUT=${OUT:-`mktemp -d`}
mkdir -p "$OUT"
ROUNDS=${ROUNDS:-4}
FILES=${FILES:-12}

if [ ! -x "$EMU" ]; then
	echo "dossrv-stress: no emu at $EMU (set EMU=)" >&2
	exit 2
fi
for t in newfs_msdos fsck_msdos hdiutil diskutil; do
	command -v $t >/dev/null 2>&1 || { echo "dossrv-stress: no $t" >&2; exit 2; }
done

mkdir -p "$ROOT/n/t" "$ROOT/tmp"
chmod 777 "$ROOT/n/t" "$ROOT/tmp"

status=0

mkfs() {	# $1 image, $2 MB, $3 fat bits, $4 sectors/cluster, $5 filler MB
	rm -f "$1"
	dd if=/dev/zero of="$1" bs=1048576 count=0 seek=$2 2>/dev/null
	dev=`hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$1" | awk '{print $1; exit}'`
	[ -n "$dev" ] || { echo "dossrv-stress: cannot attach $1" >&2; exit 2; }
	newfs_msdos -F $3 -c $4 -v STRESS "$dev" >/dev/null 2>&1 ||
		{ hdiutil detach "$dev" >/dev/null 2>&1; echo "dossrv-stress: newfs $1" >&2; exit 2; }
	if [ -n "$5" ] && [ "$5" != 0 ]; then
		mnt="$OUT/mnt"
		mkdir -p "$mnt"
		diskutil mount -mountPoint "$mnt" "$dev" >/dev/null
		dd if=/dev/zero of="$mnt/filler.bin" bs=1048576 count=$5 2>/dev/null
		diskutil unmount "$mnt" >/dev/null
	fi
	hdiutil detach "$dev" >/dev/null 2>&1
}

run() {		# $1 name, $2 image, $3 MB, $4 fat bits, $5 spc, $6 filler
	echo "=== $1 (FAT$4, $5 sector(s) per cluster, ${6:-0}MB filler)"
	mkfs "$ROOT/tmp/stress.img" $3 $4 $5 "$6"
	chmod 666 "$ROOT/tmp/stress.img"
	cat > "$ROOT/tmp/stress.sh" <<SH
load std
dossrv -f /tmp/stress.img -m /n/t
sleep 1
fatstress -n $ROUNDS -f $FILES /n/t
SH
	#
	# emu in the background and killed when the run says it is done:
	# dossrv goes on serving after fatstress returns, and emu does not
	# exit while it does.  (btbench.sh says the same about btfs.)
	#
	"$EMU" -r "$ROOT" sh /tmp/stress.sh > "$OUT/$1.log" 2>&1 &
	emupid=$!
	i=0
	while [ $i -lt ${WAIT:-150} ]; do
		grep -q 'FATSTRESS-' "$OUT/$1.log" 2>/dev/null && break
		kill -0 $emupid 2>/dev/null || break
		sleep 1
		i=`expr $i + 1`
	done
	sleep 1
	kill $emupid 2>/dev/null || true
	wait $emupid 2>/dev/null || true
	cat "$OUT/$1.log"
	if ! grep -q FATSTRESS-OK "$OUT/$1.log"; then
		echo "STRESS FAIL ($1): the run did not finish clean"
		status=1
		return
	fi
	#
	# and the filesystem itself.  fsck_msdos -n reports lost chains,
	# cross-links, bad directory entries and a wrong free count
	# without changing anything.
	#
	if fsck_msdos -n "$ROOT/tmp/stress.img" > "$OUT/$1.fsck" 2>&1; then
		echo "fsck: clean"
	else
		echo "STRESS FAIL ($1): fsck_msdos is not happy"
		sed -n 1,20p "$OUT/$1.fsck"
		status=1
	fi
}

run fat16 "$ROOT/tmp/stress.img" 32 16 1 0
run fat32 "$ROOT/tmp/stress.img" 64 32 1 34
# 512MB, not 256: with 4KB clusters a 256MB filesystem has just under
# the 65525 clusters that make it FAT32, and newfs_msdos refuses it
run fat32b "$ROOT/tmp/stress.img" 512 32 8 0

rm -f "$ROOT/tmp/stress.img" "$ROOT/tmp/stress.sh"
if [ $status = 0 ]; then
	echo "STRESS PASS"
else
	echo "STRESS FAIL"
fi
exit $status
