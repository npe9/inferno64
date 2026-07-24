#!/bin/sh
# Interactive Inferno/riscv64 virt under QEMU (Cocoa/GUI).
# Matches smoke.sh networking: hostfwd + host clients so TCP-IN/UDP-IN pass;
# FAT image with FS-OK marker so FS-FAIL content does not appear.
#
# Usage:
#   ./os/virt/play.sh           # foreground (Terminal: Ctrl-C / close window)
#   ./os/virt/play.sh --detach  # new session; survives parent shell exit
set -e

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
export PATH="$ROOT/MacOSX/arm64/bin:${PATH:-}"
IVIRT=${IVIRT:-$ROOT/Inferno/riscv64/bin/ivirt}
QEMU=${QEMU:-qemu-system-riscv64}
IMG=${TMPDIR:-/tmp}/ivirt-play.img
LOG=${TMPDIR:-/tmp}/ivirt-play.log
OUT=${TMPDIR:-/tmp}/ivirt-play-stdout.log
PIDFILE=${TMPDIR:-/tmp}/ivirt-play.pid
DMG=${TMPDIR:-/tmp}/ivirt-play-fat
INCLIENT=${TMPDIR:-/tmp}/ivirt-play-inclient.py
UDPCLIENT=${TMPDIR:-/tmp}/ivirt-play-udpclient.py
ECHO_PID=
UDPECHO_PID=
IN_PID=
UDPIN_PID=

# Re-exec in a new session so agent/CI shells do not kill QEMU on exit.
# macOS has no setsid(1); use Python double-fork + setsid(2).
if [ "${1:-}" = "--detach" ] && [ -z "${PLAY_DETACHED:-}" ]; then
	# absolute path — daemon may not keep our cwd
	case $0 in
	/*) PLAY_SCRIPT=$0 ;;
	*) PLAY_SCRIPT=$(CDPATH= cd -- "$(dirname "$0")" && pwd)/$(basename "$0") ;;
	esac
	rm -f "$PIDFILE"
	PLAY_SCRIPT="$PLAY_SCRIPT" OUT="$OUT" PIDFILE="$PIDFILE" python3 - <<'PY'
import os, sys
script, out, pidfile = os.environ["PLAY_SCRIPT"], os.environ["OUT"], os.environ["PIDFILE"]
if os.fork() > 0:
	sys.exit(0)
os.setsid()
if os.fork() > 0:
	sys.exit(0)
os.environ["PLAY_DETACHED"] = "1"
devnull = open("/dev/null", "rb")
logf = open(out, "w")
os.dup2(devnull.fileno(), 0)
os.dup2(logf.fileno(), 1)
os.dup2(logf.fileno(), 2)
with open(pidfile, "w") as f:
	f.write("%d\n" % os.getpid())
os.execv(script, [script])
PY
	i=0
	while [ ! -s "$PIDFILE" ] && [ "$i" -lt 50 ]; do
		sleep 0.1
		i=$((i + 1))
	done
	if [ ! -s "$PIDFILE" ]; then
		echo "play: detach failed (no pidfile); see $OUT" >&2
		exit 1
	fi
	echo "play: detached pid $(cat "$PIDFILE") log $LOG out $OUT"
	exit 0
fi

cleanup() {
	for p in "$ECHO_PID" "$UDPECHO_PID" "$IN_PID" "$UDPIN_PID"; do
		[ -n "$p" ] && kill "$p" 2>/dev/null || true
	done
}
trap cleanup EXIT INT TERM

if [ ! -x "$IVIRT" ]; then
	echo "play: missing $IVIRT (cd os/virt && mk INIT=virtinit install)" >&2
	exit 1
fi

# Host echoes for outbound guest dials (10.0.2.2).
# No accept timeout: play sessions outlive a fixed socket timeout.
python3 - <<'PY' &
import socket
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 54322))
s.listen(5)
while True:
	c, _ = s.accept()
	try:
		data = b""
		c.settimeout(30)
		while len(data) < 5:
			b = c.recv(64)
			if not b:
				break
			data += b
		if data[:5] == b"hello":
			c.sendall(b"pong")
	except Exception:
		pass
	finally:
		c.close()
PY
ECHO_PID=$!

python3 - <<'PY' &
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 54325))
while True:
	try:
		data, addr = s.recvfrom(2048)
	except Exception:
		continue
	if data[:5] == b"hello":
		s.sendto(b"pong", addr)
PY
UDPECHO_PID=$!

# FAT with FS-OK marker (same as smoke).
if ! [ -f "$IMG" ] || ! grep -q FS-OK "$IMG" 2>/dev/null; then
	rm -f "$DMG.dmg" "$IMG"
	hdiutil create -size 1m -fs "MS-DOS FAT12" -volname VIRTFS -layout NONE "$DMG" >/dev/null
	MNT=$(hdiutil attach -nobrowse "$DMG.dmg" | awk '/\/Volumes\//{print $NF; exit}')
	export COPYFILE_DISABLE=1
	printf 'FS-OK\n' >"$MNT/marker.txt"
	rm -f "$MNT"/._marker.txt
	hdiutil detach "$MNT" >/dev/null
	cp "$DMG.dmg" "$IMG"
	rm -f "$DMG.dmg"
fi

# Host clients for inbound guest listeners (via hostfwd).
cat >"$INCLIENT" <<'PY'
import socket, sys, time
deadline = time.time() + 90
last = None
while time.time() < deadline:
	s = socket.socket()
	s.settimeout(2)
	try:
		s.connect(("127.0.0.1", 54323))
		s.sendall(b"hello")
		data = s.recv(64)
		if data[:4] == b"pong":
			sys.exit(0)
		last = "bad reply %r" % (data,)
	except Exception as e:
		last = str(e)
		time.sleep(0.3)
	finally:
		try:
			s.close()
		except Exception:
			pass
sys.stderr.write("play inclient: %s\n" % last)
sys.exit(1)
PY
cat >"$UDPCLIENT" <<'PY'
import socket, sys, time
deadline = time.time() + 90
last = None
while time.time() < deadline:
	s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
	s.settimeout(2)
	try:
		s.sendto(b"hello", ("127.0.0.1", 54326))
		data, _ = s.recvfrom(64)
		if data[:4] == b"pong":
			sys.exit(0)
		last = "bad reply %r" % (data,)
	except Exception as e:
		last = str(e)
		time.sleep(0.3)
	finally:
		s.close()
sys.stderr.write("play udpclient: %s\n" % last)
sys.exit(1)
PY

python3 "$INCLIENT" &
IN_PID=$!
python3 "$UDPCLIENT" &
UDPIN_PID=$!

rm -f "$LOG"
echo "play: log $LOG"
echo "play: starting $QEMU (kill window or Ctrl-C to stop)"
"$QEMU" -M virt -m 256 -bios none -kernel "$IVIRT" \
	-name "Inferno/riscv64 virt" \
	-device ramfb -global virtio-mmio.force-legacy=true \
	-drive if=none,id=hd0,file="$IMG",format=raw \
	-device virtio-blk-device,drive=hd0,bus=virtio-mmio-bus.0 \
	-netdev user,id=net0,hostfwd=tcp::54323-:54323,hostfwd=udp::54326-:54326 \
	-device virtio-net-device,netdev=net0,bus=virtio-mmio-bus.1 \
	-device virtio-tablet-device,bus=virtio-mmio-bus.2 \
	-device virtio-rng-device,bus=virtio-mmio-bus.3 \
	-device virtio-keyboard-device,bus=virtio-mmio-bus.4 \
	-serial file:"$LOG" \
	-qmp unix:"${TMPDIR:-/tmp}/ivirt-play.qmp",server,nowait \
	-display cocoa,show-cursor=on
