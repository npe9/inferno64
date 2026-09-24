#!/bin/sh
#
# Does the configuration that receives nothing on silicon receive under qemu?
#
# The board has spent six and a half minutes on a channel at 18 per
# cent duty with a sixteen-bit sync at threshold 0 and taken no packet,
# no CRC error and no overflow.  Everything checkable from the host has
# been checked: registers read back and arithmetic verified, MARCSTATE
# in RX throughout, the pin proven by its own inversion, thresholds and
# modulation indices and the preamble gate all swept.
#
# What has not been separated is the driver's software path from the
# part's configuration, and the model can do that without hardware.
# twoboards.sh proves a packet crosses with the settings the driver
# boots with; this proves it with the settings silicon was actually
# wearing when it heard nothing:
#
#	rate 9600, deviation 20000, bw 50000
#	txmode fixed, pktlen 64, CRC off
#	sync 0xaaaa 16
#
# If a packet arrives, the software is sound under that configuration
# and the fault is in what those registers mean to a real part.  If it
# does not, there is a bug reachable from here, which is a much better
# place to be.
#
#	silicfg.sh /path/to/qemu-system-arm [kernel]
#
Q=${1:?usage: silicfg.sh <qemu-system-arm> [kernel]}
K=${2:-os/inferno/stm32f407/istm32f407}
PORT=${PORT:-14461}
MSG=${MSG:-silicon-config-carried-this}
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' 0

cfg() {
	printf 'echo rate 9600 >/dev/radio0/ctl\n';        sleep 2
	printf 'echo deviation 20000 >/dev/radio0/ctl\n';  sleep 2
	printf 'echo bw 50000 >/dev/radio0/ctl\n';         sleep 2
	printf 'echo txmode fixed >/dev/radio0/ctl\n';     sleep 2
	printf 'echo pktlen 64 >/dev/radio0/ctl\n';        sleep 2
	printf 'echo sync 0xaaaa 16 >/dev/radio0/ctl\n';   sleep 2
}

{ sleep 13; cfg; sleep 2; printf 'cat /dev/radio0/data\n'; sleep 40; } |
	"$Q" -M netduinoplus2,radio=on \
	    -nic socket,model=cc1120,listen=127.0.0.1:$PORT \
	    -nographic -serial null -serial mon:stdio -kernel "$K" \
	    > "$OUT/rx" 2>&1 &
rxpid=$!
sleep 6
{ sleep 13; cfg; sleep 2
  printf "echo $MSG >/dev/radio0/data\n"; sleep 10; } |
	timeout 60 "$Q" -M netduinoplus2,radio=on \
	    -nic socket,model=cc1120,connect=127.0.0.1:$PORT \
	    -nographic -serial null -serial mon:stdio -kernel "$K" \
	    > "$OUT/tx" 2>&1
sleep 20
kill $rxpid 2>/dev/null

if tr -d '\r' < "$OUT/rx" | grep -qx "$MSG"; then
	echo "SILICFG-OK the silicon configuration carries a packet under qemu"
	echo "so the driver's software path is sound with those settings and"
	echo "what silicon does differently is in the part, not the code"
	exit 0
fi
echo "SILICFG-FAILED nothing arrived with the silicon configuration,"
echo "and twoboards.sh passes with the boot defaults -- so one of these"
echo "six ctl lines breaks reception and it can be found from here."
echo "--- receiver said:"
grep -v '^$' "$OUT/rx" | tail -12
echo "--- sender said:"
grep -v '^$' "$OUT/tx" | tail -6
exit 1
