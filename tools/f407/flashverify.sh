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
#	flashverify.sh /dev/cu.usbserial-XXXX [init]
#
# The optional second argument is the init to build, passed to mk as
# INIT=.  It is needed because this script BUILDS before it flashes, and
# building without the override silently reverts a station image to the
# shell one -- mk has no dependency on a variable, which has cost a
# wrong measurement here before.  It greps the generated prog.s to say
# which init the image really carries, rather than trusting the
# argument.
#
# AND IT CHECKS THE PROCESS COUNT AGAINST THE INIT, because the two have
# to agree and nothing else makes them.  armv7max25 attaches a packet
# device to #a, which starts three kprocs, and the board's config carries
# five -- enough for a shell image and two short for a station.  At five
# the station prints "addr N0CALL-1" and then "no procs for kproc"
# forever, which is a board that looks like it booted.  The number is
# nprocwanted in the config, beside main_pool_pcnt; there is no second
# config file for a station because the format has no include and three
# hundred duplicated lines would drift.  So it is two edits, and this
# refuses to flash the half of them.
#
# The board is reset from its own console with ^R twice running
# (os/inferno/port/devuart.c handles it in the uart receive interrupt),
# so nothing has to be touched.
#
PORT=${1:?usage: flashverify.sh <tty>}
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
export PATH="$ROOT/MacOSX/arm64/bin:$PATH"

INIT=$2
if [ -n "$INIT" ]; then
	rm -f os/inferno/stm32f407/stm32f407.prog.* \
	      os/inferno/stm32f407/stm32f407.xipmod.* \
	      os/inferno/stm32f407/stm32f407.root.*
	STAMP=$(cd os/inferno/stm32f407 && mk INIT=$INIT istm32f407 2>&1 |
		sed -n "s/.*KERNDATE='\([0-9]*\).*/\1/p" | tail -1)
else
	STAMP=$(cd os/inferno/stm32f407 && mk istm32f407 2>&1 |
		sed -n "s/.*KERNDATE='\([0-9]*\).*/\1/p" | tail -1)
fi
case "$INIT" in
*ax25*)	WANTPROC=7 ;;
*)	WANTPROC= ;;
esac
CARRIES=$(grep -o "from \.\./init/[a-z0-9]*\.dis" \
	os/inferno/stm32f407/stm32f407.prog.s | sort -u | head -1)
echo "flashverify: the image carries $CARRIES"
if [ -n "$INIT" ] && [ "$CARRIES" != "from ../init/$INIT.dis" ]; then
	echo "FLASHVERIFY-FAILED asked for $INIT and the image carries"
	echo "$CARRIES -- mk kept a generated table from a previous build"
	exit 1
fi
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

# STALE CLIENTS FIRST, AND THIS IS THE ROOT CAUSE OF THE DAY'S THREE
# AMBIGUOUS FLASHES.  open_dev() in mikroe-uhb's hid/generic.py loops
# forever waiting for VID/PID 0x1234/0x0001, and that match says nothing
# about which board or which hex.  Two clients left over from earlier
# backgrounded invocations -- one for hours -- grabbed the bootloader
# whenever it appeared and wrote THEIR file, while the client just
# started went on waiting.  So this clears them rather than leaving
# somebody to remember: a pkill from outside would kill this script's own
# client instead, which is how the first attempt at this ended with
# "Terminated: 15" in its log.
if pgrep -f "mikroe-uhb" > /dev/null 2>&1; then
	echo "flashverify: clearing stale mikroe-uhb clients"
	pkill -f "mikroe-uhb"
	sleep 1
fi

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
python3 - "$PORT" "$STAMP" "$WANTPROC" <<'PY'
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
need = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None
if need:
    if p is None:
        print("FLASHVERIFY-FAILED the boot line did not say nproc, so the"
              " process count cannot be checked")
        raise SystemExit(1)
    if int(p[-1]) < int(need):
        print("FLASHVERIFY-FAILED this init needs nproc %s and the image has"
              " %s." % (need, p[-1]))
        print("Set nprocwanted in os/inferno/stm32f407/stm32f407 and build"
              " again: at %s the station reaches \"addr\" and then \"no procs"
              " for kproc\" forever, which looks like a board that booted."
              % p[-1])
        raise SystemExit(1)
print("FLASHVERIFY-OK")
PY
