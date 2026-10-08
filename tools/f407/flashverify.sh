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

# AND AN OPTIONAL CONF, because the authenticating kernel is a different
# one.  $Keyring has to be in the conf's mod section for keyring(2) to
# load, declaring it costs 197K of flash, and armv7minit cannot absorb
# that -- so os/inferno/stm32f407/mkfile derives stm32f407auth from
# stm32f407 and this has to be able to build and flash it.  Everything
# downstream is named from $CONF so the hex, the ELF, the date stamp and
# the prog.s the init check greps all come from the same kernel.
CONF=${3:-stm32f407}

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
	# A DERIVED CONF HAS TO EXIST BEFORE MK PARSES ITS MKFILE.
	# ROOTFILES is a backquote substitution evaluated at parse time
	# and it runs awk on $CONF, so a conf generated by a RULE in the
	# same mkfile is too late: "awk: can't open file stm32f407auth"
	# and "bad include program status".  Make it first.
	if [ "$CONF" != stm32f407 ]; then
		(cd os/inferno/stm32f407 && mk $CONF) >>$BUILDLOG 2>&1
	fi
	(cd os/inferno/stm32f407 && mk CONF=$CONF INIT=$INIT i$CONF.hex) \
		> $BUILDLOG 2>&1
else
	if [ "$CONF" != stm32f407 ]; then
		(cd os/inferno/stm32f407 && mk $CONF) > $BUILDLOG 2>&1
	fi
	(cd os/inferno/stm32f407 && mk CONF=$CONF i$CONF.hex) >> $BUILDLOG 2>&1
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
HEXF=$ROOT/os/inferno/stm32f407/i$CONF.hex
ELFF=$ROOT/os/inferno/stm32f407/i$CONF

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
	os/inferno/stm32f407/$CONF.prog.s | sort -u | head -1)
echo "flashverify: the image carries $CARRIES"
# AND AN ABSENT prog.s IS A FAILURE, NOT A PASS.
#
# This check greps the generated prog.s rather than trusting the
# argument, which is the right idea and was vacuous whenever the file
# was missing: CARRIES came back empty and the comparison below was
# against an empty string.  mk short-circuits when prog.s has been
# deleted while stm32f407.xipmod.t still exists, so a tree in that state
# builds from a STALE XIP blob -- which is how two images that carry
# different inits came out byte-identical at 915608, over the flash
# limit, and sent an afternoon after a flash-size regression that was
# not there.
if [ -n "$INIT" ] && [ -z "$CARRIES" ]; then
	echo "FLASHVERIFY-FAILED the build produced no stm32f407.prog.s, so which"
	echo "init the image carries cannot be read.  mk short-circuits when"
	echo "prog.s is gone and its object is not: remove"
	echo "os/inferno/stm32f407/stm32f407.xipmod.* and prog.* together."
	exit 1
fi
if [ -n "$INIT" ] && [ "$CARRIES" != "from ../init/$INIT.dis" ]; then
	echo "FLASHVERIFY-FAILED asked for $INIT and the image carries"
	echo "$CARRIES -- mk kept a generated table from a previous build"
	exit 1
fi
echo "flashverify: built, kerndate $STAMP"

# AND IT BOOTS THE IMAGE UNDER QEMU BEFORE PUTTING IT ON A BOARD.
#
# Every check above asks whether the right FILES went into the image.
# None of them asks whether the image runs, and the gap is wide enough
# to drive a whole session into: os/inferno/init/<init>.dis must be
# built with DISWORD=4 for this 32 bit kernel -- the kernel mkfile does
# that, with "cd ../init; mk 'DISWORD='$DISWORD $INIT.dis" -- and a
# <init>.dis built BY HAND in that directory picks up mkconfig's
# default of 8 instead.  mk then sees a newer .dis and embeds it, so a
# 64 bit word module goes into a 32 bit kernel.  It flashes, the banner
# prints, the kerndate matches, nproc matches, prog.s names the right
# init, and the module cannot load: the interpreter walks the type
# descriptor map, finds 2 where a pointer belongs, and takes a bus
# fault in D2H() before init() runs a single line.
#
# Two boards were flashed with exactly that and read as working runs,
# because what was being read was the PREVIOUS session's scrollback.
# The failure is instant, deterministic and free to provoke: the board
# this kernel is built for is modelled by qemu-system-arm's
# netduinoplus2, and the whole fault happens before any device is
# touched.  Forty seconds here against an hour of measurements taken
# against a kernel that panicked at startup.
#
# A missing qemu says so and does not pass quietly -- a check that
# cannot fail is how the stale XIP blob got as far as the flash limit.
QEMU=${QEMU:-/Users/npe/src/qemu-v10.1.3/build-arm/qemu-system-arm}
if [ ! -x "$QEMU" ]; then
	echo "flashverify: NO SMOKE TEST -- no qemu at $QEMU, so whether this"
	echo "image can load its own init module is unknown.  Set QEMU= to"
	echo "a build that has -M netduinoplus2."
else
	SMOKE=/tmp/fv-smoke-$$.log
	timeout -s KILL 40 "$QEMU" -M netduinoplus2,radio=on -nographic \
	    -serial null -serial mon:stdio \
	    -kernel os/inferno/stm32f407/i$CONF < /dev/null > $SMOKE 2>&1
	if grep -qE "fault pc|panic:" $SMOKE; then
		echo "FLASHVERIFY-FAILED the image faults under qemu before it"
		echo "gets anywhere, so flashing it would only move the fault"
		echo "onto a board:"
		grep -nE "Initial Dis|fault pc|cfsr|panic:" $SMOKE | head -5
		echo "If the fault is in D2H/interp right after \"Initial Dis\","
		echo "the init module was built with the wrong DISWORD.  Remove"
		echo "os/inferno/init/$INIT.dis and let the kernel mkfile build"
		echo "it, or pass DISWORD=4 by hand."
		exit 1
	fi
	# And it has to get PAST the loader, not merely avoid faulting:
	# a kernel that stops silently at "Initial Dis" passes a check
	# for the absence of a panic.
	if ! grep -q "Initial Dis" $SMOKE; then
		echo "FLASHVERIFY-FAILED the image never reached Initial Dis"
		echo "under qemu; it is not a working kernel."
		exit 1
	fi
	AFTER=$(awk '/Initial Dis/{seen=1; next} seen && NF' $SMOKE |
	        grep -c .)
	if [ "$AFTER" -eq 0 ]; then
		echo "FLASHVERIFY-FAILED the image loaded nothing after"
		echo "Initial Dis under qemu -- the init module printed not one"
		echo "line, which is what a module that cannot load looks like"
		echo "when the fault handler stays quiet."
		exit 1
	fi
	echo "flashverify: boots under qemu, $AFTER lines past Initial Dis"
fi

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

HEX=$ROOT/os/inferno/stm32f407/i$CONF.hex
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
python3 - "$PORT" "$STAMP" "$WANTPROC" "$WANTCAL" "$CONF" <<'PY'
import re, sys, time
sys.path.insert(0, "tools/radio")
from twoboard import open_board
b = open_board(sys.argv[1], "board")
want = sys.argv[2] if len(sys.argv) > 2 else ""
# The banner carries the CONF's own name -- "conf stm32f407auth (...)"
# for the derived one -- so the pattern has to come from the argument
# and not be spelled out.  Matching the base name against an auth
# kernel's banner read kerndate None while nproc parsed fine, which is
# a verification that fails for the wrong reason.
conf = sys.argv[5] if len(sys.argv) > 5 and sys.argv[5] else "stm32f407"
pat = r"conf " + re.escape(conf) + r" \((\d+)\)"
for _ in range(10):
    time.sleep(3)
    t = b.text()
    m = re.findall(pat, t)
    if m and (not want or m[-1] == want):
        break
m = re.findall(pat, b.text())
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
