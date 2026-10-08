#!/bin/sh
#
# A whole Styx-over-the-radio run with no hardware: two qemu guests,
# one exporting and one mounting, over the modelled CC1120.
#
# WHY THIS EXISTS.  Steps 5 and 6 of doc/radio-plan.ms -- ssl(3) under
# the Styx and an export over it -- have only ever been exercised on the
# two clicker2 boards, through screen, and that has cost more than the
# steps did.  A board stops answering a software reset and the arm
# cannot be run until somebody presses a button; two boards are two
# serial adapters and one wedges if anything opens the device twice;
# and every reading comes through a terminal's scrollback, which was
# returning a FROZEN FILE for two runs in a row before
# twoboard.session_for() was fixed.  None of that is about the radio.
#
# tools/qemu-patches models the part and gives it a socket back end, and
# /lib/radio already has an entry for each guest with a callsign, a peer
# and a role -- so the station init runs unmodified, and the pair is one
# command with no hands in it.  ax25inittest.sh does this for UI frames;
# this does it for a connected link with a filesystem on top.
#
# WHAT IT CHECKS, and the asymmetry is the point: the ANSWERER exports
# and the CALLER mounts, so the two ends print different things and
# neither can be mistaken for the other.  /lib/radio makes qemu2 the
# answerer and qemu1 the caller, and #a matches an incoming frame by its
# SOURCE, so each entry names the other as its peer.
#
# THE ANSWERER STARTS FIRST because it announces and waits; a caller
# that calls before anything is listening gets "ax25: no answer" and
# that is a harness fault dressed as a link fault.
#
# The negative control is the second half: the answerer alone, with
# nothing to call it.  It must announce and never export.  Without that,
# an init printing EXPORTING from a path that does not depend on a peer
# would pass this test, which is exactly the shape of mistake that put
# two "successful" runs of a kernel that never booted into this
# session's notes.
#
#	qemustyx.sh /path/to/qemu-system-arm [kernel]
#
# The kernel must be a station image -- built with INIT=armv7mstyx --
# and whether the link is encrypted is NOT this script's business: it is
# the ssl= key in /lib/radio, per board, and the script reports which
# arm each guest says it ran rather than assuming.
#
Q=${1:?usage: qemustyx.sh <qemu-system-arm> [kernel]}
K=${2:-os/inferno/stm32f407/istm32f407}
PORT=${PORT:-15723}
SECS=${SECS:-90}
# OUTDIR KEEPS THE CONSOLES.  The verdict lines below are a summary and
# the diagnosis is always in the part they leave out: the run that found
# the keyring-plus-ssl arm failing showed only that the answerer "did not
# export", when what mattered was the eleven lines after its last one.
# A harness that throws away the evidence makes you run it again.
OUT=${OUTDIR:-$(mktemp -d)}
mkdir -p "$OUT"
if [ -z "$OUTDIR" ]; then
	trap 'rm -rf "$OUT"' 0
else
	echo "qemustyx: consoles kept in $OUT"
fi
rc=0

if [ ! -f "$K" ]; then
	echo "QEMUSTYX-FAILED no kernel at $K"
	exit 1
fi

# The answerer is uid 0x22222222, which /lib/radio calls qemu2,
# N0CALL-8, role=answerer.  It also holds the socket end, which is
# unrelated to the radio roles but has to be the one started first for
# the same reason.
"$Q" -M netduinoplus2,radio=on -global stm32f405-soc.uid=0x22222222 \
    -nic socket,model=cc1120,listen=127.0.0.1:$PORT \
    -nographic -serial null -serial mon:stdio -kernel "$K" \
    < /dev/null > "$OUT/sat" 2>&1 &
satpid=$!
sleep 6
timeout $SECS "$Q" -M netduinoplus2,radio=on \
    -global stm32f405-soc.uid=0x11111111 \
    -nic socket,model=cc1120,connect=127.0.0.1:$PORT \
    -nographic -serial null -serial mon:stdio -kernel "$K" \
    < /dev/null > "$OUT/gnd" 2>&1
sleep 2
# TERM and not KILL: a SIGKILLed child makes the shell print the
# whole qemu command line, which looks like a crash in a run that
# passed.  qemu exits on TERM.
kill $satpid 2>/dev/null
sleep 1

for f in sat gnd; do
	tr -d '\r' < "$OUT/$f" > "$OUT/$f.c"
done

# WHICH KERNEL EACH GUEST RAN, printed before any verdict.  A log that
# cannot be tied to an image is how an afternoon of readings in this
# session turned out to describe a kernel that bus-faulted at startup.
for f in sat gnd; do
	echo "$f: $(grep -h 'conf stm32' "$OUT/$f.c" | head -1)"
	echo "$f: $(grep -h 'styx: ssl' "$OUT/$f.c" | head -1)"
	echo "$f: $(grep -h 'styx: call\|styx: N0CALL' "$OUT/$f.c" | head -1)"
done

if ! grep -q ARMV7M-STYX-EXPORTING "$OUT/sat.c"; then
	echo "QEMUSTYX-FAILED the answerer did not export:"
	grep -E '^(styx:|ARMV7M)' "$OUT/sat.c" | tail -10
	rc=1
fi
if ! grep -q ARMV7M-STYX-MOUNTED "$OUT/gnd.c"; then
	echo "QEMUSTYX-FAILED the caller did not mount:"
	grep -E '^(styx:|ARMV7M)' "$OUT/gnd.c" | tail -10
	rc=1
fi
# A fault on either end is a failure even if both markers appeared,
# because the markers are printed before the traffic that follows them.
for f in sat gnd; do
	if grep -qE 'fault pc|panic:' "$OUT/$f.c"; then
		echo "QEMUSTYX-FAILED $f faulted:"
		grep -nE 'fault pc|cfsr|panic:' "$OUT/$f.c" | head -4
		rc=1
	fi
done

if [ $rc -eq 0 ]; then
	echo "QEMUSTYX-PAIR-OK answerer exported and caller mounted"
	grep -h 'bytes free' "$OUT/sat.c" | tail -1 | sed 's/^/sat core: /'
fi

# THE CONTROL: the answerer alone.  It must announce and never export.
echo "=== control: the answerer with nobody calling ==="
timeout 40 "$Q" -M netduinoplus2,radio=on \
    -global stm32f405-soc.uid=0x22222222 \
    -nic socket,model=cc1120,listen=127.0.0.1:$((PORT+1)) \
    -nographic -serial null -serial mon:stdio -kernel "$K" \
    < /dev/null > "$OUT/alone" 2>&1
tr -d '\r' < "$OUT/alone" > "$OUT/alone.c"
if ! grep -q ARMV7M-STYX-LISTENING "$OUT/alone.c"; then
	echo "QEMUSTYX-FAILED the control never announced, so the pair above"
	echo "proves nothing about the link -- the harness is what changed:"
	grep -E '^(styx:|ARMV7M)' "$OUT/alone.c" | tail -8
	rc=1
elif grep -q ARMV7M-STYX-EXPORTING "$OUT/alone.c"; then
	echo "QEMUSTYX-FAILED the control EXPORTED with nobody calling it,"
	echo "so EXPORTING does not depend on a peer and the pair above is"
	echo "not evidence of a link."
	rc=1
else
	echo "QEMUSTYX-CONTROL-OK announced, never exported"
fi

exit $rc
