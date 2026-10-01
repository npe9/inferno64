#!/bin/sh
#
# efs: the fallback the two superblocks exist for.
#
#	sh tests/efs-fallback.sh
#
# Run from the root of the tree.
#
# WHY THIS EXISTS.  A Pi 3B came up with its filesystem unmountable:
#
#	efs: /n/dos/efs.img: 16384 blocks, generation 978 from superblock 1
#	efs: mount /n/efs: node checksum 1000 1, want 0 0
#
# efsck on that image found a tree node reading back as 4096 zero bytes
# while the live superblock still named it.  Generation 977, sitting in
# the other superblock, was never tried -- Fs.mount chose the
# higher-generation READABLE SUPERBLOCK and never asked whether the tree
# that superblock named could be read.  Fs.alloc's own comment says "a
# crash part way through a commit must be able to fall back"; nothing
# provided the fallback.
#
# tests/efs-format.sh already covers a corrupt SUPERBLOCK, which was
# always handled.  This covers a sound superblock naming a tree that is
# not there, which was not.
#
# The image is corrupted by hand rather than by injecting a write
# failure, and that is deliberate: -F stops writes at the efs layer,
# where the commit order still holds, so it cannot produce "the
# superblock landed and a node did not".  Reaching in and zeroing the
# block the live superblock points at produces exactly that state and
# nothing else, which is what makes a pass here mean something.
#
# Four checks:
#
#	1. -S names a superblock, so the two generations can be read
#	   independently.  Without this there was no way to ask whether
#	   the generation behind a broken one was sound -- a
#	   mount-write-unmount cycle commits TWICE, so the live slot
#	   cannot even be moved by hand to find out.
#	2. both generations are sound on a healthy image, which is the
#	   CoW invariant stated rather than assumed.
#	3. with the live superblock's tree root zeroed, mount falls back,
#	   says so, and the files are still there and still readable.
#	4. efsck goes through the same mount, so it reports the tree it
#	   would actually be checking.
#
set -u
ROOT=`cd \`dirname "$0"\`/.. && pwd`
cd "$ROOT"
EMU=./MacOSX/arm64/bin/emu-cpu
[ -x "$EMU" ] || EMU=./MacOSX/arm64/bin/emu
T=tmp
EMUTIMEOUT=200
fail=0

say() { printf '%s\n' "$*"; }
check() {
	if grep -q "$2" "$3"; then
		say "  ok: $1"
	else
		say "  FAIL: $1 (wanted /$2/)"
		fail=`expr $fail + 1`
	fi
}
nocheck() {
	if grep -q "$2" "$3"; then
		say "  FAIL: $1 (did not want /$2/)"
		fail=`expr $fail + 1`
	else
		say "  ok: $1"
	fi
}

#
# emu's status is the status, not the left-hand side of a pipe: a server
# that never exits must not read as slow work.  Same rule as the other
# efs suites.
#
runemu() {			# runemu <outfile> <script>
	rout=$1; rscr=$2
	timeout $EMUTIMEOUT $EMU -r"$ROOT" /dis/sh.dis "$rscr" > $T/fb-raw.txt 2>&1
	rst=$?
	grep -v '^new:\|^newa:' $T/fb-raw.txt > "$rout"
	if [ $rst -ne 0 ]; then
		say "  FAIL: emu exited $rst on $rscr (124 means it never exited)"
		fail=`expr $fail + 1`
	fi
}

mkdir -p $T
rm -f $T/fb.img

#
# Two commits, so that BOTH slots hold a generation.  A freshly made
# image has only superblock 0 written, and falling back to a slot that
# was never written is not the case under test.
#
cat > $T/fb-make.sh <<'EOF'
load std
disk/mkefs -n 256 /tmp/fb.img
disk/efs -f /tmp/fb.img /n/client
echo one > /n/client/a
echo two > /n/client/b
unmount /n/client
echo MADE
EOF
say '1. a healthy image, and -S to read each superblock'
runemu $T/fb1.txt /$T/fb-make.sh
check "it was made"		'MADE'				$T/fb1.txt

cat > $T/fb-look.sh <<'EOF'
load std
disk/efsck -S 0 /tmp/fb.img
disk/efsck -S 1 /tmp/fb.img
echo LOOKED
EOF
runemu $T/fb2.txt /$T/fb-look.sh
check "-S 0 is accepted"	'clean, generation'		$T/fb2.txt
check "-S reached the end"	'LOOKED'			$T/fb2.txt
#
# 2. BOTH sound, and at DIFFERENT generations.  Equal generations would
# pass a fallback test without a fallback having happened.
#
say '2. both generations sound, and one behind the other'
g0=`awk '/clean, generation/{print $NF; exit}' $T/fb2.txt`
g1=`awk '/clean, generation/{n++; if(n==2){print $NF; exit}}' $T/fb2.txt`
if [ -n "$g0" ] && [ -n "$g1" ] && [ "$g0" != "$g1" ]; then
	say "  ok: superblock 0 at generation $g0, superblock 1 at $g1"
else
	say "  FAIL: wanted two different clean generations, got '$g0' and '$g1'"
	fail=`expr $fail + 1`
fi

#
# 3. Zero the block the LIVE superblock's treeroot names.  The live one
# is whichever generation is higher, read out of the image rather than
# assumed, because which slot that is depends on how many commits ran.
#
say '3. the live superblock names a tree root that is not there'
python3 - "$T/fb.img" <<'PY'
import struct, sys
p = sys.argv[1]
BS = 4096
d = bytearray(open(p, 'rb').read())
n = len(d) // BS
rd = lambda o: struct.unpack('>q', bytes(d[o:o+8]))[0]
# superblock 0 is block 0; superblock 1 is the last block (superblk()).
b0, b1 = 0, (n - 1) * BS
live = b0 if rd(b0 + 16) > rd(b1 + 16) else b1
tr = rd(live + 32)			# Super.pack puts treeroot at 32
print("corrupting tree root block %d of generation %d" % (tr, rd(live + 16)))
d[tr*BS:(tr+1)*BS] = b'\0' * BS
open(p, 'wb').write(bytes(d))
PY

cat > $T/fb-mount.sh <<'EOF'
load std
disk/efs -f /tmp/fb.img /n/client
ls /n/client
cat /n/client/a
unmount /n/client
echo MOUNTED
EOF
runemu $T/fb3.txt /$T/fb-mount.sh
check "it said it fell back"	'falling back to superblock'	$T/fb3.txt
#
# The generation it MOUNTED must be the lower of the two.  "from
# superblock" alone is the normal banner and matches whether a fallback
# happened or not, which is not a check.
#
lo=$g1
[ -n "$g0" ] && [ -n "$g1" ] && [ "$g0" -lt "$g1" ] && lo=$g0
if [ -n "$lo" ]; then
	check "it mounted the older generation $lo" \
				"generation $lo from superblock"	$T/fb3.txt
else
	say "  FAIL: no generations read, cannot tell which was mounted"
	fail=`expr $fail + 1`
fi
#
# ANCHORED.  Unanchored, '/n/client/a' matched "cat: cannot open
# /n/client/a: does not exist" -- a check that passed on the very
# failure it was written to catch.
#
check "the files are there"	'^/n/client/a$'			$T/fb3.txt
check "and still read"		'^one$'				$T/fb3.txt
check "it got that far"		'MOUNTED'			$T/fb3.txt
#
# The point of the whole exercise: this used to be the board's failure.
#
nocheck "no unmountable filesystem" 'mount /n/client: node checksum'	$T/fb3.txt

say '4. efsck goes through the same mount'
cat > $T/fb-ck.sh <<'EOF'
load std
disk/efsck /tmp/fb.img
echo CHECKED
EOF
runemu $T/fb4.txt /$T/fb-ck.sh
check "efsck fell back too"	'falling back to superblock'	$T/fb4.txt
check "and found it clean"	'clean, generation'		$T/fb4.txt
check "it finished"		'CHECKED'			$T/fb4.txt

if [ $fail -eq 0 ]; then
	say 'EFS-FALLBACK-OK'
	exit 0
fi
say "EFS-FALLBACK-FAIL $fail check(s)"
exit 1
