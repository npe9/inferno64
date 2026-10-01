#!/bin/sh
#
# Flash one board and PROVE it is running what was flashed.
#
# Three times in one day a flash reported success and the board was
# running the previous kernel, and once it reported nothing at all while
# the client sat waiting for a bootloader that never appeared.  Each time
# the next measurement was taken against the wrong image, and twice the
# measurement was what caught it -- the second time only by luck.
#
# A flash tool reports that it wrote bytes to a device it found.  It does
# not know which board that was: the HID bootloader is matched on
# 0x1234/0x0001 and two boards look identical to it.  So the only
# evidence is the board's own account of itself afterwards, and the
# kernel prints one -- "conf stm32f407 (<kerndate>)" on its boot line,
# where kerndate is recompiled with the image.  This builds, keeps the
# stamp, flashes, and then reads the boot line back.
#
#	flashverify.sh /dev/cu.usbserial-XXXX
#
# The board is reset from its own console with ^R twice running
# (os/inferno/port/devuart.c handles it in the uart receive interrupt),
# so nothing has to be touched.
#
PORT=${1:?usage: flashverify.sh <tty>}
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
export PATH="$ROOT/MacOSX/arm64/bin:$PATH"

STAMP=$(cd os/inferno/stm32f407 && mk istm32f407 2>&1 |
	sed -n "s/.*KERNDATE='\([0-9]*\).*/\1/p" | tail -1)
if [ -z "$STAMP" ]; then
	# nothing was rebuilt, so the stamp is whatever the image carries
	# already; read it off the board after and compare to itself
	echo "flashverify: nothing to rebuild; the stamp cannot be checked"
	echo "flashverify: touch a source and run again if that matters"
fi
[ -n "$STAMP" ] && echo "flashverify: built, kerndate $STAMP"

SESS=$(python3 - "$PORT" <<'PY'
import re, subprocess, sys
pids = subprocess.run(["lsof", "-t", sys.argv[1]],
                      capture_output=True, text=True).stdout.split()
out = subprocess.run(["screen", "-ls"], capture_output=True, text=True).stdout
for s in re.findall(r"(\d+\.ttys\d+\.\S+)", out):
    if s.split(".")[0] in pids:
        print(s)
        break
PY
)

HEX=$ROOT/os/inferno/stm32f407/istm32f407.hex
"$ROOT/tools/f407/flash.sh" ~/src/mikroe-uhb \
	~/src/mikroe-uhb/venv/bin/python "$HEX" > /tmp/fv-$$.log 2>&1 &
FL=$!
sleep 3

# ^R twice running, nothing between: any other character disarms it.
reset() {
	if [ -n "$SESS" ]; then
		screen -S "$SESS" -X stuff "$(printf '\022')"
		sleep 0.2
		screen -S "$SESS" -X stuff "$(printf '\022')"
	else
		python3 -c "
import os,sys,time
sys.path.insert(0,'$ROOT/tools/f407')
import console
fd = console.open_port('$PORT')
for _ in range(2):
    os.write(fd, b'\022'); time.sleep(0.2)
"
	fi
}

# Tried more than once, because board 2's console input has failed and
# recovered before -- see doc/radio-plan.ms -- and a reset that does not
# arrive looks exactly like a board that will not enter its bootloader.
n=0
while [ $n -lt 6 ]; do
	reset
	i=0
	while [ $i -lt 10 ]; do
		if grep -q "McuType" /tmp/fv-$$.log 2>/dev/null; then
			break 2
		fi
		sleep 2
		i=$((i+1))
	done
	n=$((n+1))
	echo "flashverify: no bootloader yet, resetting again ($n)"
done
wait $FL
rc=$?
grep -E "McuType|BootStart" /tmp/fv-$$.log || true
if ! grep -q McuType /tmp/fv-$$.log; then
	echo "FLASHVERIFY-FAILED no bootloader appeared"
	rm -f /tmp/fv-$$.log
	exit 1
fi
rm -f /tmp/fv-$$.log

# And the board's own account.  This is the whole point.
python3 - "$PORT" "$STAMP" <<'PY'
import re, sys, time
sys.path.insert(0, "tools/radio")
from twoboard import open_board
b = open_board(sys.argv[1], "board")
want = sys.argv[2] if len(sys.argv) > 2 else ""
for _ in range(10):
    time.sleep(3)
    t = b.text()
    m = re.findall(r"conf stm32f407 \((\d+)\)", t)
    if m and (not want or m[-1] == want):
        break
m = re.findall(r"conf stm32f407 \((\d+)\)", b.text())
got = m[-1] if m else None
p = re.findall(r"procinit conf.nproc (\d+)", b.text())
print("flashverify: the board says kerndate %s, nproc %s"
      % (got, p[-1] if p else "?"))
if want and got != want:
    print("FLASHVERIFY-FAILED built %s, the board is running %s" % (want, got))
    raise SystemExit(1)
print("FLASHVERIFY-OK")
PY
