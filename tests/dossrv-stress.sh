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

#
# A filesystem shaped like the Pi's own boot partition: a root directory
# of sixty long-named files and a hundred-odd megabytes in them.
#
# This is not decoration.  Every empty image above passes against a
# dossrv that renames a file into a zero-length entry on the board --
# the length is read back out of the sector buffer long after the
# sector has been handed to something else, and on a filesystem small
# enough that the buffer survives, nothing shows.  It takes a root
# directory long enough for the search to recycle that buffer.  Checked
# both ways: this case fails against the server before the fix and
# passes after it.
#
mkbusy() {	# $1 image
	rm -f "$1"
	dd if=/dev/zero of="$1" bs=1048576 count=0 seek=512 2>/dev/null
	dev=`hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$1" | awk '{print $1; exit}'`
	[ -n "$dev" ] || { echo "dossrv-stress: cannot attach $1" >&2; exit 2; }
	newfs_msdos -F 32 -c 1 -v BOOTFS "$dev" >/dev/null 2>&1 ||
		{ hdiutil detach "$dev" >/dev/null 2>&1; echo "dossrv-stress: newfs $1" >&2; exit 2; }
	mnt="$OUT/busy"
	mkdir -p "$mnt"
	diskutil mount -mountPoint "$mnt" "$dev" >/dev/null
	i=0
	while [ $i -lt 60 ]; do
		dd if=/dev/zero of="$mnt/bcm2710-rpi-firmware-blob-$i.dtb" bs=32768 count=1 2>/dev/null
		i=`expr $i + 1`
	done
	dd if=/dev/zero of="$mnt/start.elf" bs=1048576 count=3 2>/dev/null
	dd if=/dev/zero of="$mnt/start4x.elf" bs=1048576 count=3 2>/dev/null
	dd if=/dev/zero of="$mnt/kernel8.img" bs=1048576 count=2 2>/dev/null
	dd if=/dev/zero of="$mnt/filler.bin" bs=1048576 count=100 2>/dev/null
	mkdir -p "$mnt/overlays"
	dd if=/dev/zero of="$mnt/overlays/an-overlay-file.dtbo" bs=4096 count=1 2>/dev/null
	diskutil unmount "$mnt" >/dev/null
	hdiutil detach "$dev" >/dev/null 2>&1
	chmod 666 "$1"
}

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
	if [ "$1" = busy ]; then
		echo "=== busy (FAT32, 512-byte clusters, a Pi boot partition's shape)"
		mkbusy "$ROOT/tmp/stress.img"
	else
	echo "=== $1 (FAT$4, $5 sector(s) per cluster, ${6:-0}MB filler)"
	mkfs "$ROOT/tmp/stress.img" $3 $4 $5 "$6"
	fi
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
	# 150 was too short once the rename-while-open case joined: the
	# fat32 image reached round 2 of 4 and the harness killed it,
	# which reads exactly like a server that hung.
	while [ $i -lt ${WAIT:-600} ]; do
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
	#
	# Its exit status is not enough.  fsck_msdos -n exits 0 having
	# printed "Free space in FSInfo block (807357) not correct
	# (807350)", which is what a directory pointing at a cluster
	# somebody else owns looks like from outside -- the truncated
	# start cluster that mkdir used to write on a filesystem with
	# more than 65535 clusters in use.  Found by putting that bug
	# back: fatstress passed it (a write and a read follow the same
	# wrong pointer, so the round trip agrees with itself) and so did
	# the exit status.  So read what it says, and allow only the one
	# line it always prints, the summary count.
	#
	fsck_msdos -n "$ROOT/tmp/stress.img" > "$OUT/$1.fsck" 2>&1
	rc=$?
	# Two lines are allowed.  One is the summary count fsck always
	# prints.  The other is "Free space in FSInfo block is unset",
	# which is a state dossrv chooses: it does not maintain FAT32's
	# cached free-cluster count, so it writes the "unknown" value the
	# specification provides rather than leaving a stale one.  A
	# "not correct" there is a different thing and fails.
	if grep -a Warning "$OUT/$1.fsck" |
	   grep -av "files, .* free" |
	   grep -av "FSInfo block is unset" > "$OUT/$1.warn"; then
		echo "STRESS FAIL ($1): fsck_msdos is not happy"
		sed -n 1,20p "$OUT/$1.warn"
		status=1
	elif [ $rc != 0 ]; then
		echo "STRESS FAIL ($1): fsck_msdos exited $rc"
		sed -n 1,20p "$OUT/$1.fsck"
		status=1
	else
		echo "fsck: clean"
	fi
}

run fat16 "$ROOT/tmp/stress.img" 32 16 1 0
run fat32 "$ROOT/tmp/stress.img" 64 32 1 34
# 512MB, not 256: with 4KB clusters a 256MB filesystem has just under
# the 65525 clusters that make it FAT32, and newfs_msdos refuses it
run fat32b "$ROOT/tmp/stress.img" 512 32 8 0
run busy "$ROOT/tmp/stress.img" 512 32 1 0
#
# The card's own shape: 537MB, FAT32, 64 sectors to a cluster -- 32KB.
#
# None of the cases above uses a cluster anywhere near that size, and
# that turned out to matter.  A kernel installed on the board by
# kupdate had the right name and the right size to the byte and 13780
# wrong bytes in it, and aligning the comparison to 32KB is what made
# the shape legible: 14 of its 57 chunks held the previous kernel's
# bytes, the first 448KB and one more.  The writes all returned the
# length they were given.  If this case reproduces it, the fault is in
# dossrv and this is where to fix it; if it does not, the difference is
# devsd or sdemmcbcm and the board is the only place left to look.
#
# kupdaterehearsal() in fatstress is already the exact sequence --
# 1.5MB written, the old one renamed aside, the new one renamed into
# place, and then read back and compared byte for byte.
#
# 2400MB, not the card's 537: FAT32 wants at least 65525 clusters and
# 32KB clusters do not reach that until 2.1GB, so newfs_msdos refuses
# the real partition's size outright.  The Pi's own firmware wrote the
# card, and it is not fussy.  The image is sparse, so the size costs a
# directory entry.
run card "$ROOT/tmp/stress.img" 2400 32 64 0

rm -f "$ROOT/tmp/stress.img" "$ROOT/tmp/stress.sh"
if [ $status = 0 ]; then
	echo "STRESS PASS"
else
	echo "STRESS FAIL"
fi
exit $status
