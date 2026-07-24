#!/bin/sh
# Smoke Linux/riscv64 console emu under qemu-user (Docker).
#	emu/Linux/smoke-riscv64.sh
set -e

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
IMG=${INFERNO_RV_IMG:-inferno-rvbuild}
export PATH="$ROOT/MacOSX/arm64/bin:$PATH"

DISROOT="/tmp/smoke-riscv64.dis"
DISHOST="$ROOT$DISROOT"

if [ ! -x "$ROOT/MacOSX/arm64/bin/limbo" ]; then
	echo "smoke: need host limbo at MacOSX/arm64/bin/limbo" >&2
	exit 1
fi

cat > /tmp/smoke-riscv64.b <<'EOF'
implement Smoke;
include "sys.m";
	sys: Sys;
include "draw.m";
Smoke: module {
	init: fn(nil: ref Draw->Context, nil: list of string);
	add: fn(a, b: int): int;
	fadd: fn(a, b: real): real;
};
add(a, b: int): int
{
	return a + b;
}
fadd(a, b: real): real
{
	return a + b;
}
init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	fd := sys->open("/dev/jit", Sys->OREAD);
	if(fd == nil){
		sys->fprint(sys->fildes(2), "no /dev/jit\n");
		raise "fail:jit";
	}
	buf := array[8] of byte;
	n := sys->read(fd, buf, len buf);
	sys->print("jit=%s", string buf[0:n]);

	s := "abcdef";
	if(s[0] != 'a' || s[5] != 'f'){
		sys->fprint(sys->fildes(2), "IINDC bad\n");
		raise "fail:indc";
	}

	x := 0;
	for(i := 0; i < 100; i++)
		x += i;
	if(x != 4950){
		sys->fprint(sys->fildes(2), "loop bad %d\n", x);
		raise "fail:loop";
	}

	if(add(40, 2) != 42){
		sys->fprint(sys->fildes(2), "call bad\n");
		raise "fail:call";
	}

	r := fadd(1.5, 2.25);
	if(r < 3.74 || r > 3.76){
		sys->fprint(sys->fildes(2), "fp bad %g\n", r);
		raise "fail:fp";
	}

	# big/little compare + branch
	if(100 < 3 || 3 > 100 || 5 == 6 || 5 != 5){
		sys->fprint(sys->fildes(2), "cmp bad\n");
		raise "fail:cmp";
	}

	sys->print("ok\n");
}
EOF

mkdir -p "$ROOT/tmp"
limbo -I "$ROOT/module" -o "$DISHOST" /tmp/smoke-riscv64.b

if ! docker inspect "$IMG" >/dev/null 2>&1; then
	echo "smoke: missing container $IMG — run emu/Linux/cross-riscv64.sh first" >&2
	exit 1
fi
docker start "$IMG" >/dev/null

docker exec "$IMG" bash -lc '
set -e
ROOT=/inferno
EMU=$ROOT/Linux/riscv64/bin/emu-g
test -x "$EMU"
QEMU="qemu-riscv64 -L /usr/riscv64-linux-gnu"
DIS=tmp/smoke-riscv64.dis
echo "== JIT =="
out=$(timeout 40 $QEMU "$EMU" -r$ROOT -c1 $DIS 2>&1)
echo "$out"
echo "$out" | grep -q "jit=1" || { echo "expected jit=1"; exit 1; }
echo "$out" | grep -q "ok" || { echo "missing ok"; exit 1; }
echo "== interpreter =="
out=$(timeout 40 $QEMU "$EMU" -r$ROOT -c0 $DIS 2>&1)
echo "$out"
echo "$out" | grep -q "jit=0" || { echo "expected jit=0"; exit 1; }
echo "$out" | grep -q "ok" || { echo "missing ok"; exit 1; }
echo "smoke: PASS"
'
