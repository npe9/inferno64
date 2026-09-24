#!/bin/sh
#
# Does a sixteen-bit sync word land where the part reads it?
#
# twoboards.sh could not answer this and passed for as long as the bug
# existed.  It sends a packet from one instance to another and checks it
# arrives, which is a round trip between a driver and a model that had
# the same wrong convention: both put a sixteen-bit sync word in SYNC3
# and SYNC2, so both agreed, so the packet arrived, so the test was
# green.  A round trip between two things you wrote cannot check a
# convention -- only something outside them can.
#
# What is outside them is SWRU295E.  SYNC_CFG1.SYNC_MODE 2 is sixteen
# bits taken from SYNC15_0, which is SYNC1 at 0x06 and SYNC0 at 0x07;
# mode 5 is thirty-two bits from SYNC31_0, which is SYNC3 at 0x04 down
# to SYNC0.  Read off a real CC1120 after asking this driver for a
# sixteen-bit 0xaaaa, before the fix: SYNC3 0xaa, SYNC2 0xaa, SYNC1
# 0x51, SYNC0 0xde -- the reset value, and what it was really hunting
# for.  No packet was ever received on that board.
#
# So this asserts the mapping itself, against the numbers the datasheet
# gives, using the driver's own "reg" verb to read back what it wrote.
# It is mechanical and it would have failed on day one.
#
#	synctest.sh /path/to/qemu-system-arm [kernel]
#
Q=${1:?usage: synctest.sh <qemu-system-arm> [kernel]}
K=${2:-os/inferno/stm32f407/istm32f407}
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' 0

{ sleep 13
  printf 'echo sync 0xaaaa 16 >/dev/radio0/ctl\n';  sleep 2
  printf 'echo reg 0x04 >/dev/radio0/ctl\n';        sleep 2
  printf 'echo reg 0x05 >/dev/radio0/ctl\n';        sleep 2
  printf 'echo reg 0x06 >/dev/radio0/ctl\n';        sleep 2
  printf 'echo reg 0x07 >/dev/radio0/ctl\n';        sleep 2
  printf 'echo reg 0x08 >/dev/radio0/ctl\n';        sleep 3
  printf 'echo sync 0x12345678 32 >/dev/radio0/ctl\n'; sleep 2
  printf 'echo reg 0x04 >/dev/radio0/ctl\n';        sleep 2
  printf 'echo reg 0x07 >/dev/radio0/ctl\n';        sleep 4; } |
	timeout 70 "$Q" -M netduinoplus2,radio=on \
	    -nographic -serial null -serial mon:stdio -kernel "$K" \
	    > "$OUT/log" 2>&1
tr -d '\r' < "$OUT/log" > "$OUT/clean"

fail=0
want() {
	if grep -qx "reg $1 $2" "$OUT/clean"; then
		echo "ok   $3: $1 = $2"
	else
		echo "FAIL $3: wanted $1 = $2, board said" \
		     "$(grep "^reg $1 " "$OUT/clean" | tail -1)"
		fail=1
	fi
}

# SYNC_MODE 2 reads SYNC15_0, so the word belongs in 0x06 and 0x07.
want 0x06 0xaa "16-bit sync high byte in SYNC1"
want 0x07 0xaa "16-bit sync low byte in SYNC0"
# And SYNC_CFG1 has to say mode 2, or the registers above are the wrong ones.
if grep -Eqx "reg 0x08 0x[46]." "$OUT/clean"; then
	echo "ok   SYNC_CFG1 top bits select a 16-bit mode"
else
	echo "FAIL SYNC_CFG1: $(grep '^reg 0x08 ' "$OUT/clean" | tail -1)"
	fail=1
fi
# Thirty-two bits is the other mapping and was always right; kept so a
# fix to one does not quietly break the other.
want 0x04 0x12 "32-bit sync first byte in SYNC3"
want 0x07 0x78 "32-bit sync last byte in SYNC0"

if [ $fail -ne 0 ]; then
	echo "SYNC-REGISTERS-FAILED"
	grep -E '^reg 0x0' "$OUT/clean" | tail -12
	exit 1
fi
echo "SYNC-REGISTERS-OK a sixteen-bit word lands in SYNC15_0 and a"
echo "thirty-two-bit word in SYNC31_0, which is what SYNC_MODE reads"
