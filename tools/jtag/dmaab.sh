#!/bin/sh
#
# Does $SWITCH change whether the SD DMA write stalls?
#
#	sh tools/jtag/dmaab.sh			  vary dmaclearirq
#	SWITCH=dmareset sh tools/jtag/dmaab.sh	  vary the channel reset
#
# Any /dev/sdM0/ctl switch that takes 0 or 1 and prints "emmc: <name>
# <value>" works.  The first question it answered was the eMMC
# interrupt acknowledge; the answer was no, and the next question --
# the DMA channel'"'"'s own CS, which the dumps show carrying END|DREQ
# from the previous transfer in both arms -- is the same experiment
# with a different name.
#
# TWO BOOTS, NOT TWENTY-FOUR WRITES.  The measurement this replaces
# was designed when the failure looked random: N writes with the
# acknowledge on and N with it off, counting a frequency.  It is not
# random.  Two independent occurrences were identical in every field
# the driver prints -- same start block, same three of nine blocks
# moved, same channel state, same eMMC state before arming -- and it
# reproduces on the first write after a fresh boot.
#
# So the experiment is: boot clean, set the acknowledge one way, do
# ONE write, keep the dump.  Restart, set it the other way, do one
# write, keep that dump.  Then diff them.  A deterministic failure
# does not need a rate, and counting one is what has now gone wrong
# three times, always the same way: reading the console for evidence
# of an event without first establishing that anything in the buffer
# is new.
#
# THE FIRST WRITE OF THE BOOT, deliberately.  That is where it
# reproduces, and a fresh kernel is also the only state both arms can
# share -- otherwise arm 1 starts from whatever arm 0 left in the
# controller, which is exactly the kind of leftover state under
# suspicion here.
#
# dmafreeze is ON for both arms.  A failed transfer then prints the
# engine's state and the controller's registers and stops, without the
# reset that would destroy them.  It wedges the board, and that used
# to be the reason not to do it; a wedge now costs one ^R reboot.
#
set -u
HERE=`dirname "$0"`
ROOT=`cd "$HERE/../.." && pwd`
# A neutral default, created rather than assumed: a path inside one
# Claude session's scratchpad does not exist for any other session, and
# every grep against a missing file reads empty.
S=${S:-${TMPDIR:-/tmp}/inferno-raspi3b}
mkdir -p "$S" 2>/dev/null
SESS=${SESS:-37971.ttys006}
SWITCH=${SWITCH:-dmaclearirq}	# which /dev/sdM0/ctl switch to vary
OUT=${OUT:-$S/dmaab-$SWITCH}
ADAPTER=${ADAPTER:-interface/ftdi/olimex-arm-usb-tiny-h.cfg}
BS=${BS:-32768}
COUNT=${COUNT:-20}

pi() { sh "$S/pi.sh" -w "${2:-4}" "$1" >/dev/null 2>&1; }
snap() { screen -S "$SESS" -X hardcopy -h "$1" 2>/dev/null; sleep 1; }

#
# NEVER CLEAR THE USER'"'"'S CONSOLE.
#
# An earlier version of this script called "screen -X clear" and
# "scrollback 0" before every step, so that a grep could only match
# new output.  That works, and it also wipes the window the person
# watching the board is looking at: they reported seeing nothing on
# the console, and they were right, because this was erasing it every
# few seconds.  The board'"'"'s console is not this script'"'"'s scratch space.
#
# Markers do the same job without touching anything.  Type a unique
# string, then read only what comes after its last occurrence.  That
# is position-based rather than emptiness-based, so it is immune to
# the scrollback rolling -- which is what all three earlier counting
# bugs in the rate harness were really about -- and it leaves the
# history intact for whoever is reading it.
#
MARKN=0
mark() {
	MARKN=`expr $MARKN + 1`
	MARK="ZZ${MARKN}ZZ"
	pi "echo $MARK" 4
	echo "$MARK"
}

# Everything the console printed after the last occurrence of $1.
since() {
	snap "$S/ab-since.txt"
	LC_ALL=C awk -v m="$1" '
		$0 ~ m { out = ""; next }
		{ out = out $0 "\n" }
		END { printf "%s", out }
	' "$S/ab-since.txt"
}

#
# Wait for the console to stop talking.
#
# A fixed sleep after the banner does not work: the boot suite runs
# for well over a minute and its FAT-BIG step alone takes 30 to 57
# seconds depending on how the card feels.  Typing into it splices --
# the PL011 has no flow control -- and the first run of this script
# lost an arm that way, reporting "the board never acknowledged
# dmaclearirq 0" when the command had been typed into the middle of
# the suite's output.
#
# So: poll, and require the hardcopy to be unchanged three times
# running before treating the board as ready.
#
settle() {
	same=0
	prev=""
	i=0
	while [ $i -lt 60 ]; do
		snap "$S/ab-settle.txt"
		cur=`cksum "$S/ab-settle.txt" | awk '{print $1}'`
		if [ "$cur" = "$prev" ]; then
			same=`expr $same + 1`
			[ $same -ge 3 ] && return 0
		else
			same=0
		fi
		prev="$cur"
		sleep 4
		i=`expr $i + 1`
	done
	echo "  console never went quiet"
	return 1
}

#
# Quiet is not the same as ready.  The boot suite's FAT-BIG step
# writes 1.5MB and says nothing for thirty to sixty seconds while it
# does, so a quiet detector settles in the middle of the suite and the
# next thing typed lands in the shell that is running it.
#
# So ask the shell directly: settle, then type a marker and require it
# back.  That tests the thing actually needed -- a shell free to run a
# command -- rather than a proxy for it.
#
waitshell() {
	k=1
	while [ $k -le 8 ]; do
		settle || return 1
		m=`mark`
		snap "$S/ab-probe.txt"
		if LC_ALL=C grep -aq "$m" "$S/ab-probe.txt"; then
			return 0
		fi
		echo "  shell busy (probe $k)"
		k=`expr $k + 1`
	done
	echo "  shell never answered"
	return 1
}

#
# Reboot with ^R, not with jtagrestart.
#
# jtagrestart loads a kernel and is what this whole directory is for,
# but it is NOT the way to cycle a board in a loop.  A warm restart
# leaves every SoC peripheral as the previous kernel had it, and twice
# now that boot has hung in schedinit() -- and when it hangs there the
# debugger goes with it: every injected instruction fails with
# DSCR.ERR=1, including a bare DSB, on all four cores, and "aarch64
# dbginit" does not clear it.  The JTAG chain still enumerates, so it
# looks like a dead board rather than an unreachable one.  TRST resets
# the TAP and not the SoC, so the only way out is a power cycle, by
# hand, by a person.  Two of those have been spent that way.
#
# ^R goes through the kernel's own archreboot(), which drives the
# BCM2835 watchdog and resets the SoC properly: the firmware runs, the
# card is read, and the machine comes up cold with every peripheral in
# its reset state.  It is taken from the console receive path, so it
# works even when the shell is stuck behind a dead file server --
# which is precisely the state a failed DMA write leaves.
#
# The cost is that the kernel under test is the one on the card.  That
# is fine here: the card holds a build with the dma, dmafreeze and
# dmaclearirq switches, and this experiment changes none of the
# kernel.  Use jtagrestart to put a NEW kernel on the board; use ^R to
# cycle it.
#
reboot() {
	snap "$S/ab-pre.txt"
	before=`LC_ALL=C grep -ac 'raspi3b build' "$S/ab-pre.txt" || true`
	echo "  rebooting with ^R"
	screen -S "$SESS" -X stuff "$(printf '\022')" 2>/dev/null
	i=0
	while [ $i -lt 30 ]; do
		snap "$S/ab-boot.txt"
		now=`LC_ALL=C grep -ac 'raspi3b build' "$S/ab-boot.txt" || true`
		if [ "$now" -gt "$before" ]; then
			echo "  booted; waiting for the shell"
			waitshell || return 1
			echo "  shell is free"
			return 0
		fi
		sleep 5
		i=`expr $i + 1`
	done
	echo "  board did not reboot; it may need a power cycle"
	return 1
}

#
# Is /n/dos alive?  Checked with DMA still off, so this cannot be the
# thing that breaks it.
#
# Arm 1 of the first run was lost for want of this.  The DMA failure
# fired the instant "dma 1" was written -- on whatever the boot was
# still doing to the card -- and panicked dosfs before the arm's own
# write ever ran, so the arm reported "neither completed nor failed"
# and the pair read as "only dmaclearirq 0 failed".  That reads as the
# acknowledge fixing it, which is exactly the claim 72d107da
# retracted.  A precondition that is not checked is an assumption.
#
dosalive() {
	m=`mark`
	pi 'echo alive > /n/dos/ablive.dat' 6
	since "$m" >"$S/ab-live.txt"
	if LC_ALL=C grep -aq 'panic\|error\|does not exist' "$S/ab-live.txt"; then
		return 1
	fi
	pi 'rm /n/dos/ablive.dat' 4
	return 0
}

#
# ORDER MATTERS.  dmaclearirq first, dma last.
#
# The first run set dma before dmaclearirq, and the failure fired
# between the two: the dump it produced was taken with the acknowledge
# at its default, not at the value the arm was supposed to be testing.
# Turning DMA on is what arms the thing under test, so everything the
# arm wants in place has to be in place before it.
#
arm() {		# $1 = the value for $SWITCH
	m=`mark`
	pi "echo $SWITCH $1 > /dev/sdM0/ctl" 5
	pi 'echo dmafreeze 1 > /dev/sdM0/ctl' 5
	pi 'echo dma 1 > /dev/sdM0/ctl' 5
	since "$m" >"$S/ab-armed.txt"
	if ! LC_ALL=C grep -aq "emmc: $SWITCH $1" "$S/ab-armed.txt"; then
		echo "  the board never acknowledged $SWITCH $1"
		return 1
	fi
	if ! LC_ALL=C grep -aq 'emmc: dmafreeze 1' "$S/ab-armed.txt"; then
		echo "  the board never acknowledged dmafreeze 1"
		return 1
	fi
	if ! LC_ALL=C grep -aq 'emmc: dma 1' "$S/ab-armed.txt"; then
		echo "  the board never acknowledged dma 1"
		return 1
	fi
	if LC_ALL=C grep -aq 'dosfs: panic' "$S/ab-armed.txt"; then
		echo "  dosfs panicked while arming; this arm is void"
		return 1
	fi
	return 0
}

run() {		# $1 = dmaclearirq; leaves the dump in $OUT-$1.txt
	echo "=== $SWITCH $1"
	reboot || return 1
	if ! dosalive; then
		echo "  /n/dos is not writable before the test; arm is void"
		return 1
	fi
	arm "$1" || return 1
	m=`mark`				# so the dump stands alone
	pi "dd -if /dev/zero -of /n/dos/ab$1.dat -bs $BS -count $COUNT" 2
	i=0
	while [ $i -lt 30 ]; do
		since "$m" >"$S/ab-w.txt"
		LC_ALL=C grep -aq 'DMA WRITE FAILURE' "$S/ab-w.txt" && break
		LC_ALL=C grep -aq 'records out' "$S/ab-w.txt" && break
		sleep 3
		i=`expr $i + 1`
	done
	sleep 4					# let the whole report land
	since "$m" >"$OUT-$1.txt"
	if LC_ALL=C grep -aq 'DMA WRITE FAILURE' "$OUT-$1.txt"; then
		echo "  FAILED -- dump in $OUT-$1.txt"
		LC_ALL=C grep -a -A 9 'DMA WRITE FAILURE' "$OUT-$1.txt" | head -10
	elif LC_ALL=C grep -aq 'records out' "$OUT-$1.txt"; then
		echo "  completed, no DMA failure"
	elif LC_ALL=C grep -aq 'dosfs: panic' "$OUT-$1.txt"; then
		echo "  dosfs panicked; the write never ran -- VOID, not a pass"
	else
		echo "  neither completed nor failed in ~90s -- VOID, not a pass"
	fi
}

run 0
run 1

echo
echo "=== the two arms, differing lines only:"
# Plain files rather than process substitution: the shebang is sh, and
# <(...) is a bashism that would have failed here and nowhere else.
for a in 0 1; do
	LC_ALL=C grep -a -A 9 'DMA WRITE FAILURE' "$OUT-$a.txt" 2>/dev/null \
		| head -10 >"$OUT-$a.dump"
done
if [ -s "$OUT-0.dump" ] && [ -s "$OUT-1.dump" ]; then
	if diff "$OUT-0.dump" "$OUT-1.dump"; then
		echo "(identical apart from incidentals -- $SWITCH changes nothing)"
	fi
elif [ -s "$OUT-0.dump" ]; then
	echo "(only $SWITCH 0 failed -- ONE pass each; say so, do not conclude)"
elif [ -s "$OUT-1.dump" ]; then
	echo "(only $SWITCH 1 failed -- ONE pass each; say so, do not conclude)"
else
	echo "(neither arm failed -- it did not reproduce this time)"
fi
