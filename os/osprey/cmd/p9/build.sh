#!/bin/sh
# Build the Plan 9 namespace library as a program on the host toolchain.
# The name space (chan/dev/pgrp/devroot) is the kernel's own upper half
# compiled against the shim (nsdat.h/dat.h/mem.h/fns.h + p9shim.c bodies).
# Link note: the disk libc.a has members the host 6l cannot read (built
# by a newer 6c), so link -l (no auto-libc) and supply those members
# from lib9 source; libc.a still provides its readable members.
set -e
cd "$(dirname "$0")/../../../.."          # repo root
P=os/osprey/cmd/p9
INC="-I $P -I os/osprey/port -I os/osprey/pc64 -I Osprey/amd64/include -I Osprey/include -I include"
LIBINC="-I Osprey/amd64/include -I Osprey/include -I include -I $P"
OBJ="os/osprey/pc64/init9.6"
for f in $P/main.c $P/p9shim.c os/osprey/port/chan.c os/osprey/port/dev.c \
         os/osprey/port/pgrp.c os/osprey/port/devroot.c; do
	o=/tmp/p9_$(basename $f .c).6
	6c $INC -o $o $f
	OBJ="$OBJ $o"
done
# libc members the host linker can't read, supplied from lib9 source
SUP=""
for m in utfnlen convM2D convD2M vsnprint dofmt vfprint; do
	6c $LIBINC -o /tmp/p9_$m.6 lib9/$m.c
	SUP="$SUP /tmp/p9_$m.6"
done
6l -l -R4096 -o /tmp/p9lib $OBJ $SUP Osprey/amd64/lib/libc.a
echo "built /tmp/p9lib"
