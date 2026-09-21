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
# EACH TRANSFER IS SCORED WHILE ITS OUTPUT IS FRESH.  The console
# scrollback is capped at 10100 lines and is saturated before the first
# transfer, because every arm begins with a full boot and boot suite.
# So a failure count taken as a difference between two snapshots is a
# difference between two sliding windows, with the earlier arm's
# failures scrolling out of the later arm's baseline.  Instead the poll
# loop that waits for "records out" also watches the tail for a failure
# report, giving N binary outcomes per arm, each read while it is still
# on screen.
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

restart() {	# fresh kernel over JTAG, then wait for the shell
	echo "  ... loading a fresh kernel over JTAG"
	( cd "$ROOT" && timeout 180 openocd -f "$ADAPTER" \
		-f tools/jtag/raspi3b.cfg \
		-c 'init; jtagrestart; resume; exit' ) >/dev/null 2>&1
	i=0
	while [ $i -lt 40 ]; do
		snap "$S/dr-boot.txt"
		if LC_ALL=C tail -40 "$S/dr-boot.txt" | \
		    LC_ALL=C grep -aq 'RASPI3B-OK'; then
			sleep 30	# let the boot suite finish talking
			return 0
		fi
		sleep 6
		i=`expr $i + 1`
	done
	echo "  ... board did not come back; abandoning this arm"
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
	pi "dd -if /dev/zero -of /n/dos/$1 -bs $BS -count $COUNT" 2
	j=0
	saw_fail=no
	saw_kupdate=no
	while [ $j -lt 30 ]; do
		snap "$S/dr-w.txt"
		t=`LC_ALL=C tail -40 "$S/dr-w.txt"`
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
