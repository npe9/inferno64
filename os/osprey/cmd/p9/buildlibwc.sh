#!/bin/sh
# Build wc, the far end of a pipeline, for the library-OS personality and emit
# os/osprey/pc64/libwcprog.i.
#
# Linked against p9crt.c, which is the personality standing in for libc's
# system calls, and with -u, as a relocatable module: it has no address of
# its own, and the loader takes a free slot for it and corrects every
# absolute address in it as it lays it down.  That is what lets two of it
# run at once - "cat | wc | wc" has two, and while wc was its address the
# second was refused.
#
# p9crt.c comes first so that p9start is at offset 0, which is where the
# loader enters a module; scripts/checkmodule.py checks that against the
# module's own symbol table rather than taking it on trust.
set -e
cd "$(dirname "$0")/../../../.."
P=os/osprey/cmd/p9
LIBINC="-I Osprey/amd64/include -I Osprey/include -I include -I $P"
6c $LIBINC -o /tmp/libwc_crt.6 $P/p9crt.c
6c $LIBINC -o /tmp/libwc_prog.6 $P/wcp9.c
6a -o /tmp/libwc_cons.6 $P/p9cons-amd64.s
OBJ="/tmp/libwc_crt.6 /tmp/libwc_prog.6 /tmp/libwc_cons.6"
SUP=""
for m in utfnlen vsnprint dofmt vfprint; do
	6c $LIBINC -o /tmp/libwc_$m.6 lib9/$m.c
	SUP="$SUP /tmp/libwc_$m.6"
done
6l -u -l -R4096 -o /tmp/libwcp9 $OBJ $SUP Osprey/amd64/lib/libc.a
python3 scripts/checkmodule.py /tmp/libwcp9 "$PWD/os/osprey/pc64/libwcprog.i" libwcprog
