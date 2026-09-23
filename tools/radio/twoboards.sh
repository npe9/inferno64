#!/bin/sh
#
# Two boards, one packet: the check that #W's receive path works.
#
# Until this existed, "no packets" on the bench had two explanations
# that could not be told apart -- nothing on the air worth hearing, or
# a driver that has never received anything from anyone -- and the
# second was true.  A radio configured for a real protocol that
# reports nothing is uninterpretable without a positive control, and
# this is the positive control.
#
# What it proves and what it does not.  It exercises the transmit FIFO
# and strobe, and on the far side the interrupt, NUM_RXBYTES, the FIFO
# read, the header this device prepends, the queue and the counters --
# the whole of #W's packet path, ending with the payload coming out of
# /dev/radio0/data on a different machine.  It does not exercise sync
# word detection or anything else in the radio: the qemu model hands
# whole packets across a netdev and never looks at SYNC_CFG1.  So a
# pass here and silence on the air together say the fault is in the RF
# half, which is worth a great deal more than either alone.
#
# Use a socket and not multicast.  With mcast= the two instances came
# up, the sender reported "sent 1", the receiver reported "recv 0" and
# the receive FIFO was empty -- which reads exactly like a driver bug
# and was two qemu instances that had never been connected.
#
#	twoboards.sh /path/to/qemu-system-arm [kernel]
#
Q=${1:?usage: twoboards.sh <qemu-system-arm> [kernel]}
K=${2:-os/inferno/stm32f407/istm32f407}
PORT=${PORT:-14417}
MSG=${MSG:-radio-carried-this}
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' 0

{ sleep 14; printf 'cat /dev/radio0/data\n'; sleep 40; } |
	"$Q" -M netduinoplus2,radio=on \
	    -nic socket,model=cc1120,listen=127.0.0.1:$PORT \
	    -nographic -serial null -serial mon:stdio -kernel "$K" \
	    > "$OUT/rx" 2>&1 &
rxpid=$!
sleep 6
{ sleep 16; printf "echo $MSG >/dev/radio0/data\n"; sleep 10; } |
	timeout 45 "$Q" -M netduinoplus2,radio=on \
	    -nic socket,model=cc1120,connect=127.0.0.1:$PORT \
	    -nographic -serial null -serial mon:stdio -kernel "$K" \
	    > "$OUT/tx" 2>&1
sleep 24
kill $rxpid 2>/dev/null

# tr: the console ends its lines with a carriage return, so an exact
# whole-line match fails on text that is plainly there.
if tr -d '\r' < "$OUT/rx" | grep -qx "$MSG"; then
	echo "RADIO-RX-OK $MSG arrived on the second board"
	exit 0
fi
echo "RADIO-RX-FAILED; the receiver said:"
grep -v '^$' "$OUT/rx" | tail -6
exit 1
