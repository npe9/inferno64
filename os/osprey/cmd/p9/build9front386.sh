#!/bin/sh
# Build 9front's libc for 386 from the source this tree carries, into
# 9front/386/lib-src/libc9.a.
#
# build9front.sh does this for amd64 and takes the system-call stubs out
# of the prebuilt archive 9front/amd64/lib/libc.a, because on a real
# Plan 9 they are generated and there is no source to compile.  There is
# no prebuilt 386 archive here, so the stubs are written:
# os/osprey/cmd/p9/sys386.s, twenty-one of them, the same names the
# amd64 archive holds.
#
# What else a machine directory owes libc, this tree already had for
# other reasons:
#
#	_tas		os/osprey/pc/libctas.s, written for the 386 boot
#			libc.  9front's libc here has an amd64 machine
#			directory and no 386 one, which is the whole
#			reason this script exists.
#	the 64-bit	libkern/vlrt-386.c and vlop-386.s, Inferno's, which
#	arithmetic	include nothing and compile against either set of
#			headers.  8c calls out to these for uvlong
#			division, multiplication and the assignment
#			operators.
#	seek(2)		9front/src/libc/amd64/_seek.c is plain C - it wraps
#			the raw _seek stub - so it is compiled here rather
#			than written again.
#
# What is deliberately not here: main9.s, libc's own entry, which this
# tree does not import for amd64 either; os/osprey/pc/init9*.c stand in
# for it, as they do there.  So this archive is what a program links
# against, not something that can start one by itself.
#
# usage: sh os/osprey/cmd/p9/build9front386.sh
set -e
cd "$(dirname "$0")/../../../.."
ROOT="$PWD"
INC="-I$ROOT/9front/src/include -I$ROOT/9front/386/include"
OUT="$ROOT/9front/386/lib-src"
TMP="$OUT/obj"
mkdir -p "$TMP"
rm -f "$OUT/libc9.a" "$TMP"/*.8

# The portable three-quarters: port, fmt and 9sys, as on amd64.  The
# object keeps the source's own name and no directory prefix, which is
# what upstream's archive holds and is not only convention: a Plan 9
# archive's member name is sixteen characters, so a prefix silently
# truncates the long ones.  No basename repeats across the three
# directories, and the longest, getnetconninfo.8, just fits.
for d in port fmt 9sys; do
	for f in "$ROOT/9front/src/libc/$d"/*.c; do
		b=$(basename "$f" .c)
		8c -I"$ROOT/9front/src/libc/$d" -I"$ROOT/9front/src/libc/fmt" \
			$INC -o "$TMP/$b.8" "$f"
	done
done

# the machine's own share
8a -o "$TMP/sys386.8" "$ROOT/os/osprey/cmd/p9/sys386.s"
8a -o "$TMP/tas.8" "$ROOT/os/osprey/pc/libctas.s"
8a -o "$TMP/vlop-386.8" "$ROOT/libkern/vlop-386.s"
8c -o "$TMP/vlrt-386.8" "$ROOT/libkern/vlrt-386.c"
8c $INC -o "$TMP/_seek.8" "$ROOT/9front/src/libc/amd64/_seek.c"

iar vu "$OUT/libc9.a" "$TMP"/*.8 >/dev/null
echo "wrote $OUT/libc9.a ($(ls "$TMP"/*.8 | wc -l | tr -d ' ') members)"
