#!/bin/sh
#
# efs milestone 3: the read-only server.
#
#	sh tests/efs-server.sh
#
# Attach, walk, open, read, stat and a directory listing, under emu on
# the host against an image mkefs made -- which is the arrangement
# doc/efs-plan.ms chose a Limbo Styx server for.
#
# The check that carries this test is cmp on a 9000-byte binary file.
# It spans three extents, the last of them partial, so it exercises the
# extent lookup, the block-boundary arithmetic and the rule that the
# inode's length and not the block's size says where a file ends.  The
# text files are there for legibility; they would pass against several
# wrong implementations.
#
set -u
ROOT=`cd \`dirname "$0"\`/.. && pwd`
cd "$ROOT"
EMU=./MacOSX/arm64/bin/emu-cpu
[ -x "$EMU" ] || EMU=./MacOSX/arm64/bin/emu
T=tmp
D=$T/efsfiles
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

#
# The files.  big.bin is 9000 bytes so that it needs three blocks and
# ends part way through the third; the two text files are a byte count
# apart so a length mixed up between them would show.
#
mkdir -p $D
printf 'hello from efs\n' > $D/hello.txt
printf 'second file\n' > $D/two.txt
head -c 9000 /dev/urandom > $D/big.bin

rm -f $T/efss.img
cat > $T/efs-srv.sh <<'EOF'
load std
disk/mkefs -n 256 -a /tmp/efsfiles/hello.txt -a /tmp/efsfiles/big.bin -a /tmp/efsfiles/two.txt /tmp/efss.img
disk/efs -f /tmp/efss.img /n/client
echo 'MARK ls'
ls -l /n/client
echo 'MARK cat'
cat /n/client/hello.txt
cat /n/client/two.txt
echo 'MARK cmp'
or {and {cmp /n/client/big.bin /tmp/efsfiles/big.bin} {echo CMP-BIG-OK}} {echo CMP-BIG-DIFFERS}
or {and {cmp /n/client/hello.txt /tmp/efsfiles/hello.txt} {echo CMP-HELLO-OK}} {echo CMP-HELLO-DIFFERS}
or {and {cmp /n/client/two.txt /tmp/efsfiles/two.txt} {echo CMP-TWO-OK}} {echo CMP-TWO-DIFFERS}
echo 'MARK enoent'
or {cat /n/client/nosuch} {echo ENOENT-OK}
echo 'MARK writable'
or {and {echo x > /n/client/hello.txt} {echo WRITE-OK}} {echo WRITE-REFUSED}
EOF
timeout 120 $EMU -r"$ROOT" /dis/sh.dis /tmp/efs-srv.sh 2>&1 |
	grep -v '^new:\|^newa:' > $T/efs-srv.txt

say "the read-only server"
check "mounts, names the superblock"	'generation 1 from superblock 0'	$T/efs-srv.txt
check "lists three files"		'big.bin'			$T/efs-srv.txt
check "stat gives big.bin's length"	'9000.*big.bin'			$T/efs-srv.txt
check "stat gives hello's length"	' 15 .*hello.txt'		$T/efs-srv.txt
check "stat gives two's length"		' 12 .*two.txt'			$T/efs-srv.txt
check "owner from the inode"		'inferno inferno'		$T/efs-srv.txt
check "reads a file's contents"		'hello from efs'		$T/efs-srv.txt
check "9000 bytes byte-for-byte"	'CMP-BIG-OK'			$T/efs-srv.txt
check "hello byte-for-byte"		'CMP-HELLO-OK'			$T/efs-srv.txt
check "two byte-for-byte"		'CMP-TWO-OK'			$T/efs-srv.txt
check "a missing name is ENOENT"	'ENOENT-OK'			$T/efs-srv.txt
#
# This asserted that writes were REFUSED, which was right for milestone
# 3 and became wrong the moment milestone 4 landed.  A test that keeps
# asserting an old limitation fails for the best possible reason, and
# the fix is to assert the new behaviour rather than to delete the
# check: writes go to tests/efs-write.sh, and what matters here is that
# the read path still works with a writable server underneath it.
#
check "and the server accepts a write"	'WRITE-OK'			$T/efs-srv.txt

if [ $fail -eq 0 ]; then
	say "EFS-SERVER-OK"
	exit 0
fi
say "EFS-SERVER-FAIL $fail check(s)"
exit 1
