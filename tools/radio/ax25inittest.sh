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
		echo "AX25INITTEST-FAILED instance $f did not come up:"
		grep -E '^(ax25init|ARMV7M)' "$OUT/$f.c" | tail -8
		rc=1
	fi
done

# Connected mode is what /lib/radio's role= selects, and these two
# serials carry role=caller and role=answerer -- so what this checks for
# is a link and not a beacon.  The UI path is still there for a station
# with no role, and tools/radio/ax25twosilicon.py exercises it on the
# boards.
if ! grep -q 'iounit 109 of a carrier.s 125' "$OUT/a.c"; then
	echo "AX25INITTEST-FAILED the caller's link iounit is not the"
	echo "carrier's 125 less sixteen:"
	grep -E '^ax25init: (linked|carrier)' "$OUT/a.c"
	rc=1
fi
if grep -q 'ax25init: linked to' "$OUT/a.c" &&
   grep -q 'ax25init: accepted on' "$OUT/b.c"; then
	echo "the link came up:"
	grep -h -E 'ax25init: (linked to|accepted on)' "$OUT/a.c" "$OUT/b.c"
else
	echo "AX25INITTEST-FAILED the link did not come up:"
	grep -E '^(ax25init|ARMV7M)' "$OUT/a.c" | tail -5
	grep -E '^(ax25init|ARMV7M)' "$OUT/b.c" | tail -5
	rc=1
fi
if grep -q 'ax25init: link [0-9]*: .*INFERNO-AX25' "$OUT/b.c"; then
	echo "the answerer took numbered frames off the link:"
	grep -o 'ax25init: link [0-9]*: .*' "$OUT/b.c" | tail -2
else
	echo "AX25INITTEST-FAILED nothing arrived on the link:"
	grep -E '^ax25init' "$OUT/b.c" | tail -6
	rc=1
fi
# and the state machine's own counters, which are the point of a link
if grep -q 'ax25init: sent [0-9]*, .*vs ' "$OUT/a.c"; then
	echo "the caller's link state:"
	grep -o 'ax25init: sent [0-9]*, .*' "$OUT/a.c" | tail -1
else
	echo "AX25INITTEST-FAILED the caller reported no link state"
	rc=1
fi

# THE CONTROL IS A STATION WITH NO ROLE, not a lone caller.  A caller
# alone is waiting for an answerer and cannot come up, so using one here
# would check nothing -- which is what the first version of this did, and
# it reported "the lone instance did not come up" as a failure when that
# is the correct behaviour.  A serial with no entry in /lib/radio gets no
# role, which is the UI beacon, and that can come up alone and must then
# hear nothing.
timeout 40 "$Q" -M netduinoplus2,radio=on -global stm32f405-soc.uid=0x33333333 \
    -nic socket,model=cc1120,listen=127.0.0.1:$((PORT+1)) \
    -nographic -serial null -serial mon:stdio -kernel "$K" \
    > "$OUT/solo" 2>&1
tr -d '\r' < "$OUT/solo" > "$OUT/solo.c"
if ! grep -q ARMV7M-AX25-UP "$OUT/solo.c"; then
	echo "AX25INITTEST-FAILED the lone instance did not come up"
	rc=1
elif ! grep -q 'no entry for this board' "$OUT/solo.c"; then
	echo "AX25INITTEST-FAILED the control has an entry in /lib/radio,"
	echo "so it is not the no-role station this check needs"
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
