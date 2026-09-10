#!/bin/sh
# Build rio - the real 9front rio, from the source in 9front/src/cmd/rio -
# for the library-OS personality, and emit os/osprey/pc64/rioprogp9.i.
#
# This is the program Phase 3.2 is named for.  It is linked against
# p9crt.c, which is the personality standing in for libc's system calls,
# and against threadmain9.c, which is this tree's libthread port - the
# four functions 9front keeps in libthread/main.c.  The prebuilt archive
# of generated system-call stubs is left off the line entirely, so a call
# rio makes that the personality does not answer is a link error here
# rather than a fault on a booted machine.
#
# With -u, as a relocatable module: rio has no address of its own and the
# loader takes a slot for it.
#
# p9crt.c comes first so that p9start is at offset 0, which is where the
# loader enters a module.  startboot, which p9start calls, is
# threadmain9.c's: it is what turns the loader's entry into libthread's
# main.
#
# Library order matters, as build9bin.sh explains: this 6l makes one pass
# over each archive, so a library must come before the one that answers
# it.
set -e
cd "$(dirname "$0")/../../../.."
ROOT="$PWD"
P=os/osprey/cmd/p9
LIBINC="-I Osprey/amd64/include -I Osprey/include -I include -I $P"
THRINC="-I $ROOT/9front/src/include -I $ROOT/9front/amd64/include -I $ROOT/9front/src/libthread"
INC="-I$ROOT/9front/src/include -I$ROOT/9front/amd64/include"
LIBSRC="$ROOT/9front/amd64/lib-src"
6c $LIBINC -o /tmp/rio9_crt.6 $P/p9crt.c
6c $THRINC -o /tmp/rio9_thrmain.6 $P/threadmain9.c
6a -o /tmp/rio9_cons.6 $P/p9cons.s
OBJ="/tmp/rio9_crt.6 /tmp/rio9_thrmain.6 /tmp/rio9_cons.6"
SUP=""
for m in utfnlen vsnprint dofmt vfprint tokenize; do
	6c $LIBINC -o /tmp/rio9_$m.6 lib9/$m.c
	SUP="$SUP /tmp/rio9_$m.6"
done
( cd "$ROOT/9front/src/cmd/rio"
  rm -f ./*.6
  for f in rio data fsys scrl time util wctl wind xfid; do
	6c -I. $INC -o "/tmp/rio9_c_$f.6" $f.c
  done
  rm -f ./*.6 )
RIOOBJ=""
for f in rio data fsys scrl time util wctl wind xfid; do
	RIOOBJ="$RIOOBJ /tmp/rio9_c_$f.6"
done
6l -u -l -R4096 -o /tmp/riop9 $OBJ $SUP $RIOOBJ \
	$LIBSRC/libframe.a $LIBSRC/libcomplete.a $LIBSRC/libdraw.a \
	$LIBSRC/libthread.a $LIBSRC/libplumb.a $LIBSRC/libc9.a
python3 scripts/checkmodule.py /tmp/riop9 "$PWD/os/osprey/pc64/rioprogp9.i" rioprogp9
