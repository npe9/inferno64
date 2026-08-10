#!/bin/sh
# Validate Inferno -c0..-c9 semantics on MacOSX/arm64.
#
# Expected (from load.c + comp-arm64.c):
#	cflag==0	interpreter (unless MUSTCOMPILE)
#	cflag!=0	JIT compile on load
#	cflag>3 i.e. >=4	print compile summaries (dis=/arm64=/mmap=)
#	cflag>4 i.e. >=5	print das() + TRAP:/macro dumps
#	/dev/jit		echoes the numeric cflag
#
#	./emu/MacOSX/validate-jit-levels.sh
set -e

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
export PATH="$ROOT/MacOSX/arm64/bin:$PATH"
EMU="$ROOT/MacOSX/arm64/bin/emu-g"
DIS="/tmp/jit-levels.dis"
HOSTDIS="$ROOT$DIS"
fail=0

if [ ! -x "$EMU" ]; then
	echo "missing $EMU" >&2
	exit 1
fi

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

check() {
	c=$1
	out=$(cd "$ROOT" && timeout 45 "$EMU" -v -c"$c" "$DIS" 2>&1) || {
		echo "c$c: FAIL run/timeout"
		fail=1
		return
	}
	flat=$(printf '%s' "$out" | tr '\n' ' ')

	# 1) /dev/jit mirrors cflag; functional body ran
	echo "$flat" | grep -q "jit=$c" || { echo "c$c: FAIL /dev/jit want jit=$c"; fail=1; return; }
	echo "$flat" | grep -q "ok" || { echo "c$c: FAIL missing ok"; fail=1; return; }

	# 2) -v mode string
	if [ "$c" = 0 ]; then
		echo "$out" | head -1 | grep -q " interp$" || {
			echo "c$c: FAIL -v banner should say interp"
			echo "$out" | head -1
			fail=1
			return
		}
	else
		echo "$out" | head -1 | grep -q " compile$" || {
			echo "c$c: FAIL -v banner should say compile"
			echo "$out" | head -1
			fail=1
			return
		}
	fi

	# 3) diagnostic thresholds
	has_summary=0
	echo "$out" | grep -q "dis=" && has_summary=1
	echo "$out" | grep -q "arm64=" && has_summary=1
	has_trap=0
	echo "$out" | grep -q "^TRAP:" && has_trap=1
	has_das=0
	# das-arm64 lines look like: <addr>  <hex>  <mnemonic>
	echo "$out" | grep -E -q '[[:space:]][0-9a-f]+[[:space:]]+[0-9a-f]{8}[[:space:]]+(add|ldr|str|mov|b\.|ret|nop)' && has_das=1

	if [ "$c" -eq 0 ]; then
		[ "$has_summary" -eq 0 ] || { echo "c$c: FAIL unexpected JIT summary in interp mode"; fail=1; return; }
		[ "$has_trap" -eq 0 ] || { echo "c$c: FAIL unexpected TRAP: in interp mode"; fail=1; return; }
		[ "$has_das" -eq 0 ] || { echo "c$c: FAIL unexpected das in interp mode"; fail=1; return; }
	elif [ "$c" -le 3 ]; then
		[ "$has_summary" -eq 0 ] || { echo "c$c: FAIL summary only for cflag>3"; fail=1; return; }
		[ "$has_trap" -eq 0 ] || { echo "c$c: FAIL TRAP: only for cflag>4"; fail=1; return; }
		[ "$has_das" -eq 0 ] || { echo "c$c: FAIL das only for cflag>4"; fail=1; return; }
	elif [ "$c" -eq 4 ]; then
		[ "$has_summary" -eq 1 ] || { echo "c$c: FAIL expected dis=/arm64= summary"; fail=1; return; }
		[ "$has_trap" -eq 0 ] || { echo "c$c: FAIL TRAP: should start at c5"; fail=1; return; }
		[ "$has_das" -eq 0 ] || { echo "c$c: FAIL das should start at c5"; fail=1; return; }
		# prove Smoke itself was compiled
		echo "$out" | grep -q "Smoke" || { echo "c$c: FAIL summary missing Smoke module"; fail=1; return; }
	else
		# c >= 5
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
echo "validate-jit-levels: PASS (arm64 semantics ok)"
