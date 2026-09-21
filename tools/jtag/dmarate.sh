#!/bin/sh
#
# Does clearing the eMMC interrupt before arming the DMA channel change
# how often a DMA write stalls?
#
# This measurement has been owed since 72d107da, which retracted a fix
# claimed on one pass against one failure at a base failure rate near
# two in three.  Repeating it gave ok/FAIL/FAIL.  The retraction said
# the honest form is N transfers with the acknowledge on and N with it
# off, on comparable board state, and that is this.
#
# THROUGH THE FILESYSTEM, NOT THE RAW DEVICE.  This is the whole point
# and the first version of this script got it wrong.  Raw writes have
# never failed: 500 in-kernel transfers clean, and writes work raw at
# dossrv's own transfer size.  doc/raspi3b-stability-plan.ms says in as
# many words that only the filesystem path fails.  Counting failures on
# the path that does not fail would have returned 0 and 0, and the
# tempting reading of that -- "the acknowledge makes no difference" --
# is exactly the blind-instrument error: a test that is exact because
# the term vanishes cannot see that term.
#
# The raw device was chosen so a failure could not panic dossrv.  That
# reason is gone: a dossrv panic now costs one jtagrestart, about
# thirty seconds, and the card is never touched.  Being able to afford
# the measurement on the path that actually fails is what the JTAG work
# was for.
#
# EACH TRANSFER IS SCORED IN A FRESHLY EMPTIED CONSOLE.  The scrollback
# is capped at 10100 lines and is saturated before the first transfer,
# because every arm begins with a full boot and boot suite.  A failure
# count taken as a difference between two snapshots is therefore a
# difference between two sliding windows, with the earlier arm's
# failures scrolling out of the later arm's baseline -- the first
# version of this script did that, and every count it produced would
# have been uninterpretable.  So the history is flushed before each
# write (and kept, in $LOG), and anything matching afterwards belongs
# to that write.  Verified that the flush works: a marker present
# before is gone after.  The result is N binary outcomes per arm
# rather than one aggregate.
#
set -u
HERE=`dirname "$0"`
ROOT=`cd "$HERE/../.." && pwd`
S=${S:-/private/tmp/claude-501/-Users-npe-src-inferno64-branches-raspi3b-port/2675f84d-d333-4a0e-ba1f-4ef786fc52b7/scratchpad}
SESS=${SESS:-37971.ttys006}
N=${N:-12}
BS=${BS:-32768}
COUNT=${COUNT:-20}
ADAPTER=${ADAPTER:-interface/ftdi/olimex-arm-usb-tiny-h.cfg}

pi() { sh "$S/pi.sh" -w "${2:-3}" "$1" >/dev/null 2>&1; }
snap() { screen -S "$SESS" -X hardcopy -h "$1" 2>/dev/null; sleep 1; }

#
# Flush the console history, keeping a copy.
#
# Everything this script reads is a hardcopy of a scrollback capped at
# 10100 lines and saturated long before the first transfer, so every
# grep competes with output from previous boots and previous arms.
# Counting occurrences across the whole buffer does not fix that on
# its own: as new lines arrive old matches scroll off, so a count can
# stay flat through an event that did happen.  Emptying the buffer
# first makes every match unambiguous -- anything present afterwards
# arrived afterwards.
#
# The history is appended to a log rather than dropped, because the
# console is the only record of what the board said and throwing it
# away to make a measurement easier would be the wrong trade.
#
LOG=${LOG:-$S/dmarate-console.log}
clearlog() {
	snap "$S/dr-keep.txt"
	cat "$S/dr-keep.txt" >>"$LOG" 2>/dev/null || true
	# "clear" empties the DISPLAY, "scrollback 0" empties the
	# HISTORY, and both are needed.  Resetting the scrollback alone
	# leaves the last screenful visible, so a hardcopy still shows
	# it -- which is how a DMA WRITE FAILURE from write 1 was still
	# on screen for writes 2, 3, 4 and 5 and scored each of them as
	# a failure, when in fact the server had panicked and those
	# writes never ran at all.
	screen -S "$SESS" -X clear 2>/dev/null
	sleep 1
	screen -S "$SESS" -X scrollback 0 2>/dev/null
	sleep 1
	screen -S "$SESS" -X scrollback 10000 2>/dev/null
	sleep 1
}

#
# Wait for the board by COUNTING a marker, not by tailing for one.
#
# The obvious form -- tail -40 | grep RASPI3B-OK -- cannot work, and
# hung the first run of this script for ten minutes before it was
# noticed.  The boot suite prints thirty or forty lines after
# RASPI3B-OK, so by the time anything looks, the marker it is waiting
# for has already scrolled out of the window.  Widening the window
# does not fix it either: the scrollback is capped and saturated, so
# the marker from the PREVIOUS boot is also in view, and a wide grep
# matches immediately and returns before the board has done anything.
#
# Counting occurrences over the whole hardcopy is immune to both.  The
# marker is "(warm, entered over JTAG)", which the kernel prints in
# its banner and which a cold boot from the card never prints, so a
# count that goes up means this restart specifically.
#
restart() {	# fresh kernel over JTAG, then wait for the shell
	clearlog
	#
	# Retried, because jtagrestart does not always take.  Observed:
	# a run that reported "stub at 0x70000 ... pc 0x70000", resumed,
	# and left the board still running its old kernel at
	# clockpoll+0x20 with no banner.  It worked on the next attempt
	# with nothing changed.  Until that is understood, the restart
	# checks whether the board actually came back rather than
	# assuming a clean exit means a clean boot.
	#
	try=1
	while [ $try -le 3 ]; do
	echo "  ... loading a fresh kernel over JTAG (attempt $try)"
	( cd "$ROOT" && timeout 180 openocd -f "$ADAPTER" \
		-f tools/jtag/raspi3b.cfg \
		-c 'init; jtagrestart; resume; exit' ) >/dev/null 2>&1
	i=0
	while [ $i -lt 12 ]; do
		snap "$S/dr-boot.txt"
		now=`LC_ALL=C grep -ac 'entered over JTAG' "$S/dr-boot.txt" || true`
		if [ "$now" -gt 0 ]; then
			sleep 40	# let the boot suite finish talking
			return 0
		fi
		sleep 6
		i=`expr $i + 1`
	done
	try=`expr $try + 1`
	clearlog
	done
	echo "  ... board did not come back after 3 attempts; abandoning this arm"
	return 1
}

setflags() {	# $1 = dmaclearirq setting; confirm the board took it
	pi 'echo dmafreeze 0 > /dev/sdM0/ctl' 5
	pi 'echo dma 1 > /dev/sdM0/ctl' 5
	pi "echo dmaclearirq $1 > /dev/sdM0/ctl" 5
	snap "$S/dr-armed.txt"
	LC_ALL=C tail -14 "$S/dr-armed.txt" | \
	    LC_ALL=C grep -aq "dmaclearirq $1" && return 0
	echo "  ... the board never acknowledged dmaclearirq $1"
	return 1
}

# one transfer; echoes ok | FAIL | WEDGE, and KUPDATE if contaminated
transfer() {	# $1 = file name
	clearlog
	pi "dd -if /dev/zero -of /n/dos/$1 -bs $BS -count $COUNT" 2
	j=0
	saw_fail=no
	saw_kupdate=no
	while [ $j -lt 30 ]; do
		snap "$S/dr-w.txt"
		t=`LC_ALL=C cat "$S/dr-w.txt"`
		printf %s "$t" | LC_ALL=C grep -aq 'DMA WRITE FAILURE' && \
			saw_fail=yes
		printf %s "$t" | LC_ALL=C grep -aq 'KUPDATE' && \
			saw_kupdate=yes
		printf %s "$t" | LC_ALL=C grep -aq 'records out' && break
		printf %s "$t" | LC_ALL=C grep -aq 'panic\|WILDSP' && break
		sleep 3
		j=`expr $j + 1`
	done
	[ $saw_kupdate = yes ] && printf 'KUPDATE '
	if [ $j -ge 30 ]; then
		echo WEDGE
	elif [ $saw_fail = yes ]; then
		echo FAIL
	else
		echo ok
	fi
}

echo "dmarate: $N writes of ${COUNT}x${BS} through /n/dos per arm"
echo "(the filesystem path -- the raw path has never failed)"
for a in 0 1; do
	echo "=== dmaclearirq $a"
	restart || continue
	setflags "$a" || continue
	ok=0; bad=0; wedged=0; dirty=0
	k=1
	while [ $k -le $N ]; do
		r=`transfer "r${a}_$k.dat"`
		echo "  write $k: $r"
		case "$r" in
		*KUPDATE*)	dirty=`expr $dirty + 1`;;
		esac
		case "$r" in
		*WEDGE*)	wedged=`expr $wedged + 1`
				restart || break
				setflags "$a" || break;;
		*FAIL*)		bad=`expr $bad + 1`;;
		*ok*)		ok=`expr $ok + 1`;;
		esac
		pi "rm /n/dos/r${a}_$k.dat" 3
		k=`expr $k + 1`
	done
	echo "=== dmaclearirq $a: $ok ok, $bad failed, $wedged wedged, of $N"
	[ $dirty -gt 0 ] && echo "    ($dirty overlapped a kupdate install -- contaminated)"
done
