#!/bin/sh
#
# radiocal(1) end to end under qemu, both roles, on the cc1120 model.
#
# This cannot check the numbers -- the model's RSSI is a constant it was
# told, not a receiver -- so what it checks is everything else, which is
# where the bugs in a program like this are: that -t walks the ramp and
# writes PA_CFG2 through ctl without the device refusing it, that -r
# decodes the twelve-byte pkt header and this program's own payload,
# that a rung's sequence numbers account for what arrived and what did
# not, and that the least-squares arithmetic runs without a divide by
# zero on real input.
#
# The negative control is the second half: -r run with nothing
# transmitting must report that fewer than three rungs arrived rather
# than printing a slope.  Without it a program that printed a plausible
# table from uninitialised arrays would pass.
#
# THE WINDOW IS IN GUEST SECONDS AND THEY ARE NOT HOST SECONDS.
# This board's clock under qemu runs about three times fast: a window
# the program measured for itself as 300010ms elapsed inside ninety
# seconds of the script's own sleeps.  So -w 25 closed about eight host
# seconds in, before the transmitter had been typed at, and three runs
# of this reported an empty table while the driver's own recv climbed to
# 12 afterwards -- which reads exactly like a receiver that heard
# nothing.  The program now prints what the window really lasted, and
# the numbers below are chosen against that rather than against the
# guest's idea of a second.
#
#	radiocaltest.sh /path/to/qemu-system-arm [kernel]
#
Q=${1:?usage: radiocaltest.sh <qemu-system-arm> [kernel]}
K=${2:-os/inferno/stm32f407/istm32f407}
PORT=${PORT:-14517}
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' 0
rc=0

# The receiver first, so it is listening before anything is sent.  -w is
# its own bound: a read of pkt blocks and the board has no interrupt
# character, so the program kills its own group when the clock runs out.
{ sleep 12; printf 'radiocal -r -w 300\n'; sleep 100; } |
	"$Q" -M netduinoplus2,radio=on \
	    -nic socket,model=cc1120,listen=127.0.0.1:$PORT \
	    -nographic -serial null -serial mon:stdio -kernel "$K" \
	    > "$OUT/rx" 2>&1 &
rxpid=$!
sleep 8
{ sleep 10; printf 'radiocal -t -n 3 -s 16 -f 63 -l 15\n'; sleep 40; } |
	timeout 90 "$Q" -M netduinoplus2,radio=on \
	    -nic socket,model=cc1120,connect=127.0.0.1:$PORT \
	    -nographic -serial null -serial mon:stdio -kernel "$K" \
	    > "$OUT/tx" 2>&1
sleep 60
kill $rxpid 2>/dev/null

tr -d '\r' < "$OUT/tx" > "$OUT/txc"
tr -d '\r' < "$OUT/rx" > "$OUT/rxc"

# the transmitter walked four rungs and wrote every packet of each
for r in 63 47 31 15; do
	if ! grep -q "^rung ramp *$r .* wrote 3 of 3$" "$OUT/txc"; then
		echo "RADIOCALTEST-FAILED the transmitter did not write rung $r:"
		grep -E '^(rung|radiocal)' "$OUT/txc" | tail -8
		rc=1
	fi
done
if ! grep -q 'PA_CFG2 back to 0x4f' "$OUT/txc"; then
	echo "RADIOCALTEST-FAILED the transmitter did not restore PA_CFG2"
	rc=1
fi

# the receiver tabulated them and printed a slope
if ! grep -q '^RADIOCAL-OK' "$OUT/rxc"; then
	echo "RADIOCALTEST-FAILED the receiver printed no slope:"
	grep -v '^$' "$OUT/rxc" | tail -14
	rc=1
else
	rungs=$(sed -n 's/^RADIOCAL-OK .*rungs \([0-9]*\)$/\1/p' "$OUT/rxc")
	if [ "$rungs" != 4 ]; then
		echo "RADIOCALTEST-FAILED the receiver saw $rungs rungs, not 4"
		rc=1
	fi
	if ! grep -q 'the window asked for' "$OUT/rxc"; then
		echo "RADIOCALTEST-FAILED the receiver did not report how"
		echo "long its window really lasted, which is the one thing"
		echo "that made three earlier runs uninterpretable"
		rc=1
	fi
	if grep -q 'were not this program' "$OUT/rxc"; then
		echo "RADIOCALTEST-FAILED stray packets were counted:"
		grep 'were not this program' "$OUT/rxc"
		rc=1
	fi
fi
[ $rc = 0 ] && echo "RADIOCALTEST-RUN-OK four rungs, three packets each" \
	&& sed -n '/ramp   nominal/,$p' "$OUT/rxc" | head -10

# The negative control: no transmitter at all.  Fewer than three rungs
# must be reported as such, and no slope printed.
{ sleep 12; printf 'radiocal -r -w 60\n'; sleep 45; } |
	timeout 70 "$Q" -M netduinoplus2,radio=on \
	    -nic socket,model=cc1120,listen=127.0.0.1:$((PORT+1)) \
	    -nographic -serial null -serial mon:stdio -kernel "$K" \
	    > "$OUT/rx2" 2>&1
tr -d '\r' < "$OUT/rx2" > "$OUT/rx2c"
if grep -q '^RADIOCAL-OK' "$OUT/rx2c"; then
	echo "RADIOCALTEST-FAILED a receiver with nothing transmitting"
	echo "printed a slope, so the table is not coming from packets"
	rc=1
elif ! grep -q '^RADIOCAL-FAILED fewer than three rungs' "$OUT/rx2c"; then
	echo "RADIOCALTEST-FAILED the empty case said neither thing:"
	grep -v '^$' "$OUT/rx2c" | tail -8
	rc=1
else
	echo "RADIOCALTEST-EMPTY-OK no transmitter, no slope"
fi

[ $rc = 0 ] && echo RADIOCALTEST-OK || echo RADIOCALTEST-FAILED
exit $rc
