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
