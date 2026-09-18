#!/bin/sh
# Build the relocation probe as a dynamically loadable module and emit
# os/osprey/pc64/relocprog.i.
#
# The difference from every other loaded program here is the -u: it is
# Plan 9's dynamically-loadable-module link, and it changes three things
# that matter.  The image is linked at 0 rather than at -T, so it has no
# address of its own.  A relocation table is appended after the symbol
# table (asmdyn in utils/6l/span.c), holding every absolute address the
# image contains.  And the header's entry is no longer a code entry -
# with -u the linker sets INITENTRY to _exporttab, so it points at the
# export table, which is why the loader here does not read it.
#
# p9start is at offset 0 of the module.  That is the same invariant every
# other program of this kind relies on - p9crt.c is linked first and
# p9start is the first thing in its text - and with the text linked at 0
# it becomes simply offset 0, which is what p9loadreloc enters.  The
# check below is that invariant tested rather than assumed: the module's
# first instructions must be the same ones the ordinary link puts at its
# entry.
set -e
cd "$(dirname "$0")/../../../.."
P=os/osprey/cmd/p9
LIBINC="-I Osprey/amd64/include -I Osprey/include -I include -I $P"
6c $LIBINC -o /tmp/reloc_crt.6 $P/p9crt.c
6c $LIBINC -o /tmp/reloc_prog.6 $P/relocp9.c
6a -o /tmp/reloc_cons.6 $P/p9cons-amd64.s
OBJ="/tmp/reloc_crt.6 /tmp/reloc_prog.6 /tmp/reloc_cons.6"
# the libc members the host linker cannot read out of the archive, from
# source, as every other loaded program here does
for m in utfnlen vsnprint dofmt vfprint; do
	6c $LIBINC -o /tmp/reloc_$m.6 lib9/$m.c
	OBJ="$OBJ /tmp/reloc_$m.6"
done
6l -u -l -R4096 -o /tmp/relocdlm $OBJ Osprey/amd64/lib/libc.a
python3 scripts/checkmodule.py /tmp/relocdlm "$PWD/os/osprey/pc64/relocprog.i" relocprog
