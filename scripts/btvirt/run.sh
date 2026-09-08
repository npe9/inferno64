#!/bin/sh
#
# Run a bench phase against BlueZ instead of against the model.
#
#	scripts/btvirt/run.sh [phase]
#
# Everything in scripts/btbench.sh talks to scripts/bthci.py, which
# was written from the same specifications by the same reader as the
# stack it is testing, so a misreading agrees with itself and passes.
# This talks to BlueZ: btvirt's btdev for the controller and the link
# layer, and emulator/bthost.c with src/shared/gatt-server.c on a
# second controller for the peer.  None of it is this tree's.
#
# The traffic goes through relay.py rather than straight at the
# published port, because that is what captures it: the same btsnoop
# the model writes, so the same tshark check can be run over a
# conversation with BlueZ.
#
set -e
ROOT=`cd \`dirname "$0"\`/../.. && pwd`
PHASE=${1:-btvirt}
PORT=${PORT:-5599}
UPPORT=${UPPORT:-5598}
EMU=${EMU:-$ROOT/MacOSX/arm64/bin/emu -c0}
OUT=${OUT:-`mktemp -d`}
mkdir -p "$OUT"
IMAGE=${IMAGE:-btvirt}
CAP="$OUT/btvirt-$PHASE.btsnoop"

if ! docker info >/dev/null 2>&1; then
	echo "btvirt: no docker daemon; start Docker and try again" >&2
	exit 1
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
	echo "btvirt: building the image"
	docker build -t "$IMAGE" "$ROOT/scripts/btvirt"
fi

cleanup() {
	docker rm -f btvirt-run >/dev/null 2>&1 || true
	kill $relay 2>/dev/null || true
	kill $emupid 2>/dev/null || true
}
trap cleanup EXIT INT TERM

docker rm -f btvirt-run >/dev/null 2>&1 || true
docker run -d --name btvirt-run -p $UPPORT:5555 "$IMAGE" >/dev/null
#
# btvirt has to be listening and the peer advertising before the guest
# scans, or the scan finds nothing and the phase fails for a reason
# that is not about either implementation.
#
i=0
while [ $i -lt 60 ]; do
	if docker logs btvirt-run 2>&1 | grep -q 'serving H4 on tcp'; then
		break
	fi
	sleep 0.5
	i=`expr $i + 1`
done
if ! docker logs btvirt-run 2>&1 | grep -q 'serving H4 on tcp'; then
	echo "BTVIRT FAIL: the container never started serving" >&2
	docker logs btvirt-run 2>&1 | tail -20 >&2
	exit 1
fi

python3 "$ROOT/scripts/btvirt/relay.py" $PORT 127.0.0.1 $UPPORT "$CAP" \
	> "$OUT/relay.log" 2>&1 &
relay=$!
sleep 1

: > "$OUT/bench-$PHASE.out"
$EMU -r "$ROOT" /dis/bt/btbench.dis "tcp!127.0.0.1!$PORT" \
	/mnt/bt /mnt/keys/btvirt $PHASE > "$OUT/bench-$PHASE.out" 2>&1 &
emupid=$!
i=0
while [ $i -lt 120 ]; do
	grep -q '^BT: done$' "$OUT/bench-$PHASE.out" && break
	kill -0 $emupid 2>/dev/null || break
	sleep 1
	i=`expr $i + 1`
done
kill $emupid 2>/dev/null || true
sleep 1
kill -9 $emupid 2>/dev/null || true

echo "=== phase $PHASE against BlueZ ==="
grep -v '^track:' "$OUT/bench-$PHASE.out" || true
echo "=== the peer said ==="
docker logs btvirt-run 2>&1 | grep '^btpeer:' || true

rc=0
if grep -q '^BT: FAILED' "$OUT/bench-$PHASE.out"; then
	echo "BTVIRT FAIL ($PHASE): an assertion failed"
	rc=1
elif ! grep -q '^BT: done$' "$OUT/bench-$PHASE.out"; then
	echo "BTVIRT FAIL ($PHASE): the run did not reach the end"
	rc=1
fi

#
# And the same independent reading of the wire the model's phases get.
#
TSHARK=`command -v tshark 2>/dev/null || true`
if [ -n "$TSHARK" ] && [ -s "$CAP" ]; then
	n=`"$TSHARK" -r "$CAP" 2>/dev/null | grep -c . || true`
	bad=`"$TSHARK" -r "$CAP" -Y '_ws.expert.severity >= 0x600000' \
		-T fields -e frame.protocols -e _ws.expert.message 2>/dev/null \
		| sed '/^$/d' | sort -u || true`
	if [ -n "$bad" ]; then
		echo "BTVIRT FAIL ($PHASE): tshark faults the capture"
		echo "$bad"
		"$TSHARK" -r "$CAP" -q -z expert 2>/dev/null | head -20
		rc=1
	else
		echo "dissected $n packets of the BlueZ conversation, no faults"
	fi
fi
echo "capture: $CAP"
if [ $rc = 0 ]; then
	echo "BTVIRT PASS ($PHASE)"
fi
exit $rc
