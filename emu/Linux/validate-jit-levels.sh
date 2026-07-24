#!/bin/sh
# Validate Inferno -c0..-c9 semantics on Linux/riscv64 under qemu-user (Docker).
#
# Same thresholds as arm64 (load.c + comp-riscv64.c):
#	cflag==0	interp banner; no JIT summaries/das
#	cflag!=0	compile banner; JIT on load
#	cflag>3 (>=4)	dis=/riscv64=/mmap= summaries
#	cflag>4 (>=5)	das() + TRAP:
#
#	./emu/Linux/validate-jit-levels.sh
set -e

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
IMG=${INFERNO_RV_IMG:-inferno-rvbuild}
export PATH="$ROOT/MacOSX/arm64/bin:$PATH"
DIS="/tmp/jit-levels.dis"
HOSTDIS="$ROOT$DIS"

cat > /tmp/jit-levels.b <<'EOF'
implement Smoke;
include "sys.m";
	sys: Sys;
include "draw.m";
Smoke: module {
	init: fn(nil: ref Draw->Context, nil: list of string);
	add: fn(a, b: int): int;
	fadd: fn(a, b: real): real;
};
add(a, b: int): int { return a + b; }
fadd(a, b: real): real { return a + b; }
init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	fd := sys->open("/dev/jit", Sys->OREAD);
	if(fd == nil){ sys->fprint(sys->fildes(2), "no /dev/jit\n"); raise "fail:jit"; }
	buf := array[8] of byte;
	n := sys->read(fd, buf, len buf);
	sys->print("jit=%s", string buf[0:n]);
	s := "abcdef";
	if(s[0] != 'a' || s[5] != 'f') raise "fail:indc";
	x := 0;
	for(i := 0; i < 100; i++) x += i;
	if(x != 4950) raise "fail:loop";
	if(add(40, 2) != 42) raise "fail:call";
	r := fadd(1.5, 2.25);
	if(r < 3.74 || r > 3.76) raise "fail:fp";
	sys->print("ok\n");
}
EOF
mkdir -p "$ROOT/tmp"
limbo -I "$ROOT/module" -o "$HOSTDIS" /tmp/jit-levels.b

if ! docker inspect "$IMG" >/dev/null 2>&1; then
	echo "missing container $IMG — run emu/Linux/cross-riscv64.sh first" >&2
	exit 1
fi
docker start "$IMG" >/dev/null

docker exec "$IMG" bash -lc '
set -e
ROOT=/inferno
EMU=$ROOT/Linux/riscv64/bin/emu-g
QEMU="qemu-riscv64 -L /usr/riscv64-linux-gnu"
DIS=tmp/jit-levels.dis
fail=0

check() {
	c=$1
	out=$(timeout 60 $QEMU "$EMU" -r$ROOT -v -c"$c" $DIS 2>&1) || {
		echo "c$c: FAIL run/timeout"
		fail=1
		return
	}
	flat=$(printf "%s" "$out" | tr "\n" " ")

	echo "$flat" | grep -q "jit=$c" || { echo "c$c: FAIL /dev/jit want jit=$c"; fail=1; return; }
	echo "$flat" | grep -q "ok" || { echo "c$c: FAIL missing ok"; fail=1; return; }

	if [ "$c" = 0 ]; then
		echo "$out" | head -1 | grep -q " interp$" || {
			echo "c$c: FAIL -v banner should say interp"; fail=1; return
		}
	else
		echo "$out" | head -1 | grep -q " compile$" || {
			echo "c$c: FAIL -v banner should say compile"; fail=1; return
		}
	fi

	has_summary=0
	echo "$out" | grep -q "dis=" && has_summary=1
	echo "$out" | grep -q "riscv64=" && has_summary=1
	has_trap=0
	echo "$out" | grep -q "^TRAP:" && has_trap=1
	has_das=0
	echo "$out" | grep -E -q "[[:space:]][0-9a-f]+[[:space:]]+[0-9a-f]{8}[[:space:]]+(addi|add|ld|sd|jalr|ret|nop|lui|beq|bne)" && has_das=1

	if [ "$c" -eq 0 ]; then
		[ "$has_summary" -eq 0 ] || { echo "c$c: FAIL unexpected JIT summary"; fail=1; return; }
		[ "$has_trap" -eq 0 ] || { echo "c$c: FAIL unexpected TRAP:"; fail=1; return; }
		[ "$has_das" -eq 0 ] || { echo "c$c: FAIL unexpected das"; fail=1; return; }
	elif [ "$c" -le 3 ]; then
		[ "$has_summary" -eq 0 ] || { echo "c$c: FAIL summary only for cflag>3"; fail=1; return; }
		[ "$has_trap" -eq 0 ] || { echo "c$c: FAIL TRAP: only for cflag>4"; fail=1; return; }
		[ "$has_das" -eq 0 ] || { echo "c$c: FAIL das only for cflag>4"; fail=1; return; }
	elif [ "$c" -eq 4 ]; then
		[ "$has_summary" -eq 1 ] || { echo "c$c: FAIL expected dis=/riscv64= summary"; fail=1; return; }
		[ "$has_trap" -eq 0 ] || { echo "c$c: FAIL TRAP: should start at c5"; fail=1; return; }
		[ "$has_das" -eq 0 ] || { echo "c$c: FAIL das should start at c5"; fail=1; return; }
		echo "$out" | grep -q "Smoke" || { echo "c$c: FAIL summary missing Smoke"; fail=1; return; }
	else
		[ "$has_summary" -eq 1 ] || { echo "c$c: FAIL expected summary"; fail=1; return; }
		[ "$has_trap" -eq 1 ] || { echo "c$c: FAIL expected TRAP:"; fail=1; return; }
		[ "$has_das" -eq 1 ] || { echo "c$c: FAIL expected das mnemonics"; fail=1; return; }
	fi
	echo "c$c: PASS"
}

for c in 0 1 2 3 4 5 6 7 8 9; do
	check "$c"
done
if [ "$fail" -ne 0 ]; then
	echo "validate-jit-levels: FAIL" >&2
	exit 1
fi
echo "validate-jit-levels: PASS (riscv64 semantics ok)"
'
