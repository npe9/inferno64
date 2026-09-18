#!/bin/sh
# Build cat for the library-OS personality and emit
# os/osprey/pc64/libcatprog.i.
#
# It is the same source as the cat that runs under the buddy on the
# server personality (catp9.c), unchanged.  What differs is the link: it
# is linked against p9crt.c, which defines open, read, write, close,
# seek, dup, fd2path, sbrk and exits itself and so keeps libc's
# system-call stubs for them off the link line entirely.  Those calls go
# to the personality in the program's own address space instead.  One
# program, two arrangements: a process boundary on the server
# personality, none here.
#
# It is linked with -u, as a relocatable module, so it has no address of
# its own: the loader takes a free slot for it and corrects every
# absolute address in it as it lays it down.  That is what lets the shell
# run two cats in one pipeline, which it could not while cat was its
# address.  p9crt.c comes first so that p9start is at offset 0, which is
# where the loader enters a module; scripts/checkmodule.py checks that
# against the module's own symbol table rather than taking it on trust.
set -e
cd "$(dirname "$0")/../../../.."
P=os/osprey/cmd/p9
LIBINC="-I Osprey/amd64/include -I Osprey/include -I include -I $P"
6c $LIBINC -o /tmp/libcat_crt.6 $P/p9crt.c
6c $LIBINC -o /tmp/libcat_cat.6 $P/catp9.c
6a -o /tmp/libcat_cons.6 $P/p9cons-amd64.s
OBJ="/tmp/libcat_crt.6 /tmp/libcat_cat.6 /tmp/libcat_cons.6"
SUP=""
for m in utfnlen vsnprint dofmt vfprint; do
	6c $LIBINC -o /tmp/libcat_$m.6 lib9/$m.c
	SUP="$SUP /tmp/libcat_$m.6"
done
6l -u -l -R4096 -o /tmp/libcatp9 $OBJ $SUP Osprey/amd64/lib/libc.a
python3 scripts/checkmodule.py /tmp/libcatp9 "$PWD/os/osprey/pc64/libcatprog.i" libcatprog
