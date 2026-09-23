#!/bin/sh
#
# Can this receiver measure a symbol rate it was not told?
#
# Every other measurement the driver can make reports a threshold
# being crossed -- an RSSI, a carrier sense, a packet that did or did
# not match a sync word -- and a threshold belongs to the receiver.
# Three separate measurements in one day on the real bench looked like
# a transmitter's signature and were the instrument's own
# quantisation, so a measurement whose answer comes from the air is
# worth having and is worth a control.
#
# "serial on" puts the part in transparent mode, where the packet
# engine is out of the path and the slicer's output goes to a pin, and
# "ghist" bins that pin's run lengths.  A preamble is an alternating
# pattern at the symbol rate, so it arrives as a pile of runs all one
# length, and that length is the symbol period.
#
# The control is that the guest is configured for one rate and the
# channel carries another.  The qemu model's "airrate" property sets
# the rate bits arrive at independently of the guest's DRATE, so a
# guest that finds 300 where it programmed 2400 has found something
# rather than echoed something.  Run at two rates a factor of four
# apart, the histogram has to move by a factor of four.
#
#	serialrate.sh /path/to/qemu-system-arm [kernel]
#
# Needs tools/qemu-patches/0050 applied.  Absolute bin numbers are not
# checked and must not be: under qemu a guest polling a pin in a tight
# loop and QEMU_CLOCK_VIRTUAL disagree by about six times, and 4800
# saturates in the same bin as 1200 because the virtual timer cannot
# deliver a 208us tick under that load.  The ratio survives both.
#
Q=${1:?usage: serialrate.sh <qemu-system-arm> [kernel]}
K=${2:-os/inferno/stm32f407/istm32f407}
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' 0

# The guest is told this, and the air never carries it.
GUESTRATE=2400

run() {
	rate=$1
	port=$2
	{ sleep 13; printf 'echo rate %d >/dev/radio0/ctl\n' $GUESTRATE
	  sleep 3;  printf 'echo serial on >/dev/radio0/ctl\n'
	  sleep 3;  printf 'echo ghist 2000 >/dev/radio0/ctl\n'
	  sleep 4;  printf 'echo ghist 2000 >/dev/radio0/ctl\n'
	  sleep 4;  printf 'echo ghist 2000 >/dev/radio0/ctl\n'
	  sleep 6; } |
		"$Q" -M netduinoplus2,radio=on \
		    -global cc1120.airrate=$rate -global cc1120.preamble=320 \
		    -nic socket,model=cc1120,listen=127.0.0.1:$port \
		    -nographic -serial null -serial mon:stdio \
		    -kernel "$K" > "$OUT/r$rate" 2>&1 &
	rxpid=$!
	sleep 4
	# A frame a second, for as long as the receiver is looking.  One
	# frame is 320 preamble bytes, which at 300 symbols a second is
	# eight seconds of pin and at 1200 is two; a sender that waited
	# for each to finish would leave the slow case measuring silence.
	{ sleep 12
	  i=0
	  while [ $i -lt 22 ]; do
		printf 'echo hello >/dev/radio0/data\n'
		sleep 1
		i=$((i+1))
	  done
	  sleep 2; } |
		timeout 45 "$Q" -M netduinoplus2,radio=on \
		    -nic socket,model=cc1120,connect=127.0.0.1:$port \
		    -nographic -serial null -serial mon:stdio \
		    -kernel "$K" > "$OUT/t$rate" 2>&1
	sleep 4
	kill $rxpid 2>/dev/null
}

# The symbol period this run measured, in microseconds.
#
# Not the bin holding the most runs.  The bins are a power of two
# apart, so a period near a boundary falls either side of it from one
# window to the next, and the sample period varies by half again
# between windows under qemu: the first cut of this read 2048 on one
# run of the same rate and 4096 on the next.  The whole distribution
# is steadier than its mode, so this takes the run-count-weighted mean
# bin, turns it into time with that window's own sample period, and
# averages the windows by how many runs each saw.
peak() {
	tr -d '\r' < "$1" |
		awk '
		/^ghist/ {
			for (i = 1; i < NF; i++)
				if ($i == "nsper")
					ns = $(i+1)
			s = 0; c = 0
			next
		}
		/^ [0-9]+:/ {
			sub(":", "", $1)
			n = $3 + $5
			s += $1 * n
			c += n
			if (ns > 0) { lastus = (s / c) * ns / 1000; lastc = c }
			next
		}
		{ if (lastc > 0) { tot += lastus * lastc; totc += lastc; lastc = 0 } }
		END {
			if (lastc > 0) { tot += lastus * lastc; totc += lastc }
			if (totc == 0) print 0; else printf "%d\n", tot / totc
		}'
}

run 300 14451
run 1200 14452
lo=$(peak "$OUT/r300")
hi=$(peak "$OUT/r1200")
echo "air 300 sym/s: measured symbol period ${lo}us"
echo "air 1200 sym/s: measured symbol period ${hi}us"

if [ "$lo" -eq 0 ] || [ "$hi" -eq 0 ]; then
	echo "SERIAL-FAILED: the pin never moved at one of the rates"
	echo "--- 300"; tr -d '\r' < "$OUT/r300" | grep -E '^ghist|^ [0-9]+:'
	echo "--- 1200"; tr -d '\r' < "$OUT/r1200" | grep -E '^ghist|^ [0-9]+:'
	exit 1
fi

# Four, to within what a histogram a power of two wide can say.  A
# bin locates a period to a factor of two, so a ratio of four is
# known to a factor of two either side of it; anything inside that
# band is the rate and nothing outside it is.  Measured 3.1 where the
# rates differ by 4.
r=$(((lo * 10) / hi))
if [ "$r" -lt 22 ] || [ "$r" -gt 70 ]; then
	echo "SERIAL-FAILED: four times the rate did not give about a"
	echo "quarter the symbol period; ${lo}us over ${hi}us is ${r} tenths"
	exit 1
fi
echo "SERIAL-RATE-OK ${lo}us against ${hi}us, ${r} tenths where four"
echo "times the rate wants forty: the histogram followed a rate the"
echo "guest was never told"
