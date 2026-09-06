#!/bin/sh
# Link the graphics userland this tree builds from source: rio, and the
# draw, mouse and keyboard servers.  build9front.sh makes the libraries
# first.  Output goes to 9front/amd64/bin-src.
#
# The entry is init9main.c's - an ordinary program's main(), not the
# startboot() this tree's own legacy demonstrations are written with -
# and the Tos and the private words come with it (init9tos.c), because
# libc's own _main is a member this linker cannot read.
#
# Library order matters here in a way it does not on a real Plan 9.
# This 6l makes one pass over each archive, so a library must come
# before the one that answers it: libframe and libcomplete ask libdraw,
# libmemlayer and libmemdraw ask libdraw, lib9p asks libauth for amount
# and libthread for incref, and everything asks libc.  The source-built
# libc comes before the prebuilt archive, which answers only the
# generated system-call stubs it has no source for.
set -e
cd "$(dirname "$0")/../../../.."
ROOT="$PWD"
INC="-I$ROOT/9front/src/include -I$ROOT/9front/amd64/include"
LIBSRC="$ROOT/9front/amd64/lib-src"
OUT="$ROOT/9front/amd64/bin-src"
ENTRY="$ROOT/os/osprey/pc64/init9main.6 $ROOT/os/osprey/pc64/init9tos.6"
# Each program is given the libraries its own mkfile names and no more.
# rio's list is libdraw, libframe, libthread, libplumb and libc; handing
# it lib9p as well pulls in a second definition of main, since lib9p
# reaches for libthread's and rio has its own threadmain.
LIBC="$LIBSRC/libc9.a $ROOT/Osprey/amd64/lib/libc.a"
RIOLIBS="$LIBSRC/libframe.a $LIBSRC/libcomplete.a $LIBSRC/libdraw.a \
	$LIBSRC/libthread.a $LIBSRC/libplumb.a $LIBC"
SRVLIBS="$LIBSRC/libmemlayer.a $LIBSRC/libmemdraw.a $LIBSRC/libdraw.a \
	$LIBSRC/lib9p.a $LIBSRC/libauth.a $LIBSRC/libthread.a $LIBC"
mkdir -p "$OUT"

# rio, out of 9front/src/cmd/rio
( cd "$ROOT/9front/src/cmd/rio"
  rm -f ./*.6
  for f in rio data fsys scrl time util wctl wind xfid; do
	6c -I. $INC $f.c
  done
  6l -l -R4096 -o "$OUT/rio" $ENTRY ./*.6 $RIOLIBS
  rm -f ./*.6 )

# the draw, mouse and keyboard servers, which are this tree's own source
( cd "$ROOT/os/osprey/cmd/draw"
  rm -f ./*.6
  for f in devdraw kshim main cursor mouse kbd; do
	6c -I. $INC -o "/tmp/9d_$f.6" $f.c
  done
  6l -l -R4096 -o "$OUT/drawsrv" $ENTRY /tmp/9d_devdraw.6 /tmp/9d_kshim.6 /tmp/9d_main.6 /tmp/9d_cursor.6 $SRVLIBS
  6l -l -R4096 -o "$OUT/mousesrv" $ENTRY /tmp/9d_mouse.6 $SRVLIBS
  6l -l -R4096 -o "$OUT/kbdsrv" $ENTRY /tmp/9d_kbd.6 $SRVLIBS
  rm -f /tmp/9d_*.6 )

for b in rio drawsrv mousesrv kbdsrv; do
	echo "$b $(ls -l "$OUT/$b" | awk '{print $5}') bytes"
done
