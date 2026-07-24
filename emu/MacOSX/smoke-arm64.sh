#!/bin/sh
# Quick regression smoke for MacOSX/arm64 Cocoa emu.
#	emu/MacOSX/smoke-arm64.sh

set -e
ROOT=${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PATH="$ROOT/MacOSX/arm64/bin:$PATH"
EMU="$ROOT/MacOSX/arm64/bin/emu"
DISROOT="/tmp/smoke-arm64.dis"
DISHOST="$ROOT$DISROOT"

if [ ! -x "$EMU" ]; then
	echo "smoke: missing $EMU — build with: (cd emu/MacOSX && mk CONF=emu-cocoa install)" >&2
	exit 1
fi

codesign -v "$EMU" 2>/dev/null || {
	echo "smoke: $EMU not signed — reinstall emu-cocoa" >&2
	exit 1
}

cat > /tmp/smoke-arm64.b <<'EOF'
implement Smoke;
include "sys.m";
	sys: Sys;
include "draw.m";
Smoke: module {
	init: fn(nil: ref Draw->Context, nil: list of string);
};
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

	fd = sys->open("/dev/user", Sys->OREAD);
	n = sys->read(fd, buf, len buf);
	sys->print("user=%s", string buf[0:n]);

	if(sys->open("/dev/audioctl", Sys->OREAD) == nil){
		sys->fprint(sys->fildes(2), "no /dev/audioctl\n");
		raise "fail:audio";
	}

	s := "abcdef";
	if(s[0] != 'a' || s[5] != 'f'){
		sys->fprint(sys->fildes(2), "IINDC bad\n");
		raise "fail:indc";
	}
	sys->print("ok\n");
}
EOF

mkdir -p "$ROOT/tmp"
limbo -I "$ROOT/module" -o "$DISHOST" /tmp/smoke-arm64.b

echo "== JIT =="
out=$(cd "$ROOT" && "$EMU" "$DISROOT")
echo "$out"
echo "$out" | grep -q 'jit=1' || { echo "smoke: expected jit=1" >&2; exit 1; }
echo "$out" | grep -q 'ok' || { echo "smoke: missing ok" >&2; exit 1; }

echo "== interpreter =="
out=$(cd "$ROOT" && "$EMU" -c0 "$DISROOT")
echo "$out"
echo "$out" | grep -q 'jit=0' || { echo "smoke: expected jit=0" >&2; exit 1; }

echo "smoke: PASS"
