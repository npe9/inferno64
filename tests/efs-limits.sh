#!/bin/sh
#
# efs at and past its declared limits.
#
# module/efs.m fixes the shape: Blocksize 4096, Bitsperblk 32768 (one
# block of the free map covers one GROUP), Maxgroups 512, so
# Maxblocks = 16777216 and the largest filesystem is 64GiB.  The
# existing stress suite runs 1024- and 4096-block images, which is
# entirely inside the first group and never touches that arithmetic.
#
# What is asked here:
#   - does a filesystem whose size lands exactly ON a group boundary
#     work, and one block either side of it
#   - is a size past Maxblocks REFUSED rather than silently wrapped
#   - does filling a filesystem fail cleanly, and does it still mount
#     and verify afterwards
#
# Each image is made, mounted, written to, unmounted, and handed to
# efsck, because "it mounted" is not the same as "it is correct" and
# the only thing that distinguishes them here is efsck.
#
set -u
ROOT=`cd \`dirname "$0"\`/.. && pwd`
cd "$ROOT"
EMU=./MacOSX/arm64/bin/emu-cpu
[ -x "$EMU" ] || EMU=./MacOSX/arm64/bin/emu
T=tmp
EMUTIMEOUT=240
fail=0
say() { printf '%s\n' "$*"; }

emu() {					# emu <script-file>
	# -pheap=256M, for the reason tests/efs-stress.sh gives where it does
	# the same: efs allocates briskly and sizing the heap for the workload
	# is a stress test's job, while shrinking the workload to fit a
	# default heap is not.  Without it a 6000-file fill dies with
	# "out of memory: heap" and tells you nothing about the filesystem.
	timeout $EMUTIMEOUT $EMU -pheap=256M -r"$ROOT" /dis/sh.dis "$1" > $T/efs-lim-raw.txt 2>&1
	st=$?
	[ $st -eq 124 ] && say "     (emu hit the ${EMUTIMEOUT}s timeout)"
	return $st
}

#
# One size: make, mount, write a file, read it back, unmount, efsck.
#
size() {				# size <label> <blocks>
	label=$1; blocks=$2
	cat > $T/efs-lim.sh <<EOS
load std
disk/mkefs -n $blocks /tmp/efslim.img
or {and {disk/efs -f /tmp/efslim.img /n/client} {echo MOUNTED}} {echo MOUNTFAIL}
or {and {echo payload-$label > /n/client/f} {cat /n/client/f} {echo WROTE}} {echo WRITEFAIL}
unmount /n/client
or {and {disk/efsck /tmp/efslim.img} {echo CKCLEAN}} {echo CKDIRTY}
EOS
	rm -f $T/efslim.img
	emu $T/efs-lim.sh
	if grep -q MOUNTED $T/efs-lim-raw.txt &&
	   grep -q WROTE $T/efs-lim-raw.txt &&
	   grep -q "payload-$label" $T/efs-lim-raw.txt &&
	   grep -q CKCLEAN $T/efs-lim-raw.txt; then
		say "  ok: $label ($blocks blocks)"
	else
		say "  FAIL: $label ($blocks blocks)"
		grep -aE 'MOUNTFAIL|WRITEFAIL|CKDIRTY|efsck:|mkefs:|panic' \
			$T/efs-lim-raw.txt | head -4 | sed 's/^/     /'
		fail=`expr $fail + 1`
	fi
	rm -f $T/efslim.img
}

say "efs at its group boundaries"
size one-under-a-group 32767
size exactly-one-group 32768
size one-over-a-group  32769

say "efs past Maxblocks, which must be refused not wrapped"
cat > $T/efs-lim.sh <<'EOS'
load std
# Maxblocks is 16777216; one past it must not produce a filesystem.
or {disk/mkefs -n 16777217 /tmp/efsover.img} {echo MKEFS-REFUSED}
or {and {disk/efs -f /tmp/efsover.img /n/client} {echo OVER-MOUNTED}} {echo OVER-NOMOUNT}
EOS
rm -f $T/efsover.img
emu $T/efs-lim.sh
if grep -q MKEFS-REFUSED $T/efs-lim-raw.txt; then
	say "  ok: Maxblocks+1 refused by mkefs"
elif grep -q OVER-NOMOUNT $T/efs-lim-raw.txt; then
	say "  ok: Maxblocks+1 made something that will not mount"
else
	say "  FAIL: Maxblocks+1 produced a mountable filesystem"
	fail=`expr $fail + 1`
fi
rm -f $T/efsover.img

#
# Filling a filesystem.  This arm FAILS today, and the failure is the
# point of it: efs does not reach the end of even a 4MiB filesystem made
# of 41-byte files.  Measured, filling a 1024-block image:
#
#   heap 64M    151 creates, then "out of memory: heap"
#   heap 256M   265 creates, then "disfault: sys: bad address"
#   heap 256M   292 creates, then "out of memory: heap"
#
# (Those three predate Fs.reserve, which holds an eighth of a filesystem
# back so that a delete can always commit -- see tests/efs-wedge.sh.  The
# reserve lowers how many files fit but not what this arm is about: the
# server still runs out of MEMORY before it runs out of ROOM.)
#
# So four times the heap buys under twice the creates, and the mode
# varies between a clean out-of-memory and a fault.  A filesystem server
# should run out of SPACE and say so; this one runs out of memory first,
# and sometimes faults instead of refusing.  tests/efs-stress.sh sizes
# its heap at 256M and runs four to twelve files, which is inside the
# range that works -- nothing had asked for hundreds.
#
# Why four times the heap buys under twice the files is now measured, in
# tests/efs-leak.sh: efs allocates more heap per operation the more files
# the FILESYSTEM holds -- 323.6 blocks per operation at one entry, 1439.3
# at sixty -- so a create costs more the more files already exist and the
# total is quadratic.  Four times the memory for twice the files is that
# law.  A memfs mounted the same way is exactly flat (151.4 against
# 151.7), which puts the term in efs and not in the mount or Styx path.
# It is not a leak: the collector does reclaim, it just does not keep up,
# so the ceiling is the high-water of garbage.
#
# Left failing rather than tuned until it passes, because the number of
# files a filesystem can hold should not be a property of the heap.
#
say "efs when it runs out of room"
cat > $T/efs-lim.sh <<'EOS'
load std
disk/mkefs -n 1024 /tmp/efsfull.img
or {and {disk/efs -f /tmp/efsfull.img /n/client} {echo MOUNTED}} {echo MOUNTFAIL}
# 1024 blocks is 4MiB; write 1KiB files until one fails.
n:=0
for i in `{seq 1 6000} {
	or {echo 0123456789012345678901234567890123456789 > /n/client/f^$i} {
		echo FULL-AT $i
		n = 1
		break
	}
}
or {~ $n 1} {echo NEVER-FILLED}
or {and {echo after-full > /n/client/last} {echo STILL-WRITABLE}} {echo REFUSES-AFTER-FULL}
unmount /n/client
or {and {disk/efs -f /tmp/efsfull.img /n/client2} {echo REMOUNTED}} {echo NOREMOUNT}
unmount /n/client2
or {and {disk/efsck /tmp/efsfull.img} {echo CKCLEAN}} {echo CKDIRTY}
EOS
rm -f $T/efsfull.img
emu $T/efs-lim.sh
if grep -q 'FULL-AT' $T/efs-lim-raw.txt &&
   grep -q REMOUNTED $T/efs-lim-raw.txt &&
   grep -q CKCLEAN $T/efs-lim-raw.txt; then
	say "  ok: filled, refused cleanly, remounted, efsck clean"
	grep -ao 'FULL-AT [0-9]*' $T/efs-lim-raw.txt | head -1 | sed 's/^/     /'
else
	say "  FAIL: runs out of MEMORY before it runs out of room (see above)"
	grep -aE 'NEVER-FILLED|NOREMOUNT|CKDIRTY|efsck:|panic|FULL-AT|out of memory|bad address' \
		$T/efs-lim-raw.txt | head -5 | sed 's/^/     /'
	fail=`expr $fail + 1`
fi
rm -f $T/efsfull.img

if [ $fail -eq 0 ]; then
	say "EFS-LIMITS-OK"
	exit 0
fi
say "EFS-LIMITS-FAIL $fail"
exit 1
