#!/bin/sh
# Cross-build Linux/riscv64 full X11 emu via Docker (Debian trixie + multiarch).
# Requires inferno-rvbuild (created by cross-riscv64.sh) and ELF graphics libs
# under Linux/riscv64/lib (rebuilds them if they look like Mach-O).
#
#	./emu/Linux/cross-emu-x11.sh
set -e

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
IMG=inferno-rvbuild
CC=riscv64-linux-gnu-gcc
AR=riscv64-linux-gnu-ar

ensure() {
	if ! docker inspect "$IMG" >/dev/null 2>&1; then
		echo "cross-emu-x11: run ./emu/Linux/cross-riscv64.sh first" >&2
		exit 1
	fi
	docker start "$IMG" >/dev/null
	docker exec "$IMG" bash -lc '
		set -e
		export DEBIAN_FRONTEND=noninteractive
		dpkg --add-architecture riscv64 2>/dev/null || true
		apt-get update -qq
		apt-get install -y -qq \
			libx11-dev:riscv64 libxext-dev:riscv64 file qemu-user >/dev/null
	'
}

elf_member() {
	lib=$1
	docker exec "$IMG" bash -lc "
		cd /tmp && rm -rf t && mkdir t && cd t
		$AR x /inferno/Linux/riscv64/lib/${lib}.a
		f=\$(ls *.o | head -1)
		file \"\$f\" | grep -q 'ELF.*RISC-V'
	"
}

ensure

echo "== ensure ELF graphics libs =="
need=
for lib in libdraw libmemdraw libmemlayer libtk libfreetype; do
	if ! elf_member "$lib"; then
		need="$need $lib"
	fi
done
# Source newer than archive (e.g. LP64 sizeof(u32) stride fix in load.c).
if [ -f "$ROOT/Linux/riscv64/lib/libmemdraw.a" ] && \
   [ "$ROOT/libmemdraw/load.c" -nt "$ROOT/Linux/riscv64/lib/libmemdraw.a" ]; then
	need="$need libmemdraw"
fi
if [ -n "$need" ]; then
	echo "rebuilding:$need"
	docker exec "$IMG" bash -lc '
		set -e
		ROOT=/inferno
		cp "$ROOT/mkconfig" /tmp/mkconfig.host.bak
		trap "cp /tmp/mkconfig.host.bak $ROOT/mkconfig" EXIT
		cat > $ROOT/mkconfig <<EOF
ROOT=/inferno
TKSTYLE=std
CONF=emu
SYSHOST=Linux
SYSTARG=\$SYSHOST
OBJTYPE=riscv64
OBJDIR=\$SYSTARG/\$OBJTYPE
<\$ROOT/mkfiles/mkhost-\$SYSHOST
<\$ROOT/mkfiles/mkfile-\$SYSTARG-\$OBJTYPE
EOF
		mkdir -p /tmp/crossbin
		ln -sf /usr/bin/riscv64-linux-gnu-gcc /tmp/crossbin/cc
		ln -sf /usr/bin/riscv64-linux-gnu-gcc /tmp/crossbin/gcc
		ln -sf /usr/bin/riscv64-linux-gnu-ar /tmp/crossbin/ar
		ln -sf /usr/bin/riscv64-linux-gnu-ranlib /tmp/crossbin/ranlib
		cat > /tmp/crossbin/mk << "EOF"
#!/bin/sh
exec qemu-riscv64 /inferno/Linux/riscv64/bin/mk "$@"
EOF
		chmod +x /tmp/crossbin/mk
		export PATH=/tmp/crossbin:$ROOT/Linux/riscv64/bin:/usr/bin:/bin
		export MACOSINF=caseinsensitive
		for lib in libdraw libmemdraw libmemlayer libtk libfreetype; do
			echo "== $lib =="
			cd $ROOT/$lib
			rm -f *.[oas] 2>/dev/null || true
			rm -f $ROOT/Linux/riscv64/lib/$lib.a
			mk install
		done
	'
fi

echo "== strip graphics libs =="
docker exec "$IMG" bash -lc '
set -e
ROOT=/inferno
AR=riscv64-linux-gnu-ar
for lib in libtk libfreetype libdraw libmemlayer libmemdraw; do
	rm -rf /tmp/$lib && mkdir /tmp/$lib && cd /tmp/$lib
	$AR x $ROOT/Linux/riscv64/lib/$lib.a
	for f in *.o; do riscv64-linux-gnu-objcopy --strip-debug "$f" || true; done
	$AR rcs $ROOT/Linux/riscv64/lib/$lib.a *.o
done
'

echo "== compile X11 sources + link emu =="
docker exec "$IMG" bash -lc '
set -e
ROOT=/inferno
CC=riscv64-linux-gnu-gcc
CFLAGS="-O2 -fno-strict-aliasing -Wno-implicit-function-declaration -Wno-unused-variable -Wno-deprecated-declarations"
INCS="-I$ROOT/Linux/riscv64/include -I$ROOT/include -I$ROOT/libinterp -I. -I../port"
DEFS="-DLINUX_RISCV64 -D_GNU_SOURCE -DEMU -DROOT=/inferno"
cd $ROOT/emu/Linux
# main.c must be current so emuinit kbind("#m") / kbind("#^") run
for src in ../port/win-x11a.c ../port/devdraw.c ../port/devpointer.c \
	../port/devsnarf.c ../port/devds.c ../port/main.c; do
	base=$(basename "$src" .c)
	$CC -c $CFLAGS $INCS $DEFS "$src" -o ${base}.o
done
$CC -c $CFLAGS $INCS $DEFS -DKERNDATE=0 emu.c -o emu.o
for f in *.o; do riscv64-linux-gnu-objcopy --strip-debug "$f" || true; done
OBJS="
asm-riscv64.o segflush-riscv64.o os.o kproc-pthreads.o lock.o
emu.root.o emu.o
alloc.o cache.o chan.o cmd.o
dev.o devcap.o devcmd.o devcons.o devdraw.o devds.o devdup.o deveia.o devenv.o
devfs.o devindir.o devip.o devmem.o devmnt.o devpipe.o
devpointer.o devprof.o devprog.o devroot.o devsnarf.o devsrv.o
devssl.o devtab.o
dial.o dis.o discall.o env.o error.o errstr.o exception.o
exportfs.o inferno.o ipaux.o ipif6-posix.o latin1.o main.o
parse.o pgrp.o print.o proc.o qio.o random.o srv.o sysfile.o uqid.o
win-x11a.o
"
$CC -O2 \
	-Wl,--wrap=malloc -Wl,--wrap=mallocz -Wl,--wrap=free \
	-Wl,--wrap=realloc -Wl,--wrap=calloc \
	-Wl,--allow-multiple-definition \
	-o o.emu $OBJS \
	-L$ROOT/Linux/riscv64/lib \
	-L/usr/lib/riscv64-linux-gnu \
	-linterp -ltk -lfreetype -lmath -ldraw -lmemlayer -lmemdraw \
	-lkeyring -lsec -lmp -l9 \
	-lX11 -lXext -lm -lpthread
cp -f o.emu $ROOT/Linux/riscv64/bin/emu
file o.emu
'

echo "== smoke =="
docker exec "$IMG" bash -lc '
qemu-riscv64 -L /usr/riscv64-linux-gnu /inferno/Linux/riscv64/bin/emu \
	-c0 /dis/sh.dis -c "echo x11-emu-ok"
'
exec "$ROOT/emu/Linux/smoke-x11.sh"