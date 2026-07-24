#!/bin/sh
# Cross-build Linux/riscv64 JIT + console emu-g via Docker (Debian trixie),
# then smoke under qemu-user.
#
#	./emu/Linux/cross-riscv64.sh
set -e

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
IMG=inferno-rvbuild
CC=riscv64-linux-gnu-gcc
AR=riscv64-linux-gnu-ar

ensure() {
	if ! docker inspect "$IMG" >/dev/null 2>&1; then
		docker run -d --name "$IMG" -v "$ROOT:/inferno" debian:trixie-slim sleep infinity >/dev/null
		docker exec "$IMG" bash -c '
			apt-get update -qq
			DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
				gcc-riscv64-linux-gnu binutils-riscv64-linux-gnu \
				qemu-user qemu-user-static build-essential >/dev/null
		'
	else
		docker start "$IMG" >/dev/null
	fi
}

ensure
echo "== rebuild JIT into libinterp.a =="
docker exec "$IMG" bash -lc '
set -e
ROOT=/inferno
CC=riscv64-linux-gnu-gcc
AR=riscv64-linux-gnu-ar
CFLAGS="-O2 -fno-strict-aliasing -Wno-implicit-function-declaration -Wno-incompatible-pointer-types -Wno-unused-variable"
INCS="-I$ROOT/Linux/riscv64/include -I$ROOT/include -I$ROOT/libinterp"
DEFS="-DLINUX_RISCV64 -D_GNU_SOURCE"
cd $ROOT/libinterp
	$CC -c $CFLAGS $INCS $DEFS -o comp-riscv64.o comp-riscv64-jit.c
	$CC -c $CFLAGS $INCS $DEFS das-riscv64.c
	$CC -c $CFLAGS $INCS $DEFS load.c
	$CC -c $CFLAGS $INCS $DEFS heap.c
	rm -rf /tmp/lip && mkdir /tmp/lip && cd /tmp/lip
	$AR x $ROOT/Linux/riscv64/lib/libinterp.a
	cp -f $ROOT/libinterp/comp-riscv64.o $ROOT/libinterp/das-riscv64.o \
		$ROOT/libinterp/load.o $ROOT/libinterp/heap.o .
	for f in *.o; do riscv64-linux-gnu-objcopy --strip-debug "$f" || true; done
	$AR rcs $ROOT/Linux/riscv64/lib/libinterp.a *.o
	riscv64-linux-gnu-size $ROOT/libinterp/comp-riscv64.o
'

echo "== strip dependent libs (cross-ld SEGV on DWARF from older objs) =="
docker exec "$IMG" bash -lc '
set -e
ROOT=/inferno
AR=riscv64-linux-gnu-ar
for lib in libmath libkeyring libsec libmp lib9; do
	rm -rf /tmp/$lib && mkdir /tmp/$lib && cd /tmp/$lib
	$AR x $ROOT/Linux/riscv64/lib/$lib.a
	for f in *.o; do riscv64-linux-gnu-objcopy --strip-debug "$f" || true; done
	$AR rcs $ROOT/Linux/riscv64/lib/$lib.a *.o
done
'

echo "== relink emu-g =="
docker exec "$IMG" bash -lc '
set -e
ROOT=/inferno
CC=riscv64-linux-gnu-gcc
CFLAGS="-O2 -fno-strict-aliasing -Wno-implicit-function-declaration -Wno-unused-variable"
INCS="-I$ROOT/Linux/riscv64/include -I$ROOT/include -I$ROOT/libinterp -I. -I../port"
DEFS="-DLINUX_RISCV64 -D_GNU_SOURCE -DEMU -DROOT=/inferno"
cd $ROOT/emu/Linux
$CC -c $CFLAGS $INCS $DEFS segflush-riscv64.c
$CC -c $CFLAGS $INCS $DEFS ../port/dis.c -o dis.o
$CC -c $CFLAGS $INCS $DEFS -DKERNDATE=0 emu-g.c -o emu-g.o
for f in *.o; do riscv64-linux-gnu-objcopy --strip-debug "$f" || true; done
OBJS="
asm-riscv64.o segflush-riscv64.o os.o kproc-pthreads.o lock.o
emu-g.root.o emu-g.o
alloc.o cache.o chan.o cmd.o
dev.o devcap.o devcmd.o devcons.o devdup.o deveia.o devenv.o
devfs.o devindir.o devip.o devmem.o devmnt.o devpipe.o
devprof.o devprog.o devroot.o devsrv.o devssl.o devtab.o
dial.o dis.o discall.o env.o error.o errstr.o exception.o
exportfs.o inferno.o ipaux.o ipif6-posix.o latin1.o main.o
parse.o pgrp.o print.o proc.o qio.o random.o srv.o sysfile.o uqid.o
"
$CC -O2 \
	-Wl,--wrap=malloc -Wl,--wrap=mallocz -Wl,--wrap=free \
	-Wl,--wrap=realloc -Wl,--wrap=calloc \
	-o o.emu-g $OBJS \
	-L$ROOT/Linux/riscv64/lib \
	-linterp -lmath -lkeyring -lsec -lmp -l9 \
	-lm -lpthread
cp -f o.emu-g $ROOT/Linux/riscv64/bin/emu-g
riscv64-linux-gnu-nm o.emu-g | grep " T compile$"
'

echo "== smoke =="
exec "$ROOT/emu/Linux/smoke-riscv64.sh"
