#!/bin/sh
# Broad functional acceptance for Linux/riscv64 hosted Inferno (qemu-user).
#	./emu/Linux/suite-riscv64.sh
set -e

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
IMG=${INFERNO_RV_IMG:-inferno-rvbuild}
export PATH="$ROOT/MacOSX/arm64/bin:$PATH"
fail=0

if [ ! -x "$ROOT/MacOSX/arm64/bin/limbo" ]; then
	echo "suite: need MacOSX/arm64 limbo" >&2
	exit 1
fi
if ! docker inspect "$IMG" >/dev/null 2>&1; then
	echo "suite: need container $IMG (run cross-riscv64.sh)" >&2
	exit 1
fi
docker start "$IMG" >/dev/null

mkdir -p "$ROOT/tmp/suite-rv"
SUITEDIR="$ROOT/tmp/suite-rv"

# --- Limbo programs exercising core runtime ---
cat > "$SUITEDIR/arith.b" <<'EOF'
implement T;
include "sys.m"; sys: Sys;
include "draw.m";
T: module { init: fn(nil: ref Draw->Context, nil: list of string); };
init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	x := 0;
	for(i := 1; i <= 1000; i++)
		x += i;
	if(x != 500500){ sys->print("FAIL arith %d\n", x); raise "fail"; }
	sys->print("PASS arith\n");
}
EOF

cat > "$SUITEDIR/string.b" <<'EOF'
implement T;
include "sys.m"; sys: Sys;
include "draw.m";
T: module { init: fn(nil: ref Draw->Context, nil: list of string); };
init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	s := "Inferno-riscv64";
	if(len s != 15 || s[0] != 'I' || s[14] != '4'){
		sys->print("FAIL string\n"); raise "fail";
	}
	a := array[3] of { "a", "b", "c" };
	if(a[1] != "b"){ sys->print("FAIL array\n"); raise "fail"; }
	sys->print("PASS string\n");
}
EOF

cat > "$SUITEDIR/math.b" <<'EOF'
implement T;
include "sys.m"; sys: Sys;
include "draw.m";
include "math.m";
T: module { init: fn(nil: ref Draw->Context, nil: list of string); };
init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	math := load Math Math->PATH;
	if(math == nil){ sys->print("FAIL load Math: %r\n"); raise "fail"; }
	r := math->sqrt(2.0);
	if(r < 1.414 || r > 1.415){ sys->print("FAIL sqrt %g\n", r); raise "fail"; }
	sys->print("PASS math\n");
}
EOF

cat > "$SUITEDIR/modload.b" <<'EOF'
implement T;
include "sys.m"; sys: Sys;
include "draw.m";
include "string.m";
include "bufio.m";
T: module { init: fn(nil: ref Draw->Context, nil: list of string); };
init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	str := load String String->PATH;
	bio := load Bufio Bufio->PATH;
	if(str == nil || bio == nil){
		sys->print("FAIL load libs %r\n"); raise "fail";
	}
	sys->print("PASS modload\n");
}
EOF

cat > "$SUITEDIR/fileio.b" <<'EOF'
implement T;
include "sys.m"; sys: Sys;
include "draw.m";
T: module { init: fn(nil: ref Draw->Context, nil: list of string); };
init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	path := "/tmp/suite-rv/io.txt";
	fd := sys->create(path, Sys->OWRITE, 8r666);
	if(fd == nil){ sys->print("FAIL create: %r\n"); raise "fail"; }
	sys->fprint(fd, "hello-riscv\n");
	fd = sys->open(path, Sys->OREAD);
	if(fd == nil){ sys->print("FAIL open: %r\n"); raise "fail"; }
	buf := array[64] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 11 || string buf[0:11] != "hello-riscv"){
		sys->print("FAIL read\n"); raise "fail";
	}
	sys->print("PASS fileio\n");
}
EOF

cat > "$SUITEDIR/callfp.b" <<'EOF'
implement T;
include "sys.m"; sys: Sys;
include "draw.m";
T: module {
	init: fn(nil: ref Draw->Context, nil: list of string);
	add: fn(a, b: int): int;
	fmul: fn(a, b: real): real;
};
add(a, b: int): int { return a+b; }
fmul(a, b: real): real { return a*b; }
init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	if(add(20, 22) != 42){ sys->print("FAIL call\n"); raise "fail"; }
	r := fmul(1.5, 4.0);
	if(r < 5.9 || r > 6.1){ sys->print("FAIL fmul %g\n", r); raise "fail"; }
	sys->print("PASS callfp\n");
}
EOF


cat > "$SUITEDIR/spawn.b" <<'EOF'
implement T;
include "sys.m"; sys: Sys;
include "draw.m";
include "sh.m";
T: module { init: fn(nil: ref Draw->Context, nil: list of string); };
init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	sh := load Sh Sh->PATH;
	if(sh == nil){ sys->print("FAIL load sh: %r\n"); raise "fail"; }
	err := sh->system(nil, "echo spawn-ok");
	if(err != nil){ sys->print("FAIL sh system: %s\n", err); raise "fail"; }
	sys->print("PASS spawn\n");
}
EOF


for b in arith string math modload fileio callfp spawn; do
	limbo -I "$ROOT/module" -o "$SUITEDIR/$b.dis" "$SUITEDIR/$b.b"
done

echo "== hosted suite (qemu-user) =="
docker exec "$IMG" bash -lc '
set -e
ROOT=/inferno
EMU=$ROOT/Linux/riscv64/bin/emu-g
QEMU="qemu-riscv64 -L /usr/riscv64-linux-gnu"
S=/inferno/tmp/suite-rv
fail=0
run1() {
	mode=$1; dis=$2; expect=$3
	# Paths are Inferno-root relative (see -r$ROOT)
	out=$(timeout 45 $QEMU "$EMU" -r$ROOT -$mode "$dis" 2>&1) || {
		echo "FAIL $mode $dis (timeout/crash)"
		echo "$out" | tail -10
		fail=1
		return
	}
	if echo "$out" | grep -q "$expect"; then
		echo "PASS $mode $(basename $dis)"
	else
		echo "FAIL $mode $(basename $dis) missing $expect"
		echo "$out" | tail -15
		fail=1
	fi
}

# JIT and interp for each program
for p in arith string math modload fileio callfp spawn; do
	run1 c1 tmp/suite-rv/$p.dis "PASS $p"
	run1 c0 tmp/suite-rv/$p.dis "PASS $p"
done

# shell builtins / fs
out=$(timeout 30 $QEMU "$EMU" -r$ROOT -c1 /dis/sh.dis -c "echo suite-sh-ok; ls /dis/sh.dis" 2>&1) || true
echo "$out" | grep -q suite-sh-ok && echo "PASS sh" || { echo "FAIL sh"; echo "$out"; fail=1; }

# echo.dis if present
if [ -f $ROOT/dis/echo.dis ]; then
	out=$(timeout 20 $QEMU "$EMU" -r$ROOT -c1 /dis/echo.dis hello-echo 2>&1) || true
	echo "$out" | grep -q hello-echo && echo "PASS echo.dis" || { echo "FAIL echo.dis"; fail=1; }
fi

if [ "$fail" -ne 0 ]; then
	echo "suite-riscv64: FAIL" >&2
	exit 1
fi
echo "suite-riscv64: PASS"
'
