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
