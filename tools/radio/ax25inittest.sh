#!/bin/sh
#
# Two boards running the AX.25 init, under qemu, with no shell on either.
#
# The question this answers is not about the radio: it is whether #a can
# start at all when nothing else is in the Dis pool.  os/inferno/
# stm32f407/mem.h records all three NPROC measurements -- at five #a gets
# "no procs for kproc" with a shell present, at seven the shell and lil
# both die, at nine even echo does -- so the way to have #a on this board
# is to not run a shell.  This is that, exercised.
#
# Both instances beacon and both listen, so each is the other's
# transmitter and neither needs a console typed at.  What is checked:
# the init reaches ARMV7M-AX25-UP, prints an iounit sixteen less than its
# carrier's, and each one hears the other's payload through #a rather
# than off the raw radio.
#
# The negative control is the second half: one instance alone, with
# nothing to hear.  It must come up and beacon and report nothing heard.
# Without it an init that printed "heard" from an uninitialised buffer
# would pass.
#
#	ax25inittest.sh /path/to/qemu-system-arm [kernel]
#
Q=${1:?usage: ax25inittest.sh <qemu-system-arm> [kernel]}
K=${2:-os/inferno/stm32f407/istm32f407}
PORT=${PORT:-15617}
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' 0
rc=0

# Two serials, so the two guests are two stations.  tools/qemu-patches
# maps the system memory region the STM32F405 SoC never had -- a guest
# reading #P/uid took a bus fault and died in its init -- and makes the
# twelve bytes come from this property.  /lib/radio has an entry for each
# of these, giving each one the other's callsign as its peer: #a matches
# an incoming frame by its SOURCE, so two stations both addressing QST
# beacon at each other and hear nothing, which is what this test found
# before the entries existed.
"$Q" -M netduinoplus2,radio=on -global stm32f405-soc.uid=0x11111111 \
    -nic socket,model=cc1120,listen=127.0.0.1:$PORT \
    -nographic -serial null -serial mon:stdio -kernel "$K" \
    > "$OUT/a" 2>&1 &
apid=$!
sleep 4
timeout 60 "$Q" -M netduinoplus2,radio=on -global stm32f405-soc.uid=0x22222222 \
    -nic socket,model=cc1120,connect=127.0.0.1:$PORT \
    -nographic -serial null -serial mon:stdio -kernel "$K" \
    > "$OUT/b" 2>&1
sleep 2
kill $apid 2>/dev/null
sleep 1

for f in a b; do
	tr -d '\r' < "$OUT/$f" > "$OUT/$f.c"
	if ! grep -q ARMV7M-AX25-UP "$OUT/$f.c"; then
		echo "AX25INITTEST-FAILED instance $f did not bring #a up:"
		grep -E '^(ax25init|ARMV7M)' "$OUT/$f.c" | tail -8
		rc=1
		continue
	fi
	car=$(sed -n 's/^ax25init: carrier iounit \([0-9]*\)$/\1/p' "$OUT/$f.c" | tail -1)
	iou=$(sed -n 's/^ax25init: ax25 iounit \([0-9]*\),.*/\1/p' "$OUT/$f.c" | tail -1)
	if [ -z "$car" ] || [ -z "$iou" ] || [ "$iou" != "$((car - 16))" ]; then
		echo "AX25INITTEST-FAILED instance $f: carrier $car, ax25 $iou,"
		echo "which is not sixteen less"
		rc=1
	else
		echo "instance $f: #a up, carrier $car, ax25 $iou"
	fi
	if ! grep -qE '^ax25init: addressing N0CALL-[89]$' "$OUT/$f.c"; then
		echo "AX25INITTEST-FAILED instance $f did not take a peer"
		echo "from /lib/radio, so it does not know who to address:"
		grep -E '^ax25init: (uid|addr|addressing|no entry)' "$OUT/$f.c"
		rc=1
	fi
	if ! grep -q 'ax25init: beacon 1$' "$OUT/$f.c"; then
		echo "AX25INITTEST-FAILED instance $f never beaconed"
		rc=1
	fi
done

for f in a b; do
	if grep -q 'ax25init: heard .*INFERNO-AX25' "$OUT/$f.c"; then
		echo "instance $f heard the other through #a:"
		grep 'ax25init: heard' "$OUT/$f.c" | head -2
	else
		echo "AX25INITTEST-FAILED instance $f heard nothing:"
		grep -cE '^ax25init: beacon' "$OUT/$f.c" | sed 's/^/  beacons sent: /'
		rc=1
	fi
done

# The control: one alone.  It must come up and hear nothing.
timeout 40 "$Q" -M netduinoplus2,radio=on -global stm32f405-soc.uid=0x11111111 \
    -nic socket,model=cc1120,listen=127.0.0.1:$((PORT+1)) \
    -nographic -serial null -serial mon:stdio -kernel "$K" \
    > "$OUT/solo" 2>&1
tr -d '\r' < "$OUT/solo" > "$OUT/solo.c"
if ! grep -q ARMV7M-AX25-UP "$OUT/solo.c"; then
	echo "AX25INITTEST-FAILED the lone instance did not come up"
	rc=1
elif grep -q 'ax25init: heard' "$OUT/solo.c"; then
	echo "AX25INITTEST-FAILED a lone instance reported hearing something,"
	echo "so \"heard\" is not coming from a packet:"
	grep 'ax25init: heard' "$OUT/solo.c" | head -3
	rc=1
else
	echo "control: alone, it came up and heard nothing"
fi

[ $rc = 0 ] && echo AX25INITTEST-OK || echo AX25INITTEST-FAILED
exit $rc
