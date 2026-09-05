#!/usr/bin/env bash
#
# mkhost.sh -- build the 9front tools that have to run on the build
# machine rather than on 9front.
#
# Most of what 9front builds is for 9front and 6c makes it.  A few
# programs are different: the build runs them, here, to generate
# source.  libc/ucd's mkrunetype is one and its own mkfile knows how
# to build it (through the eval of host/mkfile beside this).  mpc is
# the other, and nothing in the tree knows: on a 9front machine it is
# an ordinary command in /bin that libsec's and libauthsrv's mkfiles
# call by name.  So it is built here, into 9front/host/bin, which
# scripts/mk9front.sh puts on the path.
#
# mpc is a yacc program and it wants libmp.  The one it gets is this
# tree's host libmp -- the same library Inferno's own utilities use --
# rather than the 9front libmp being built for amd64, which is not
# code this machine can run.
#
# yacc is a third.  The parser this tree's iyacc writes calls sprint,
# which Plan 9's libc has and APE's libap does not, so an APE program
# with a grammar in it -- eqn, pic, grap, spin -- does not link.
# 9front's own yacc writes a parser against 9front's libc, which is
# the one being built here, so that is the yacc to run.  It needs its
# skeleton, which is why the import brings sys/lib/yaccpar across, and
# one function this tree's Bio has not got; see Blethal in hostsupp.c.
#
# cpp is the other.  APE's headers begin
#
#	#if !defined(_RESEARCH_SOURCE) && !defined(_PLAN9_SOURCE)
#
# and neither 9front's compiler nor this tree's understands "#if" --
# which is why 9front's pcc pipes every APE source through the
# standalone cpp rather than handing it to the compiler.  So the same
# is needed here, running on this machine.  Its one Plan 9 system call
# is dup(old, new); 9front-glue/host/include/unistd.h is where that is
# made to mean what it means on Plan 9.
#
# size is the last, and the only one here that is not 9front's own
# source: cwfs's mkfile runs "size $target" after linking and the name
# would otherwise reach the Xcode size, which reads Mach-O.  9front's
# size goes through libmach; this one reads the a.out header directly.
# See the note at the top of size.c.
#
# mkpaqfs and mkbootfs are the last two, and they are for a kernel
# rather than for the userland: mkbootfs lays out the tree a boot
# proto describes and mkpaqfs turns it into the bootfs.paq the kernel
# links.  On 9front those are mkpaqfs and disk/mkfs, both ordinary
# commands in /bin.  mkpaqfs is 9front's own source built here
# against this tree's libflate and libsec; mkbootfs is ours, and the
# note at the top of it says why disk/mkfs is not built instead.
#
# ROOT must be set.  Called by scripts/mk9front.sh; a tool is rebuilt
# only when its source is newer.

set -eu

: "${ROOT:?ROOT must be set}"

host=$ROOT/$(/usr/bin/sed -n 's/^SYSHOST=\([^ 	]*\).*/\1/p' "$ROOT/mkconfig")/$(/usr/bin/sed -n 's/^OBJTYPE=\([^ 	]*\).*/\1/p' "$ROOT/mkconfig")
bin=$ROOT/9front/host/bin
obj=$ROOT/9front/host/obj
mkdir -p "$bin" "$obj"

src=$ROOT/9front-src/sys/src/cmd/mpc.y
if [ ! -x "$bin/mpc" ] || [ "$src" -nt "$bin/mpc" ] \
   || [ "$ROOT/9front-glue/host/hostsupp.c" -nt "$bin/mpc" ]; then
	echo "mkhost: mpc"
	(cd "$obj" && "$host/bin/iyacc" -o mpc.c -s mpc "$src" >/dev/null 2>&1)
	cc -w -Wno-implicit-function-declaration -Wno-int-conversion \
		-I"$ROOT/9front-glue/host/include" -I"$host/include" -I"$ROOT/include" \
		-o "$bin/mpc" "$obj/mpc.c" "$ROOT/9front-glue/host/hostsupp.c" \
		"$host/lib/libmp.a" "$host/lib/libbio.a" "$host/lib/lib9.a"
fi

src=$ROOT/9front-src/sys/src/cmd/yacc.c
if [ ! -x "$bin/yacc" ] || [ "$src" -nt "$bin/yacc" ] \
   || [ "$ROOT/9front-glue/host/hostsupp.c" -nt "$bin/yacc" ]; then
	echo "mkhost: yacc"
	"$ROOT/9front-glue/host/hostcc" \
		-DPARSER="\"$ROOT/9front-src/sys/lib/yaccpar\"" \
		-DPARSERS="\"$ROOT/9front-src/sys/lib/yaccpars\"" \
		-o "$obj/yacc.o" "$src"
	"$ROOT/9front-glue/host/hostld" -o "$bin/yacc" "$obj/yacc.o"
fi

cppdir=$ROOT/9front-src/sys/src/cmd/cpp
newest=$(/usr/bin/find "$cppdir" -name '*.[ch]' -newer "$bin/cpp" -print 2>/dev/null | head -1)
if [ ! -x "$bin/cpp" ] || [ -n "$newest" ]; then
	echo "mkhost: cpp"
	objs=
	for f in cpp lex nlist tokens macro eval include hideset; do
		"$ROOT/9front-glue/host/hostcc" \
			-o "$obj/cpp-$f.o" "$cppdir/$f.c"
		objs="$objs $obj/cpp-$f.o"
	done
	# shellcheck disable=SC2086
	"$ROOT/9front-glue/host/hostld" -o "$bin/cpp" $objs
fi

src=$ROOT/9front-glue/host/size.c
if [ ! -x "$bin/size" ] || [ "$src" -nt "$bin/size" ] \
   || [ "$ROOT/9front-glue/host/hostsupp.c" -nt "$bin/size" ]; then
	echo "mkhost: size"
	"$ROOT/9front-glue/host/hostcc" -o "$obj/size.o" "$src"
	"$ROOT/9front-glue/host/hostld" -o "$bin/size" "$obj/size.o"
fi

flate=$ROOT/libflate
src=$ROOT/9front-src/sys/src/cmd/paqfs/mkpaqfs.c
if [ ! -x "$bin/mkpaqfs" ] || [ "$src" -nt "$bin/mkpaqfs" ] \
   || [ "$flate/deflate.c" -nt "$bin/mkpaqfs" ] \
   || [ "$ROOT/9front-glue/host/hostsupp.c" -nt "$bin/mkpaqfs" ]; then
	echo "mkhost: mkpaqfs"
	objs=
	"$ROOT/9front-glue/host/hostcc" -o "$obj/mkpaqfs.o" "$src"
	objs="$obj/mkpaqfs.o"
	for f in deflate deflateblock flateerr crc adler; do
		"$ROOT/9front-glue/host/hostcc" -o "$obj/flate-$f.o" "$flate/$f.c"
		objs="$objs $obj/flate-$f.o"
	done
	# shellcheck disable=SC2086
	"$ROOT/9front-glue/host/hostld" -o "$bin/mkpaqfs" $objs \
		"$host/lib/libsec.a" "$host/lib/libmp.a"
fi

src=$ROOT/9front-glue/host/mkbootfs.c
proto=$ROOT/9front-src/sys/src/libdisk/proto.c
if [ ! -x "$bin/mkbootfs" ] || [ "$src" -nt "$bin/mkbootfs" ] \
   || [ "$proto" -nt "$bin/mkbootfs" ] \
   || [ "$ROOT/9front-glue/host/hostsupp.c" -nt "$bin/mkbootfs" ]; then
	echo "mkhost: mkbootfs"
	nine="-I$ROOT/9front-glue/host/include/9front -I$ROOT/utils/include"
	# shellcheck disable=SC2086
	"$ROOT/9front-glue/host/hostcc" $nine -o "$obj/mkbootfs.o" "$src"
	# shellcheck disable=SC2086
	"$ROOT/9front-glue/host/hostcc" $nine -o "$obj/proto.o" "$proto"
	"$ROOT/9front-glue/host/hostld" -o "$bin/mkbootfs" \
		"$obj/mkbootfs.o" "$obj/proto.o" "$host/lib/libregexp.a"
fi
