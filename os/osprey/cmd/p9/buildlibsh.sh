#!/bin/sh
# Build the shell that runs on the library-OS personality for the library-OS personality and emit
# os/osprey/pc64/libshprog.i.
#
# Linked against p9crt.c, which is the personality standing in for libc's
# system calls, and with -u, as a relocatable module: it has no address of
# its own, and the loader takes a free slot for it and corrects every
# absolute address in it as it lays it down.  The shell is the program the
# personality itself execs, so this is the path that takes a slot in
# p9exec rather than in p9spawn - and the shell holds its slot for as long
# as its script runs, with its pipelines in the slots beside it.
#
# p9crt.c comes first so that p9start is at offset 0, which is where the
# loader enters a module; scripts/checkmodule.py checks that against the
# module's own symbol table rather than taking it on trust.
set -e
cd "$(dirname "$0")/../../../.."
P=os/osprey/cmd/p9
LIBINC="-I Osprey/amd64/include -I Osprey/include -I include -I $P"
6c $LIBINC -o /tmp/libsh_crt.6 $P/p9crt.c
6c $LIBINC -o /tmp/libsh_prog.6 $P/shlib.c
6a -o /tmp/libsh_cons.6 $P/p9cons-amd64.s
OBJ="/tmp/libsh_crt.6 /tmp/libsh_prog.6 /tmp/libsh_cons.6"
SUP=""
for m in utfnlen vsnprint dofmt vfprint; do
	6c $LIBINC -o /tmp/libsh_$m.6 lib9/$m.c
	SUP="$SUP /tmp/libsh_$m.6"
done
6l -u -l -R4096 -o /tmp/libshp9 $OBJ $SUP Osprey/amd64/lib/libc.a
python3 scripts/checkmodule.py /tmp/libshp9 "$PWD/os/osprey/pc64/libshprog.i" libshprog
