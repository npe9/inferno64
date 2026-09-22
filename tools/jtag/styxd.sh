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
# and that server wedges.  Twice in one day it sat there LISTENING,
# accepting TCP connections and never answering a single Styx
# Tversion, at 0% CPU.  The board's side of that is invisible and
# looks nothing like a server fault: kupdate blocks in its mount, the
# process spawned for it never prints, every later open of /n/remote
# blocks behind the dead mount, and the board goes quiet with every
# process asleep and cpu0 in WFI.  An afternoon went into "why is the
# board hung" for a board that was fine.
#
# A listening socket is therefore not evidence.  The check is a real
# Styx handshake, and the only cure found is a restart.
#
set -u
ROOT=`cd \`dirname "$0"\`/../.. && pwd`
PORT=${PORT:-6666}

handshake() {
	python3 - "$PORT" <<'PYEOF'
import socket, struct, sys
port = int(sys.argv[1])
try:
    s = socket.create_connection(('127.0.0.1', port), timeout=5)
    v = b'9P2000'
    body = struct.pack('<IH', 8192, len(v)) + v
    s.sendall(struct.pack('<IBH', 4+1+2+len(body), 100, 0xffff) + body)
    s.settimeout(5)
    d = s.recv(64)
    sys.exit(0 if d and d[4] == 101 else 1)   # Rversion
except Exception:
    sys.exit(1)
PYEOF
}

if handshake; then
	echo "styxd: serving on $PORT (Rversion answered)"
	exit 0
fi
echo "styxd: not answering Styx; restarting"
pkill -f "styxlisten -A 'tcp!\*!$PORT'" 2>/dev/null
pkill -f "emu -r $ROOT" 2>/dev/null
sleep 3
nohup "$ROOT/MacOSX/arm64/bin/emu" -r "$ROOT" sh -c \
	"styxlisten -A 'tcp!*!$PORT' export / ; sleep 2000000" \
	>/dev/null 2>&1 &
i=0
while [ $i -lt 20 ]; do
	sleep 1
	if handshake; then
		echo "styxd: restarted and serving on $PORT"
		exit 0
	fi
	i=`expr $i + 1`
done
echo "styxd: restarted but still not answering Styx" >&2
exit 1
