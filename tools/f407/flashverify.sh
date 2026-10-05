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
# AND IT CHECKS THE PROCESS COUNT THE BOARD REPORTS against the one the
# image was built to want.  armv7max25 attaches a packet device to #a,
# which starts three kprocs, and five slots -- enough for a shell image
# -- is two short for a station: it prints "addr N0CALL-1" and then "no
# procs for kproc" forever, which is a board that looks like it booted.
#
# This check was written when the count was a literal in the config and a
# station image was two edits in two files with nothing connecting them.
# It is now NPROC in os/inferno/stm32f407/image-<init>, beside the XIP
# list, because both are properties of the init; the mkfile passes it in
# as NPROCWANTED and this reads it from the same file.  So the check can
# no longer catch a mismatched pair, and what it still catches is a
# board running an image other than the one just built -- a generated
# config .c left over from a previous build, which has happened here.
#
# The board is reset from its own console with ^R twice running
# (os/inferno/port/devuart.c handles it in the uart receive interrupt),
# so nothing has to be touched.
#
PORT=${1:?usage: flashverify.sh <tty>}

# ONE AT A TIME, which clearing stale clients at startup does not give.
#
# A lock, because the clearing below is not enough and the reason is this
# script's own use: run in the background, two invocations overlap, and
# the second clears the FIRST one's client -- mid-write, with the board
# in its bootloader.  Whichever client is alive when a bootloader appears
# then writes whatever hex it was given, which may be several builds old.
#
# That is how both boards came to be running an image from the previous
# day while five flashes in a row reported a bootloader, printed a
# summary and exited zero.  The guard below caught every one of them;
# what it could not say was that the cause was upstream in the flashing
# and not in the board.
if ! mkdir /tmp/flashverify.lock 2>/dev/null; then
	echo "flashverify: /tmp/flashverify.lock exists, so another run is"
	echo "in progress or one died holding it.  Two at once write each"
	echo "other's images to whichever board enters its bootloader."
	echo "FLASHVERIFY-FAILED not the only run"
	exit 1
fi
trap 'rmdir /tmp/flashverify.lock 2>/dev/null' 0 1 2 3 15

cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
export PATH="$ROOT/MacOSX/arm64/bin:$PATH"

INIT=$2

# ASK FOR THE HEX, NOT THE KERNEL, AND KEEP THE WHOLE BUILD LOG.
#
# This used to build istm32f407 and then flash istm32f407.hex, which are
# two different files, and it read one thing out of the build output --
# KERNDATE -- with a sed that cannot fail.  The kernel built; the
# conversion to hex refused the image for being too big; and this
# printed "built, kerndate <new>" and flashed a hex from an earlier
# build.  Five times.  The board was reporting the truth all along.
#
# So: the target is the hex, because the hex is what gets written to the
# board; the status of the build is checked; and the log is searched for
# diagnostics rather than for the one line that was wanted.  See the
# mkfile beside the config for the other half of this.
BUILDLOG=/tmp/fv-build-$$.log
if [ -n "$INIT" ]; then
	rm -f os/inferno/stm32f407/stm32f407.prog.* \
	      os/inferno/stm32f407/stm32f407.xipmod.* \
	      os/inferno/stm32f407/stm32f407.root.*
	(cd os/inferno/stm32f407 && mk INIT=$INIT istm32f407.hex) \
		> $BUILDLOG 2>&1
else
	(cd os/inferno/stm32f407 && mk istm32f407.hex) > $BUILDLOG 2>&1
fi
brc=$?
if [ "$brc" != 0 ]; then
	echo "flashverify: the build exited $brc; its last lines were"
	tail -12 $BUILDLOG | sed 's/^/    /'
	echo "FLASHVERIFY-FAILED the build did not produce a hex"
	rm -f $BUILDLOG
	exit 1
fi
rm -f $BUILDLOG
HEXF=$ROOT/os/inferno/stm32f407/istm32f407.hex
ELFF=$ROOT/os/inferno/stm32f407/istm32f407

# THE STAMP COMES FROM BESIDE THE IMAGE, not out of the build output.
#
# Scraping KERNDATE from what mk printed works only on a build that
# relinked the kernel, and the build that matters is the one right after
# a refused conversion: the kernel is already current, only the hex is
# remade, nothing prints a stamp, and the comparison that catches an old
# image on the board was skipped exactly when it was needed.  The mkfile
# writes the stamp it compiled in to istm32f407.date; this reads that,
# and insists on it.
if [ ! -f "$ELFF.date" ]; then
	echo "FLASHVERIFY-FAILED no $ELFF.date, so the stamp this image"
	echo "prints is unknown and the flash cannot be verified"
	exit 1
fi
STAMP=$(cat "$ELFF.date")
if [ -z "$STAMP" ]; then
	echo "FLASHVERIFY-FAILED $ELFF.date is empty"
	exit 1
fi
if [ ! -f "$HEXF" ]; then
	echo "FLASHVERIFY-FAILED mk exited zero and there is no hex"
	exit 1
fi
# And older than the kernel beside it is the same fault wearing a
# success: the mkfile now removes the hex when it cannot make one, but
# this costs nothing and does not depend on that staying true.
if [ -n "$(find "$ELFF" -newer "$HEXF" 2>/dev/null)" ]; then
	echo "FLASHVERIFY-FAILED the hex is older than the kernel beside it,"
	echo "so it is from an earlier build and must not be flashed"
	exit 1
fi
# The process count this init needs, read from the same file the BUILD
# reads it from, so that this cannot disagree with the image.  It used to
# be a hardcoded 7 for anything matching *ax25*, which is a second place
# to remember a number.
if [ -n "$INIT" ]; then
	WANTPROC=$(sed -n 's/^NPROC=\([0-9]*\).*/\1/p' \
		os/inferno/stm32f407/image-$INIT 2>/dev/null)
else
	WANTPROC=
fi
CARRIES=$(grep -o "from \.\./init/[a-z0-9]*\.dis" \
	os/inferno/stm32f407/stm32f407.prog.s | sort -u | head -1)
echo "flashverify: the image carries $CARRIES"
if [ -n "$INIT" ] && [ "$CARRIES" != "from ../init/$INIT.dis" ]; then
	echo "FLASHVERIFY-FAILED asked for $INIT and the image carries"
	echo "$CARRIES -- mk kept a generated table from a previous build"
	exit 1
fi
echo "flashverify: built, kerndate $STAMP"

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

# STALE CLIENTS, WHICH THE LOCK MAKES MEANINGFUL: with one run at a time
# anything still alive here is genuinely orphaned.  open_dev() in mikroe-uhb's hid/generic.py loops
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

# IF NO BOOTLOADER CAME, KILL THE CLIENT RATHER THAN WAIT FOR IT.
#
# open_dev() in mikroe-uhb's hid/generic.py loops forever waiting for
# VID/PID 0x1234/0x0001, so a board that never enters its bootloader
# leaves this script blocked in "wait" with nothing on its stdout and
# the lock held.  It sat there for fifteen minutes with an empty client
# log before I thought to look at the process list.
#
# A board that will not enter its bootloader in six resets is a result,
# not something to go on waiting for.
if ! grep -q "McuType" /tmp/fv-$$.log 2>/dev/null; then
	kill $FL 2>/dev/null
	wait $FL 2>/dev/null
	echo "FLASHVERIFY-FAILED no bootloader appeared after six resets."
	echo "The console given was $PORT; check it is the board's and not"
	echo "another board's -- a reset stuffed into the wrong session"
	echo "looks exactly like this.  What that console last said:"
	rm -f /tmp/fv-$$.log
	exit 1
fi
wait $FL
rc=$?
grep -E "McuType|BootStart" /tmp/fv-$$.log || true
# THE CLIENT'S OWN EXIT STATUS, which this captured and then ignored.
#
# Five flashes of one board have now ended with a bootloader answering,
# mikroe-uhb printing McuType and BootStart, and the board still running
# the image it had before.  A client that printed its summary and then
# failed looks identical here to one that succeeded, because the only
# thing read out of its log was that summary -- and the summary is
# printed when it attaches, not when it finishes.
#
# So: the status, and on anything but zero the end of its log, which is
# the one place the reason can be.
if [ "$rc" != 0 ]; then
	echo "flashverify: the client exited $rc; its last lines were"
	grep -v "^DEBUG:mikroeuhb.device:send data:" /tmp/fv-$$.log |
		tail -8 | sed 's/^/    /'
fi
rm -f /tmp/fv-$$.log
if [ "$rc" != 0 ]; then
	echo "FLASHVERIFY-FAILED the client did not succeed"
	exit 1
fi

# And the board's own account.  This is the whole point.
# The station check is keyed on the INIT, not on there being a process
# count.  It used to be "if need:", and need is the process count, which
# every image has now that image-<init> carries it -- so a mission image
# was about to be failed for not printing a line only a station prints.
case "$INIT" in
*ax25*)	WANTCAL=1 ;;
*)	WANTCAL= ;;
esac
python3 - "$PORT" "$STAMP" "$WANTPROC" "$WANTCAL" <<'PY'
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
# AND, FOR A STATION, THAT IT APPLIED ITS CALIBRATION.
#
# armv7max25 soft-fails every calibration path on purpose -- it prints
# why and carries on, because a station that will not start is no better
# than one on the wrong frequency.  But these two boards are 64ppm
# apart, which at 915MHz is about 59kHz, and at 1200-baud 2-FSK that is
# no link at all.  A station running the driver's defaults therefore
# boots clean, prints its address, beacons, hears nothing, and looks
# exactly like a path that does not close -- which is the thing a
# cabled run exists to rule out.  So the applied figure is part of
# "flashed", not something to notice afterwards.
wantcal = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else None
if wantcal:
    t = b.text()
    if "ax25init: ppm " not in t:
        why = [l for l in t.split("\n") if l.startswith("ax25init:")]
        print("FLASHVERIFY-FAILED the station did not apply a ppm"
              " correction, so it is on the driver's default crystal.")
        print("What it said about calibration:")
        for l in why[-6:]:
            print("    " + l)
        raise SystemExit(1)
    for l in t.split("\n"):
        if l.startswith("ax25init: ppm ") or l.startswith("ax25init: uid "):
            print("flashverify: " + l.strip())
print("FLASHVERIFY-OK")
PY
