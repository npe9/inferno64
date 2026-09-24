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
#
# EMU overrides which emu serves this worktree.  The binary and the root
# are independent -- "emu -r <root>" serves <root> whatever built it --
# so the multicore branch's emu can serve this tree with no merge at all,
# which is how "does parallelvm fix it?" was answered for the cost of one
# command rather than 2700 lines.
#
#
# emu-cpu, NOT emu.
#
# There are two emu builds on MacOSX and serving Styx with the wrong one
# costs a day:
#
#	emu		is emu-cocoa -- it links Cocoa and creates an
#			NSApplication.  That is what you want at a
#			terminal, and it is the wrong thing here.
#	emu-cpu		links no Cocoa at all.  No NSApplication, no
#			window, nothing for macOS to nap.
#
# A headless emu-cocoa serving Styx is, to macOS, an app doing nothing
# visible in the background, and App Nap SUSPENDS the whole task.  From
# outside that looks like every kind of hang at once: connections
# completing their handshake in the kernel and queueing unaccepted
# (netstat -anL climbing past 1/0/128), Styx handshakes unanswered for
# minutes, CPU time frozen, SIGTERM ignored because the handler never
# runs, and then recovery with no explanation.  Eleven runs of
# tools/jtag/wedgewatch.sh against the Cocoa binary failed that way, at
# 11 to 115 abrupt disconnects.
#
# Build it with:	cd emu/MacOSX && mk CONF=emu-cpu install
#
EMU=${EMU:-$ROOT/MacOSX/arm64/bin/emu-cpu}
if [ ! -x "$EMU" ]; then
	echo "styxd: $EMU is missing; build it with" >&2
	echo "styxd:     (cd emu/MacOSX && mk CONF=emu-cpu install)" >&2
	exit 1
fi
PORT=${PORT:-6666}
#
# About -P: one `export /' per connection rather than one shared.
#
# Shared, every client mounts the same pipe to the same server, so all of
# their traffic queues on one styx hop, and one board pulling a kernel
# took a new client's handshake from 0.01s to 1.23s; per connection it
# stayed at 0.03s under the same load.
#
# It is NOT the default, because the per-connection servers do not go
# away: with remotecmd dialling every fifteen seconds the emu reached 139
# threads with a single connection open, and reads that took 30s took 70s
# and then 214s.  The isolation is real and the leak is worse.  Use it for
# a short measurement, not for a server that stays up.
#
# NOT -P by default: see below.  It isolates connections beautifully and
# leaks a server process per connection, which on a board polling every
# fifteen seconds is worse than the problem.
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

#
# Say so, loudly, if the traces are on.
#
# INFERNO_MNTDEBUG prints two lines per Styx message and INFERNO_IPDEBUG
# a few per connection.  A traced server is about thirty times slower --
# 1MB over loopback went from 0.42s to 17.4s, and a handshake from 0.001s
# to 5s -- which looks EXACTLY like the fault the traces exist to find.
# It was left on after a debugging session and the slowness was reported
# as a regression.
#
if [ -n "${INFERNO_MNTDEBUG:-}${INFERNO_IPDEBUG:-}" ]; then
	echo "styxd: WARNING: tracing is on (INFERNO_MNTDEBUG/INFERNO_IPDEBUG);" >&2
	echo "styxd: the server will be ~30x slower.  Unset them for real numbers." >&2
fi

if handshake; then
	echo "styxd: serving on $PORT (Rversion answered)"
	exit 0
fi

echo "styxd: not answering Styx; restarting"
#
# Only THIS worktree's emu.  "pkill -f 'emu -r'" also matches every
# other worktree's server and would kill other people's work.
#
#
# And ESCALATE.  A wedged emu does not die of SIGTERM: it has handlers
# installed and whatever has stopped it stops them too.  A plain pkill
# left the old process alive and holding the port, this script gave up
# after its sixty seconds, and the run that followed measured the OLD
# server -- which was already wedged, so it "reproduced the fault in one
# connection" against a binary that did not even have the new
# instrumentation in it.
#
pkill -f "emu -r $ROOT" 2>/dev/null
i=0
while pgrep -f "emu -r $ROOT" >/dev/null 2>&1 && [ $i -lt 5 ]; do
	sleep 1
	i=`expr $i + 1`
done
if pgrep -f "emu -r $ROOT" >/dev/null 2>&1; then
	echo "styxd: it ignored SIGTERM (wedged); killing it outright" >&2
	pkill -9 -f "emu -r $ROOT" 2>/dev/null
	sleep 1
fi

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
nohup "$EMU" -r "$ROOT" sh -c \
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
