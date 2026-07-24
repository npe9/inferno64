#!/bin/sh
# Smoke Linux/riscv64 X11 emu under Xvfb (Docker inferno-rvbuild).
# Checks /dev/pointer is bound and that wm creates an Inferno X11 window.
#	./emu/Linux/smoke-x11.sh
set -e

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
IMG=inferno-rvbuild
EMU=/inferno/Linux/riscv64/bin/emu

if ! docker inspect "$IMG" >/dev/null 2>&1; then
	echo "smoke-x11: need $IMG (run ./emu/Linux/cross-emu-x11.sh)" >&2
	exit 1
fi
docker start "$IMG" >/dev/null

docker exec "$IMG" bash -lc "
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq xvfb x11-utils >/dev/null
pkill Xvfb 2>/dev/null || true
Xvfb :99 -screen 0 1024x768x24 >/tmp/xvfb.log 2>&1 &
sleep 1
export DISPLAY=:99

qemu-riscv64 -L /usr/riscv64-linux-gnu $EMU -c0 /dis/wm/wm.dis \
	>/tmp/wm.out 2>/tmp/wm.err &
EPID=\$!
sleep 3
xwininfo -root -tree > /tmp/xwin.out 2>&1
kill \$EPID 2>/dev/null || true
wait \$EPID 2>/dev/null || true

# colors exercised writepixels; LP64 sizeof(ulong) stride bug crashed here.
qemu-riscv64 -L /usr/riscv64-linux-gnu $EMU -c0 /dis/wm/wm.dis wm/colors \
	>/tmp/colors.out 2>/tmp/colors.err &
CPID=\$!
sleep 4
kill \$CPID 2>/dev/null || true
wait \$CPID 2>/dev/null || true
pkill Xvfb 2>/dev/null || true

if grep -q 'cannot open /dev/pointer' /tmp/wm.err; then
	echo 'FAIL: /dev/pointer not bound (rebuild main.o / cross-emu-x11.sh)' >&2
	cat /tmp/wm.err >&2
	exit 1
fi
if ! grep -qi inferno /tmp/xwin.out; then
	echo 'FAIL: no Inferno X11 window' >&2
	cat /tmp/wm.err /tmp/xwin.out >&2
	exit 1
fi
if grep -qE 'flushimage fail|segmentation violation' /tmp/colors.err; then
	echo 'FAIL: wm/colors crashed (rebuild libmemdraw with sizeof(u32) strides)' >&2
	cat /tmp/colors.err >&2
	exit 1
fi
echo 'PASS Linux/riscv64 X11 emu (pointer + wm + colors)'
"
