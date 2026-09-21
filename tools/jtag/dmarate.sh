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
# It has been lost to a wedged board four times, because a wedge used
# to cost a power cycle or a card carried to another machine.  It does
# not any more: each arm starts by loading a fresh kernel over JTAG,
# which takes about thirty seconds and does not touch the card.  That
# also makes the two arms more comparable than they would otherwise
# be, since each one starts from a kernel that has just booted rather
# than from whatever the previous arm left behind.
#
# The raw device is deliberate.  /dev/sdM0/kfstest goes through devsd
# and sdemmcbcm and nothing else, so a failure returns to dd and
# cannot reach a file server and panic it.  dmafreeze stays off, so a
# failed transfer falls back to PIO and the run continues; the failure
# is still reported on the console, and counting those reports is the
# measurement.
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

pi() { sh "$S/pi.sh" -w "${2:-4}" "$1" >/dev/null 2>&1; }
snap() { screen -S "$SESS" -X hardcopy -h "$1" 2>/dev/null; sleep 1; }

restart() {	# fresh kernel over JTAG, then wait for the shell
	echo "  ... loading a fresh kernel over JTAG"
	( cd "$ROOT" && timeout 180 openocd -f "$ADAPTER" \
		-f tools/jtag/raspi3b.cfg \
		-c 'init; jtagrestart; resume; exit' ) >/dev/null 2>&1
	i=0
	while [ $i -lt 40 ]; do
		snap "$S/dr-boot.txt"
		if LC_ALL=C tail -40 "$S/dr-boot.txt" | LC_ALL=C grep -aq 'RASPI3B-OK'; then
			sleep 25		# let the boot suite settle
			return 0
		fi
		sleep 6
		i=`expr $i + 1`
	done
	echo "  ... board did not come back; giving up on this arm"
	return 1
}

arm() {		# $1 = dmaclearirq setting
	pi 'echo dmafreeze 0 > /dev/sdM0/ctl' 5
	pi 'echo dma 1 > /dev/sdM0/ctl' 5
	pi "echo dmaclearirq $1 > /dev/sdM0/ctl" 5
	snap "$S/dr-armed.txt"
	if ! LC_ALL=C tail -12 "$S/dr-armed.txt" | LC_ALL=C grep -aq "dmaclearirq $1"; then
		echo "  ... the board never acknowledged dmaclearirq $1"
		return 1
	fi
	return 0
}

count_failures() {	# failures reported since $1 was taken
	snap "$S/dr-now.txt"
	a=`LC_ALL=C grep -ac 'DMA WRITE FAILURE' "$1" 2>/dev/null || echo 0`
	b=`LC_ALL=C grep -ac 'DMA WRITE FAILURE' "$S/dr-now.txt" 2>/dev/null || echo 0`
	# The scrollback is capped and rolls, so a raw difference can go
	# negative once old lines scroll off.  Clamp; an arm that rolls
	# the buffer is reported as such rather than silently mismeasured.
	d=`expr $b - $a`
	[ "$d" -lt 0 ] && d=0
	echo "$d"
}

echo "dmarate: $N transfers of ${COUNT}x${BS} per arm, raw device"
for a in 0 1; do
	echo "=== dmaclearirq $a"
	restart || continue
	arm "$a" || continue
	snap "$S/dr-base.txt"
	base_lines=`LC_ALL=C grep -ac '' "$S/dr-base.txt"`
	done_n=0
	k=1
	while [ $k -le $N ]; do
		pi "dd -if /dev/zero -of /dev/sdM0/kfstest -bs $BS -count $COUNT" 2
		j=0
		while [ $j -lt 25 ]; do
			snap "$S/dr-w.txt"
			LC_ALL=C tail -6 "$S/dr-w.txt" | \
			    LC_ALL=C grep -aq 'records out' && break
			sleep 3
			j=`expr $j + 1`
		done
		if [ $j -ge 25 ]; then
			echo "  transfer $k: no completion in ~75s (wedged)"
			restart || break
			arm "$a" || break
		else
			done_n=`expr $done_n + 1`
		fi
		k=`expr $k + 1`
	done
	f=`count_failures "$S/dr-base.txt"`
	now_lines=`LC_ALL=C grep -ac '' "$S/dr-now.txt"`
	if [ "$now_lines" -le "$base_lines" ]; then
		echo "  (scrollback rolled during this arm; the count is a lower bound)"
	fi
	echo "=== dmaclearirq $a: $f DMA write failures reported over \
$done_n completed transfers of $N attempted"
done
