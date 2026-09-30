#!/bin/sh
#
# Does a beacon kernel actually put frames on the air that another board
# receives?  Under qemu, before spending a flash cycle on it.
#
# os/inferno/init/armv7mbeacon.b makes a board transmit on its own, so
# that plan item 3 -- receive a packet somebody else sent -- does not
# need a console on the transmitting board.  That matters because the
# second board's console does not work: an RS232 click into a PL2303
# where the first board has a USB UART click, and nothing arrives.
#
# So the transmitter is configured by its own init and never spoken to,
# and everything this checks is on the receiving side.
#
# THE CONTROL IS THE SECOND HALF, and it is not optional: the same
# receiver, the same settings, the same duration, with the beacon
# instance not started.  The payload is a fixed recognisable token so a
# buffer of noise that happens to pass CRC cannot read as a received
# packet, and the control says whether anything at all arrives when
# nothing is sending.
#
# A socket and not multicast, for the reason twoboards.sh records: with
# mcast= both instances came up, the sender said "sent 1", the receiver
# said "recv 0", and that reads exactly like a driver bug while being
# two qemu instances that were never connected.
#
#	beacontest.sh <qemu-system-arm> <beacon-kernel> <shell-kernel>
#
Q=${1:?usage: beacontest.sh <qemu> <beacon-kernel> <shell-kernel>}
KB=${2:?beacon kernel}
KS=${3:?shell kernel}
PORT=${PORT:-14473}
TOKEN=${TOKEN:-INFERNO-BEACON}
OUT=${OUTDIR:-$(mktemp -d)}
mkdir -p "$OUT"

cat > "$OUT/pace.py" <<'PYEOF'
import sys, time
for line in sys.stdin:
    for ch in line:
        sys.stdout.write(ch); sys.stdout.flush(); time.sleep(0.02)
PYEOF

# The receiver: configured to match the beacon, then reading the data
# file.  Its own console works, which is the whole point of the split.
receiver() {
	{ sleep 14
	  printf 'echo rate 9600 >/dev/radio0/ctl\n';       sleep 3
	  printf 'echo deviation 20000 >/dev/radio0/ctl\n'; sleep 3
	  printf 'echo bw 50000 >/dev/radio0/ctl\n';        sleep 3
	  printf 'echo freq 915000000 >/dev/radio0/ctl\n';  sleep 3
	  printf 'echo sync 0xaaaa 16 >/dev/radio0/ctl\n';  sleep 3
	  printf 'echo csthr -104 >/dev/radio0/ctl\n';      sleep 3
	  # stats before, so that recv is a delta and not a total, and
	  # again after: the counters are the only thing that tells
	  # "the part never heard it" from "it heard it and the queue
	  # dropped it", which a count of payloads on the console cannot.
	  printf 'cat /dev/radio0/stats\n';                 sleep 4
	  printf 'cat /dev/radio0/data\n';                  sleep 45
	  printf '\004';                                     sleep 3
	  printf 'cat /dev/radio0/stats\n';                 sleep 5
	} | python3 "$OUT/pace.py" |
	  timeout -s KILL 190 "$Q" -M netduinoplus2,radio=on \
	    -nic socket,model=cc1120,listen=127.0.0.1:$PORT \
	    -nographic -serial null -serial mon:stdio -kernel "$KS" 2>&1
}

beacon() {
	timeout -s KILL 170 "$Q" -M netduinoplus2,radio=on \
	    -nic socket,model=cc1120,connect=127.0.0.1:$PORT \
	    -nographic -serial null -serial mon:stdio -kernel "$KB" \
	    < /dev/null 2>&1
}

echo "=== with the beacon running ==="
receiver > "$OUT/rx1" 2>&1 &
rxpid=$!
sleep 8
beacon > "$OUT/tx1" 2>&1 &
txpid=$!
wait $rxpid 2>/dev/null
kill $txpid 2>/dev/null
grep -E 'ARMV7M-BEACON|beacon:' "$OUT/tx1" | head -4 | sed 's/^/   tx: /'
# Occurrences and not lines: the payload carries no newline, so
# consecutive frames land on one line and counting lines under-reports.
n1=$(grep -o "$TOKEN" "$OUT/rx1" | wc -l | tr -d ' ')
echo "   rx: $n1 occurrence(s) of $TOKEN"
grep -E '^(sent|recv|crcerr|rxoverflow|toobig)|^recv ' "$OUT/rx1" | sed 's/^/   rx: /'
grep -E 'recv [0-9]|crcerr [0-9]|rxoverflow' "$OUT/rx1" | sed 's/^/   rx stats: /' | head -6

sleep 3
echo
echo "=== the control: same receiver, no beacon started ==="
receiver > "$OUT/rx2" 2>&1
n2=$(grep -o "$TOKEN" "$OUT/rx2" | wc -l | tr -d ' ')
echo "   rx: $n2 occurrence(s) of $TOKEN"
grep -E 'recv [0-9]|crcerr [0-9]|rxoverflow' "$OUT/rx2" | sed 's/^/   rx stats: /' | head -4

echo
if [ "$n1" -gt 0 ] && [ "$n2" -eq 0 ]; then
	echo "BEACONTEST-OK  received with the beacon, nothing without it"
elif [ "$n1" -gt 0 ]; then
	echo "BEACONTEST-FAILED  the token arrived with NO beacon running,"
	echo "so it is not coming from the beacon and means nothing"
elif [ "$n2" -eq 0 ]; then
	echo "BEACONTEST-FAILED  nothing received, and the control is silent"
	echo "too, so this says the path does not work and not why"
else
	echo "BEACONTEST-FAILED  nothing with the beacon, something without"
fi
echo "transcripts in $OUT"
