#!/bin/sh
# Build the 9front userland this tree carries the source of, with this
# tree's own toolchain, into 9front/amd64/lib-src.
#
# Why from source.  The prebuilt archives in 9front/amd64/lib were made
# by 9front's own 6c, which emits instructions past the end of this
# linker's table: 6l here reads 228 of the 262 members of libc.a and
# rejects 34 with "opcode out of range".  Nothing in the tree had ever
# linked them, and the reason was that it could not.  This tree's 6c, on
# the other hand, compiles current 9front source: all 220 files of libc
# that are imported build with no warnings.  main9.s and main9p.s, the
# two that libc's own entry lives in, are not imported at all - the
# entries in os/osprey/pc/init9*.c stand in for them - and pool.c
# wanted a newer pool.h and is given one, the whole include set at the
# same revision being carried in 9front/src.
#
# What still comes from the prebuilt archive is the system-call stubs -
# open, close, rfork, rendezvous and the rest.  Those are generated on a
# real Plan 9 by libc/9syscall/mkfile out of a sys.h and the kernel's
# table, so there is no source file to build here; they are also small
# and every one of them is readable.  So the link is source-built libc
# first and the archive after it, and the archive answers only what the
# source cannot.
#
# The revision is a0a079f4054f88eabcb2c2e6d20f3ee4a1908b78 (9front), the
# same for every directory under 9front/src.  See 9front/src/README.
set -e
cd "$(dirname "$0")/../../../.."
ROOT="$PWD"
INC="-I$ROOT/9front/src/include -I$ROOT/9front/amd64/include"
OUT="$ROOT/9front/amd64/lib-src"
mkdir -p "$OUT"

# libc, whose parts live in four directories
build_libc() {
	rm -f "$OUT/libc9.a"
	for d in port fmt 9sys amd64; do
		( cd "$ROOT/9front/src/libc/$d" || exit 1
		  rm -f ./*.6
		  for f in *.c; do
			6c -I. -I../fmt $INC "$f" || exit 1
		  done
		  for f in *.s; do
			test -f "$f" || continue
			6a -I. "$f" || exit 1
		  done
		  # r, not u: amd64 is built last and its memmove.s,
		  # strcpy.s, getcallerpc.s and the eleven others must
		  # replace the same-named port C, which is what 9front's
		  # own build does and what "u" - replace if newer - fails
		  # to do when the two are compiled in the same second.
		  iar rvc "$OUT/libc9.a" ./*.6 >/dev/null
		  rm -f ./*.6 ) || exit 1
	done
	echo "libc9.a $(ls -l "$OUT/libc9.a" | awk '{print $5}') bytes"
}

# a library whose whole directory is the library, minus the files named
build_lib() {
	lib=$1; shift
	skip=" $* "
	rm -f "$OUT/$lib.a"
	( cd "$ROOT/9front/src/$lib" || exit 1
	  rm -f ./*.6
	  for f in *.c; do
		case "$skip" in *" $f "*) continue;; esac
		6c -I. $INC "$f" || exit 1
	  done
	  iar rvc "$OUT/$lib.a" ./*.6 >/dev/null
	  rm -f ./*.6 ) || exit 1
	echo "$lib.a $(ls -l "$OUT/$lib.a" | awk '{print $5}') bytes"
}

build_libc
# libthread carries every architecture's context switch; amd64.c is this
# one's, and the others would define the same symbols.  example.c, test.c
# and tprimes.c are programs that live beside the library.
build_lib libthread 386.c arm.c arm64.c mips.c power.c power64.c example.c test.c tprimes.c
build_lib libdraw
build_lib libframe
build_lib libplumb
build_lib libcomplete
build_lib libmemdraw
build_lib libmemlayer
build_lib lib9p ftest.c		# lib9p's own test program, not part of the library
build_lib libauth
