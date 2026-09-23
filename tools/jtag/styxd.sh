#!/bin/sh
#
# Make sure the host is serving this worktree to the board, and PROVE
# it rather than assume it.
#
#	sh tools/jtag/styxd.sh
#
# The board's kupdate fetches its kernel over a styx mount to
#
#	emu -r <worktree> sh -c "styxlisten -A 'tcp!*!6666' export /"
#
# A listening socket is not evidence that it works, and neither is a
# running emu.  Three separate things can leave the board unable to
# fetch, and all three look identical from the board -- kupdate simply
# blocks with no message:
#
#   1. the server genuinely stops answering Styx (seen once, on a
#      server that had been up three and a half days);
#   2. styxlisten cannot announce because the port is still held from
#      the previous instance, and emu keeps running anyway because the
#      shell goes on to its sleep -- so there is a live emu, no
#      listener, and no visible error unless stderr was kept;
#   3. the emu exits and something else holds the port.
#
# Case 2 was mistaken for case 1 repeatedly across a long session, and
# cost hours.  The fixes are: wait for the port to be FREE before
# starting, keep stderr, look in it for the announce failure, and
# finish with a real Styx handshake.
#
set -u
ROOT=`cd \`dirname "$0"\`/../.. && pwd`
PORT=${PORT:-6666}
STYXFLAGS=${STYXFLAGS:-}
LOG=${LOG:-/tmp/styxd.log}

#
# Patient, and it has to be.
#
# The first version gave up after five seconds and its failures were
# read as "the server has wedged".  They were not: a server busy
# serving the board a 1.9MB kernel does not answer a new connection
# promptly, and one that had been declared wedged answered normally
# when asked again a minute later.  Several conclusions in
# doc/emu-styx-wedge-plan.ms were drawn from that and are marked
# accordingly.
#
# Three tries, thirty seconds each, and it prints how long the answer
# took so that "slow" and "dead" stop looking alike.
#
handshake() {
	python3 - "$PORT" <<'PYEOF'
import socket, struct, sys, time
port = int(sys.argv[1])
for attempt in range(3):
    t0 = time.time()
    try:
        s = socket.create_connection(('127.0.0.1', port), timeout=30)
        v = b'9P2000'
        body = struct.pack('<IH', 8192, len(v)) + v
        s.sendall(struct.pack('<IBH', 4+1+2+len(body), 100, 0xffff) + body)
        s.settimeout(30)
        d = s.recv(64)
        s.close()
        if d and d[4] == 101:
            dt = time.time() - t0
            if dt > 1.0:
                print("styxd: answered after %.1fs (slow, not dead)" % dt)
            sys.exit(0)
    except Exception:
        pass
    time.sleep(2)
sys.exit(1)
PYEOF
}

#
# Only a LISTEN blocks a new listener.
#
# The first version matched any socket on the port, so the board's
# lingering FIN_WAIT_2 connections -- which cannot stop a bind -- made
# it refuse to start the server at all, for sixty seconds, and then
# give up.  A check that is too strict fails as surely as one that is
# too lax; this one asks the question that matters.
#
portbusy() {
	netstat -an 2>/dev/null | grep "\.$PORT " | grep -q LISTEN
}

if handshake; then
	echo "styxd: serving on $PORT (Rversion answered)"
	exit 0
fi

echo "styxd: not answering Styx; restarting"
#
# Only THIS worktree's emu.  "pkill -f 'emu -r'" also matches every
# other worktree's server and would kill other people's work.
#
pkill -f "emu -r $ROOT" 2>/dev/null

#
# Wait for the port to be genuinely free.  Killing the process is not
# enough: a connection it had accepted and never served sits in
# CLOSE_WAIT and keeps the address busy, and styxlisten then fails with
# "announce writing /net/tcp/clone: Address already in use" -- into a
# log nobody was reading, while emu stayed up and looked healthy.
#
i=0
while portbusy && [ $i -lt 60 ]; do
	sleep 1
	i=`expr $i + 1`
done
if portbusy; then
	echo "styxd: port $PORT still busy after ${i}s:" >&2
	netstat -an 2>/dev/null | grep "\.$PORT " >&2
	exit 1
fi

: > "$LOG"
#
# STYXFLAGS passes extra styxlisten flags (-T times each connection's
# setup, -v is verbose).  Starting the server by hand instead, to get a
# flag in, is how "Address already in use" was walked into four times in
# one session: this script waits for the port and that hand-rolled
# command does not, so the server silently never announced and the next
# hour of measurements were of nothing at all.
#
nohup "$ROOT/MacOSX/arm64/bin/emu" -r "$ROOT" sh -c \
	"styxlisten ${STYXFLAGS:-} -A 'tcp!*!$PORT' export / ; sleep 2000000" \
	>"$LOG" 2>&1 &

i=0
while [ $i -lt 40 ]; do
	sleep 1
	if handshake; then
		echo "styxd: restarted and serving on $PORT (waited ${i}s for the port)"
		exit 0
	fi
	if grep -q 'cannot announce' "$LOG" 2>/dev/null; then
		echo "styxd: styxlisten could not announce:" >&2
		grep 'cannot announce' "$LOG" >&2
		exit 1
	fi
	i=`expr $i + 1`
done
echo "styxd: restarted but still not answering Styx; its output:" >&2
tail -5 "$LOG" >&2
exit 1
