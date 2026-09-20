#!/bin/sh
#
# Write a file with dossrv and then read it with somebody else.
#
# This is the check tests/dossrv-stress.sh does not make, and the gap it
# leaves is the one that has now cost this board three kernels.
# fatstress writes a file and reads it back, but it reads it back
# through the same dossrv that wrote it, so a block that never reached
# the card is still served out of the sector cache and compares equal.
# kupdate on the board does exactly the same thing and for the same
# reason reported "KUPDATE-VERIFY 1918040 bytes read back identical"
# about a kernel whose first 256KB were the previous kernel's.
#
# fsck_msdos is an outside opinion about the STRUCTURE -- chains,
# directories, the free count -- and it passed on that card too,
# because the structure was right.  Nothing was checking the CONTENTS.
#
# So: dossrv writes the file under emu, the image is detached from emu
# entirely, and macOS mounts it and compares the bytes.  Two different
# filesystem implementations, one of which has no cache in common with
# the other.
#
set -e
ROOT=${ROOT:-`cd \`dirname $0\`/.. && pwd`}
EMU=${EMU:-$ROOT/MacOSX/arm64/bin/emu}
OUT=${OUT:-`mktemp -d`}
MB=${MB:-512}		# FAT32 needs 65525 clusters; at 4KB that is 268MB minimum
SPC=${SPC:-8}		# sectors per cluster; the card's own shape is 8 (4KB)
SIZE=${SIZE:-1918040}	# a kernel's worth, which is what fails on the board
ROUNDS=${ROUNDS:-4}	# kupdate's sequence, repeated, so clusters get recycled

mkdir -p "$OUT" "$ROOT/n/t" "$ROOT/tmp"
chmod 777 "$ROOT/n/t" "$ROOT/tmp"

if [ ! -x "$EMU" ]; then
	echo "dossrv-outside: no emu at $EMU (set EMU=)" >&2
	exit 2
fi
for t in newfs_msdos hdiutil diskutil; do
	command -v $t >/dev/null 2>&1 || { echo "dossrv-outside: no $t" >&2; exit 2; }
done

img="$ROOT/tmp/outside.img"
src="$ROOT/tmp/outside.src"

#
# A source file whose every byte is a function of its offset, so a
# comparison says WHERE it went wrong and not merely that it did.  A
# file of zeros, or of one repeated pattern, hides exactly the failure
# this is looking for: a stale region that happens to hold the same
# bytes.
#
r=0
while [ $r -le $ROUNDS ]; do
	dd if=/dev/urandom of="$src.$r" bs=1024 count=$((SIZE/1024 + 1)) 2>/dev/null
	dd if="$src.$r" of="$src.$r.t" bs=1 count=$SIZE 2>/dev/null
	mv "$src.$r.t" "$src.$r"
	chmod 666 "$src.$r"
	r=`expr $r + 1`
done

rm -f "$img"
dd if=/dev/zero of="$img" bs=1048576 count=0 seek=$MB 2>/dev/null
dev=`hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$img" | awk '{print $1; exit}'`
[ -n "$dev" ] || { echo "dossrv-outside: cannot attach $img" >&2; exit 2; }
newfs_msdos -F 32 -c $SPC -v OUTSIDE "$dev" >/dev/null 2>&1 ||
	{ hdiutil detach "$dev" >/dev/null 2>&1; echo "dossrv-outside: newfs" >&2; exit 2; }
hdiutil detach "$dev" >/dev/null 2>&1
chmod 666 "$img"

#
# The sequence kupdate performs, which is where this fails on the
# board: write under a temporary name, rename the old one aside, rename
# the new one into place.  Then exit, so every buffer dossrv holds is
# either written or lost -- and the point of this test is to find out
# which.
#
{
echo 'load std'
echo 'dossrv -f /tmp/outside.img -m /n/t'
echo 'sleep 1'
echo 'cp /tmp/outside.src.0 /n/t/kernel8.img'
#
# And somebody else using the same server at the same time, because
# that is the board's shape and it is the one thing left that this
# test did not have.  kupdate is spawned on purpose so that "the
# checks and the fetch proceed together"; dossrv serialises the
# requests but the sector cache is shared, and the region that came
# back stale on the board -- the first 256KB of a 1.9MB file -- is the
# part written earliest and so the first to be evicted.  A test where
# nothing else is running never evicts anything under pressure.
#
if [ ${CONCURRENT:-1} != 0 ]; then
	echo '{ fatstress -n 12 -f 8 /n/t } &'
fi
r=1
while [ $r -le $ROUNDS ]; do
	#
	# Exactly what kupdate does, and in its order.  The old kernel
	# is moved aside before the new one takes its name, so the
	# clusters the previous file held are freed one round and
	# handed straight back out the next -- which is the state the
	# board is in every time it updates, and the state a test that
	# writes into an empty filesystem never reaches.
	#
	echo "rm -f /n/t/kernel8.bak"
	echo "cp /tmp/outside.src.$r /n/t/kernel8.new"
	echo "mv /n/t/kernel8.img /n/t/kernel8.bak"
	echo "mv /n/t/kernel8.new /n/t/kernel8.img"
	echo "echo ROUND $r"
	r=`expr $r + 1`
done
echo 'echo WROTE'
} > "$ROOT/tmp/outside.sh"
"$EMU" -r "$ROOT" sh /tmp/outside.sh > "$OUT/run.log" 2>&1 &
emupid=$!
i=0
while [ $i -lt ${WAIT:-600} ]; do
	grep -q 'WROTE' "$OUT/run.log" 2>/dev/null && break
	kill -0 $emupid 2>/dev/null || break
	sleep 1
	i=`expr $i + 1`
done
sleep 2
kill $emupid 2>/dev/null || true
wait $emupid 2>/dev/null || true
cat "$OUT/run.log"

if ! grep -q WROTE "$OUT/run.log"; then
	echo "OUTSIDE-FAIL dossrv did not finish the write"
	exit 1
fi

#
# Now ask somebody else.
#
mnt="$OUT/mnt"
mkdir -p "$mnt"
dev=`hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$img" | awk '{print $1; exit}'`
diskutil mount -mountPoint "$mnt" "$dev" >/dev/null
rc=0
if [ ! -f "$mnt/kernel8.img" ]; then
	echo "OUTSIDE-FAIL the file is not there at all"
	rc=1
elif cmp "$mnt/kernel8.img" "$src.$ROUNDS" && cmp "$mnt/kernel8.bak" "$src.`expr $ROUNDS - 1`"; then
	echo "OUTSIDE-OK $SIZE bytes, ${SPC}-sector clusters, $ROUNDS rounds: kernel8.img and kernel8.bak both hold what dossrv was given"
else
	echo "OUTSIDE-FAIL the bytes on the disk are not the bytes dossrv was given"
	#
	# Say WHERE, because the shape is the diagnosis.  A contiguous
	# run from the start is a prefix that never left the cache; a
	# scatter is something else entirely.
	#
	python3 - "$mnt/kernel8.img" "$src.$ROUNDS" <<'PY'
import sys
a=open(sys.argv[1],'rb').read(); b=open(sys.argv[2],'rb').read()
print("  on disk %d bytes, expected %d" % (len(a), len(b)))
n=min(len(a),len(b))
bad=[i for i in range(n) if a[i]!=b[i]]
if not bad:
    print("  contents agree; only the length differs")
else:
    print("  %d bytes differ, first at %d, last at %d" % (len(bad), bad[0], bad[-1]))
    runs=[]; s=bad[0]; p=bad[0]
    for i in bad[1:]:
        if i!=p+1:
            runs.append((s,p)); s=i
        p=i
    runs.append((s,p))
    print("  %d contiguous run(s); the largest:" % len(runs))
    for s,e in sorted(runs, key=lambda r: r[0]-r[1])[:4]:
        print("    %d..%d  (%d bytes, %d KB)" % (s,e,e-s+1,(e-s+1)//1024))
PY
	rc=1
fi
diskutil unmount "$mnt" >/dev/null 2>&1
hdiutil detach "$dev" >/dev/null 2>&1
rm -f "$img" "$src".* "$ROOT/tmp/outside.sh"
exit $rc
