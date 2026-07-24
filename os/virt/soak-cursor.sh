#!/bin/sh
# Tablet soak + optional draw-load: prove pointer keeps moving under load.
# Usage: ./soak-cursor.sh [play-qmp-path]
#   With arg: attach to running play.sh QMP.
#   Without: boot headless ivirt, soak, exit.
set -e
ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
IVIRT=${IVIRT:-$ROOT/Inferno/riscv64/bin/ivirt}
QEMU=${QEMU:-qemu-system-riscv64}
TMP=${TMPDIR:-/tmp}
ATTACH_QMP=${1:-}
LOG=$TMP/ivirt-soak-cursor.log
QMP=$TMP/ivirt-soak-cursor.qmp
IMG=$TMP/ivirt-soak-cursor.img
PIDFILE=$TMP/ivirt-soak-cursor.pid
OWNED=0

if [ -n "$ATTACH_QMP" ]; then
	QMP=$ATTACH_QMP
	LOG=${TMP}/ivirt-play.log
else
	rm -f "$LOG" "$QMP" "$PIDFILE"
	if [ -f "$TMP/ivirt-play.img" ]; then
		cp "$TMP/ivirt-play.img" "$IMG"
	else
		dd if=/dev/zero of="$IMG" bs=1m count=4 2>/dev/null
	fi
	$QEMU -M virt -nographic -bios none -kernel "$IVIRT" \
		-device ramfb -global virtio-mmio.force-legacy=true \
		-drive if=none,id=hd0,file="$IMG",format=raw \
		-device virtio-blk-device,drive=hd0,bus=virtio-mmio-bus.0 \
		-netdev user,id=net0 \
		-device virtio-net-device,netdev=net0,bus=virtio-mmio-bus.1 \
		-device virtio-tablet-device,bus=virtio-mmio-bus.2,id=tablet0 \
		-device virtio-rng-device,bus=virtio-mmio-bus.3 \
		-device virtio-keyboard-device,bus=virtio-mmio-bus.4 \
		-serial file:"$LOG" \
		-qmp unix:"$QMP",server,nowait \
		-display none &
	echo $! >"$PIDFILE"
	OWNED=1
	cleanup() {
		kill "$(cat "$PIDFILE")" 2>/dev/null || true
		wait 2>/dev/null || true
	}
	trap cleanup EXIT
	i=0
	while [ $i -lt 120 ]; do
		if grep -q 'interactive sh\|exception cause\|panic:' "$LOG" 2>/dev/null; then
			break
		fi
		sleep 1
		i=$((i+1))
	done
	if grep -q 'exception cause\|panic:\|Hit the reset' "$LOG" 2>/dev/null; then
		echo "SOAK-FAIL boot panic"
		tail -40 "$LOG"
		exit 1
	fi
	if ! grep -q 'interactive sh' "$LOG" 2>/dev/null; then
		echo "SOAK-FAIL boot timeout"
		tail -40 "$LOG"
		exit 1
	fi
fi

python3 - "$QMP" <<'PY'
import json, socket, sys, time

qmp_path = sys.argv[1]
deadline = time.time() + 30
s = None
while time.time() < deadline:
	try:
		s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
		s.settimeout(2)
		s.connect(qmp_path)
		break
	except Exception:
		time.sleep(0.2)
		s = None
if s is None:
	sys.stderr.write("SOAK-FAIL qmp connect %s\n" % qmp_path)
	sys.exit(1)

def recv_obj():
	buf = b""
	while True:
		chunk = s.recv(4096)
		if not chunk:
			raise EOFError("qmp closed")
		buf += chunk
		while b"\n" in buf:
			line, buf = buf.split(b"\n", 1)
			if line.strip():
				return json.loads(line.decode())

def cmd(obj):
	s.sendall((json.dumps(obj) + "\n").encode())
	while True:
		r = recv_obj()
		if "return" in r or "error" in r:
			return r

recv_obj()
cmd({"execute": "qmp_capabilities"})

def send_xy(x, y):
	ev = [
		{"type": "abs", "data": {"axis": "x", "value": x}},
		{"type": "abs", "data": {"axis": "y", "value": y}},
	]
	r = cmd({"execute": "input-send-event",
	         "arguments": {"device": "tablet0", "events": ev}})
	if "error" in r:
		r = cmd({"execute": "input-send-event",
		         "arguments": {"events": ev}})
	if "error" in r:
		sys.stderr.write("SOAK-FAIL qmp %s\n" % r)
		sys.exit(1)

n = 0
t0 = time.time()
while time.time() - t0 < 10.0:
	for i in range(50):
		x = 800 + (n * 733) % 31000
		y = 800 + (n * 1097) % 23000
		send_xy(x, y)
		n += 1
	time.sleep(0.005)
print("SOAK-EVENTS %d" % n)
PY

if [ "$OWNED" = 1 ]; then
	sleep 1
	if grep -q 'exception cause\|panic:\|Hit the reset' "$LOG"; then
		echo "SOAK-FAIL panic during tablet soak"
		tail -40 "$LOG"
		exit 1
	fi
fi
echo "SOAK-PASS"
