#!/bin/sh
#
# efs milestone 2: make an image and print it back, then corrupt it on
# purpose and check that the format fails the way it promises to.
#
#	sh tests/efs-format.sh
#
# Run from the root of the tree.  Everything happens under emu on the
# host against image files -- which is the property doc/efs-plan.ms
# chose a Limbo Styx server for, and the property that found every bug
# in dossrv during this port.
#
# The checks, in order:
#
#	1. dump's report matches what mkefs was told to write.  This is
#	   the milestone's own check.  It is weak on its own -- an empty
#	   image proves nothing, as the plan says -- so the three below
#	   do the work.
#	2. one superblock corrupt: the checksum catches it, names it, and
#	   mount falls back to the spare.  Note WHERE the spare is found
#	   from: the device's size, not the corrupt superblock's claim
#	   about the size, or the corruption would hide the copy that
#	   exists for exactly this case.
#	3. both corrupt: refuses to mount.  A filesystem that mounts and
#	   lies is the failure this format exists to prevent, so "no" is
#	   the correct answer and a pass.
#	4. the tree root corrupt, superblocks fine: the per-block checksum
#	   turns "the tree is wrong" into "block 1 is wrong".
#
set -u
ROOT=`cd \`dirname "$0"\`/.. && pwd`
cd "$ROOT"
EMU=./MacOSX/arm64/bin/emu-cpu
[ -x "$EMU" ] || EMU=./MacOSX/arm64/bin/emu
T=tmp
fail=0

say() { printf '%s\n' "$*"; }
check() {			# check <what> <pattern> <file>
	if grep -q "$2" "$3"; then
		say "  ok: $1"
	else
		say "  FAIL: $1 (wanted /$2/)"
		fail=`expr $fail + 1`
	fi
}

rm -f $T/efs.img $T/efs-one.img $T/efs-both.img $T/efs-tree.img

cat > $T/efs-run.sh <<'EOF'
load std
disk/mkefs -n 256 /tmp/efs.img
disk/efsdump /tmp/efs.img
EOF
timeout 120 $EMU -r"$ROOT" /dis/sh.dis /tmp/efs-run.sh 2>&1 |
	grep -v '^new:\|^newa:' > $T/efs-out.txt

say "1. dump matches mkefs"
check "block count"	'nblocks 256'				$T/efs-out.txt
check "live generation"	'mount would take superblock 0, generation 1' $T/efs-out.txt
check "spare is older"	'generation 0'				$T/efs-out.txt
check "bitmap at 1"	'freeroot 1'				$T/efs-out.txt
check "tree root at 2"	'treeroot 2'				$T/efs-out.txt
check "root inode"	'(1 inode 0).*mode 40775 nlink 2'	$T/efs-out.txt
check "four blocks used"	'4 marked in use'			$T/efs-out.txt
check "which four"	'in use: 0 1 2 255'			$T/efs-out.txt

#
# The corruptions go at byte 32 of a block, which is the treeroot field,
# chosen because it is a field the reader would otherwise believe.
#
cp $T/efs.img $T/efs-one.img
printf '\336\255\276\357' | dd of=$T/efs-one.img bs=1 seek=32 conv=notrunc 2>/dev/null
cp $T/efs.img $T/efs-both.img
printf '\336\255' | dd of=$T/efs-both.img bs=1 seek=32 conv=notrunc 2>/dev/null
printf '\336\255' | dd of=$T/efs-both.img bs=1 seek=1044512 conv=notrunc 2>/dev/null
#
# The tree root, at block 2 in an empty image: byte 2*4096+20, which is
# inside its first entry.  These offsets track mkefs's layout, so a
# change there breaks this test rather than silently corrupting the
# wrong block and passing -- which is what happened when the bitmap
# moved to block 1 and this still aimed at 4096.
#
cp $T/efs.img $T/efs-tree.img
printf '\336\255' | dd of=$T/efs-tree.img bs=1 seek=8212 conv=notrunc 2>/dev/null

cat > $T/efs-run2.sh <<'EOF'
load std
echo 'MARK one'
disk/efsdump /tmp/efs-one.img
echo 'MARK both'
disk/efsdump /tmp/efs-both.img
echo 'MARK tree'
disk/efsdump /tmp/efs-tree.img
EOF
timeout 120 $EMU -r"$ROOT" /dis/sh.dis /tmp/efs-run2.sh 2>&1 |
	grep -v '^new:\|^newa:' > $T/efs-out2.txt

#
# Inferno's shell parses an unquoted == as a syntax error: = is
# assignment and there is no equality operator spelled that way.  The
# markers above are quoted for that reason, and this note is here
# because the first version of this script was not and the whole second
# half silently produced nothing but "syntax error".
#

say "2. one superblock corrupt: falls back to the spare"
awk '/^MARK one/,/^MARK both/' $T/efs-out2.txt > $T/efs-one.txt
check "checksum names it"	'superblock checksum'		$T/efs-one.txt
check "spare still found"	'superblock 1 (block 255)'	$T/efs-one.txt
check "mounts the spare"	'mount would take superblock 1'	$T/efs-one.txt
check "and still reads"		'mode 40775'			$T/efs-one.txt

say "3. both superblocks corrupt: refuses"
awk '/^MARK both/,/^MARK tree/' $T/efs-out2.txt > $T/efs-both.txt
check "refuses to mount"	'mount would FAIL'		$T/efs-both.txt

say "4. tree root corrupt: names the block"
awk '/^MARK tree/,0' $T/efs-out2.txt > $T/efs-tree.txt
check "superblocks still good"	'mount would take superblock 0'	$T/efs-tree.txt
check "block named"		'node checksum'			$T/efs-tree.txt

if [ $fail -eq 0 ]; then
	say "EFS-FORMAT-OK"
	exit 0
fi
say "EFS-FORMAT-FAIL $fail check(s)"
exit 1
