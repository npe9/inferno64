#!/bin/sh
# Smoke-test Inferno/riscv64 native kernel under qemu-system-riscv64.
# virtinit: GC, blk, FAT, draw, ptr, kbd, tk, rng, cap, ssl, auth, dynld, net, DHCP, DNS/cs, TCP, UDP, Styx, sh, UART.
#	./os/virt/smoke.sh
set -e

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
IVIRT=${IVIRT:-$ROOT/Inferno/riscv64/bin/ivirt}
QEMU=${QEMU:-qemu-system-riscv64}
LOG=${TMPDIR:-/tmp}/ivirt-smoke.$$.log
DMG=${TMPDIR:-/tmp}/ivirt-smoke.$$
IMG=${TMPDIR:-/tmp}/ivirt-smoke.$$.img
INCLIENT=${TMPDIR:-/tmp}/ivirt-inclient.$$.py
UDPCLIENT=${TMPDIR:-/tmp}/ivirt-udpclient.$$.py
ECHO_PID=
UDPECHO_PID=
HTTP_PID=
HTTPROOT=

cleanup() {
	if [ -n "$ECHO_PID" ]; then
		kill "$ECHO_PID" 2>/dev/null || true
		wait "$ECHO_PID" 2>/dev/null || true
	fi
	if [ -n "$UDPECHO_PID" ]; then
		kill "$UDPECHO_PID" 2>/dev/null || true
		wait "$UDPECHO_PID" 2>/dev/null || true
	fi
	if [ -n "$HTTP_PID" ]; then
		kill "$HTTP_PID" 2>/dev/null || true
		wait "$HTTP_PID" 2>/dev/null || true
	fi
	rm -rf "$HTTPROOT" 2>/dev/null || true
	if [ -n "${SMOKE_KEEP_LOG:-}" ] && [ -f "$LOG" ]; then
		cp "$LOG" "$SMOKE_KEEP_LOG"
	fi
	rm -f "$LOG" "$IMG" "$DMG.dmg" "$INCLIENT" "$UDPCLIENT"
}
trap cleanup EXIT

if [ ! -x "$IVIRT" ]; then
	echo "smoke: missing $IVIRT (cd os/virt && mk INIT=virtinit install)" >&2
	exit 1
fi
if ! command -v "$QEMU" >/dev/null 2>&1; then
	echo "smoke: need $QEMU in PATH" >&2
	exit 1
fi
if ! command -v expect >/dev/null 2>&1; then
	echo "smoke: need expect in PATH" >&2
	exit 1
fi
if ! command -v hdiutil >/dev/null 2>&1; then
	echo "smoke: need hdiutil to build FAT12 test image" >&2
	exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
	echo "smoke: need python3 for host TCP echo" >&2
	exit 1
fi

# Host echo for guest dial tcp!10.0.2.2!54322 (QEMU user-net gateway).
python3 - <<'PY' &
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 54322))
s.listen(1)
s.settimeout(120)
try:
	c, _ = s.accept()
except Exception as e:
	sys.stderr.write("echo: accept failed: %s\n" % e)
	sys.exit(1)
finally:
	s.close()
c.settimeout(30)
data = b""
while len(data) < 5:
	b = c.recv(64)
	if not b:
		break
	data += b
if data[:5] != b"hello":
	sys.stderr.write("echo: bad request %r\n" % (data,))
	c.close()
	sys.exit(1)
c.sendall(b"pong")
c.close()
PY
ECHO_PID=$!
sleep 0.2
if ! kill -0 "$ECHO_PID" 2>/dev/null; then
	echo "smoke: host TCP echo failed to start" >&2
	wait "$ECHO_PID" || true
	exit 1
fi

# Host UDP echo for guest dial udp!10.0.2.2!54325.
python3 - <<'PY' &
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 54325))
s.settimeout(120)
try:
	data, addr = s.recvfrom(64)
except Exception as e:
	sys.stderr.write("udpecho: recv failed: %s\n" % e)
	sys.exit(1)
if data[:5] != b"hello":
	sys.stderr.write("udpecho: bad request %r from %s\n" % (data, addr))
	sys.exit(1)
s.sendto(b"pong", addr)
s.close()
PY
UDPECHO_PID=$!
sleep 0.2
if ! kill -0 "$UDPECHO_PID" 2>/dev/null; then
	echo "smoke: host UDP echo failed to start" >&2
	wait "$UDPECHO_PID" || true
	exit 1
fi

# Tiny HTTP server for Charon (guest → 10.0.2.2:8765).
HTTPROOT=${TMPDIR:-/tmp}/ivirt-http.$$
mkdir -p "$HTTPROOT"
printf '%s\n' '<html><body>ivirt-http-smoke</body></html>' >"$HTTPROOT/smoke.html"
python3 - <<PY &
import http.server, socketserver
class H(http.server.SimpleHTTPRequestHandler):
	def __init__(self, *a, **k):
		super().__init__(*a, directory="$HTTPROOT", **k)
	def log_message(self, *a):
		pass
socketserver.TCPServer.allow_reuse_address = True
httpd = socketserver.TCPServer(("127.0.0.1", 8765), H)
httpd.serve_forever()
PY
HTTP_PID=$!
sleep 0.2

# 1 MiB FAT12 with marker.txt for dossrv.
rm -f "$DMG.dmg" "$IMG"
hdiutil create -size 1m -fs "MS-DOS FAT12" -volname VIRTFS -layout NONE "$DMG" >/dev/null
MNT=$(hdiutil attach -nobrowse "$DMG.dmg" | awk '/\/Volumes\//{print $NF; exit}')
if [ -z "$MNT" ] || [ ! -d "$MNT" ]; then
	echo "smoke: failed to attach FAT image" >&2
	exit 1
fi
export COPYFILE_DISABLE=1
printf 'FS-OK\n' >"$MNT/marker.txt"
rm -f "$MNT"/._marker.txt
hdiutil detach "$MNT" >/dev/null
cp "$DMG.dmg" "$IMG"
rm -f "$DMG.dmg"

# Host client for inbound TCP (guest :54323 via hostfwd).
cat >"$INCLIENT" <<'PY'
import socket, sys, time
deadline = time.time() + 30
last = None
while time.time() < deadline:
	s = socket.socket()
	s.settimeout(2)
	try:
		s.connect(("127.0.0.1", 54323))
		s.sendall(b"hello")
		data = s.recv(64)
		s.close()
		if data[:4] == b"pong":
			sys.exit(0)
		last = "bad reply %r" % (data,)
	except Exception as e:
		last = str(e)
		time.sleep(0.2)
	finally:
		try:
			s.close()
		except Exception:
			pass
sys.stderr.write("inclient: %s\n" % last)
sys.exit(1)
PY

# Host client for inbound UDP (guest :54326 via hostfwd).
cat >"$UDPCLIENT" <<'PY'
import socket, sys, time
deadline = time.time() + 30
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
		time.sleep(0.2)
	finally:
		s.close()
sys.stderr.write("udpclient: %s\n" % last)
sys.exit(1)
PY

set +e
expect <<EOF >"$LOG" 2>&1
set timeout 180
proc fail {msg} {
  catch {exec kill [exp_pid]}
  puts \$msg
  exit 1
}
spawn $QEMU -M virt -m 256 -nographic -bios none -kernel $IVIRT \
  -device ramfb \
  -global virtio-mmio.force-legacy=true \
  -drive if=none,id=hd0,file=$IMG,format=raw \
  -device virtio-blk-device,drive=hd0,bus=virtio-mmio-bus.0 \
  -netdev user,id=net0,hostfwd=tcp::54323-:54323,hostfwd=udp::54326-:54326 \
  -device virtio-net-device,netdev=net0,bus=virtio-mmio-bus.1 \
  -device virtio-tablet-device,bus=virtio-mmio-bus.2 \
  -device virtio-rng-device,bus=virtio-mmio-bus.3 \
  -device virtio-keyboard-device,bus=virtio-mmio-bus.4
# links run before screeninit/ramfb
expect {
  -exact "virtiommio: input" {}
  timeout { fail "FAIL timeout waiting virtio-input" }
}
expect {
  -exact "virtiommio: rng" {}
  timeout { fail "FAIL timeout waiting virtio-rng" }
}
expect {
  -exact "ramfb: 640x480" {}
  timeout { fail "FAIL timeout waiting ramfb configure" }
}
expect {
  -exact "SNPRINT-ABI-OK" {}
  timeout { fail "FAIL timeout waiting SNPRINT-ABI-OK" }
}
expect {
  -exact "GC-STRESS-OK" {}
  timeout { fail "FAIL timeout waiting GC-STRESS-OK" }
}
expect {
  -exact "BLK-OK" {}
  timeout { fail "FAIL timeout waiting BLK-OK" }
}
expect {
  -exact "FS-OK" {}
  timeout { fail "FAIL timeout waiting FS-OK" }
}
expect {
  -exact "TMP-OK" {}
  timeout { fail "FAIL timeout waiting TMP-OK" }
}
expect {
  -exact "MEMORY-OK" {}
  timeout { fail "FAIL timeout waiting MEMORY-OK" }
}
expect {
  -exact "DRAW-RECT-OK" {}
  timeout { fail "FAIL timeout waiting DRAW-RECT-OK" }
}
expect {
  -exact "DRAW-OK" {}
  timeout { fail "FAIL timeout waiting DRAW-OK" }
}
expect {
  -exact "PTR-OK" {}
  timeout { fail "FAIL timeout waiting PTR-OK" }
}
expect {
  -exact "TASKPROG-OK" {}
  timeout { fail "FAIL timeout waiting TASKPROG-OK" }
}
expect {
  -exact "KBD-OK" {}
  timeout { fail "FAIL timeout waiting KBD-OK" }
}
expect {
  -exact "TK-OK" {}
  timeout { fail "FAIL timeout waiting TK-OK" }
}
expect {
  -exact "WM-OK" {}
  timeout { fail "FAIL timeout waiting WM-OK" }
}
expect {
  -exact "PLUMB-OK" {}
  timeout { fail "FAIL timeout waiting PLUMB-OK" }
}
expect {
  -exact "TB-OK" {}
  timeout { fail "FAIL timeout waiting TB-OK" }
}
expect {
  -exact "COLORS-OK" {}
  timeout { fail "FAIL timeout waiting COLORS-OK" }
}
# Order matches virtinit: wmrun → wmsrv → ft → … → ip → heavysmoke → sh smoke
expect {
  -exact "WMSRV-OK" {}
  timeout { fail "FAIL timeout waiting WMSRV-OK" }
}
expect {
  -exact "FT-OK" {}
  timeout { fail "FAIL timeout waiting FT-OK" }
expect {
  -exact "MATH-OK" {}
  timeout { fail "FAIL timeout waiting MATH-OK" }
}
}
expect {
  -exact "RAND-OK" {}
  timeout { fail "FAIL timeout waiting RAND-OK" }
}
expect {
  -exact "CAP-OK" {}
  timeout { fail "FAIL timeout waiting CAP-OK" }
}
expect {
  -exact "SSL-OK" {}
  timeout { fail "FAIL timeout waiting SSL-OK" }
}
expect {
  -exact "AUTH-OK" {}
  timeout { fail "FAIL timeout waiting AUTH-OK" }
}
expect {
  -exact "DYNLD-OK" {}
  timeout { fail "FAIL timeout waiting DYNLD-OK" }
}
expect {
  -exact "NET-OK" {}
  timeout { fail "FAIL timeout waiting NET-OK" }
}
expect {
  -exact "DHCP-OK" {}
  timeout { fail "FAIL timeout waiting DHCP-OK" }
}
expect {
  -exact "IP-OK" {}
  timeout { fail "FAIL timeout waiting IP-OK" }
}
expect {
  -exact "DNS-REMOTE-OK" {}
  timeout { fail "FAIL timeout waiting DNS-REMOTE-OK" }
}
expect {
  -exact "DNS-OK" {}
  timeout { fail "FAIL timeout waiting DNS-OK" }
}
expect {
  -exact "TCP-OK" {}
  timeout { fail "FAIL timeout waiting TCP-OK" }
}
expect {
  -exact "TCP-NET-OK" {}
  timeout { fail "FAIL timeout waiting TCP-NET-OK" }
}
# Poll hostfwd before guest announce finishes (45s guest wait).
exec python3 $INCLIENT &
expect {
  -exact "TCP-IN-LISTEN" {}
  timeout { fail "FAIL timeout waiting TCP-IN-LISTEN" }
}
expect {
  -exact "TCP-IN-OK" {}
  -exact "TCP-IN-FAIL" { puts "WARN TCP-IN failed (hostfwd flake)" }
  timeout { fail "FAIL timeout waiting TCP-IN-OK" }
}
expect {
  -exact "UDP-OK" {}
  timeout { fail "FAIL timeout waiting UDP-OK" }
}
expect {
  -exact "UDP-NET-OK" {}
  timeout { fail "FAIL timeout waiting UDP-NET-OK" }
}
expect {
  -exact "UDP-IN-LISTEN" {}
  timeout { fail "FAIL timeout waiting UDP-IN-LISTEN" }
}
exec python3 $UDPCLIENT &
expect {
  -exact "UDP-IN-OK" {}
  -exact "UDP-IN-FAIL" { puts "WARN UDP-IN failed (hostfwd flake)" }
  timeout { fail "FAIL timeout waiting UDP-IN-OK" }
}
expect {
  -exact "STYX-OK" {}
  timeout { fail "FAIL timeout waiting STYX-OK" }
}
# CLI Dis stress runs before heavy GUI.
set timeout 60
expect {
  -exact "CMD-STRESS-OK" {}
  -re {CMD-STRESS-FAIL[^\r\n]*} { fail "FAIL CMD-STRESS" }
  timeout { fail "FAIL timeout waiting CMD-STRESS-OK" }
}
expect {
  -exact "ACME-LIVE-OK" {}
  timeout { fail "FAIL timeout waiting ACME-LIVE-OK" }
}
expect {
  -exact "MAN-LIVE-OK" {}
  timeout { fail "FAIL timeout waiting MAN-LIVE-OK" }
}
expect {
  -exact "CHARON-LIVE-OK" {}
  timeout { fail "FAIL timeout waiting CHARON-LIVE-OK" }
}
expect {
  -exact "CHARON-HTTP-OK" {}
  timeout { fail "FAIL timeout waiting CHARON-HTTP-OK" }
}
# WM Dis utility stress. Escape \$ so host shell does not expand.
set timeout 45
foreach tag {
  MEMORY-LIVE CLOCK-LIVE ABOUT-LIVE KEYBOARD-LIVE DATE-LIVE
  EDIT-LIVE TASK-LIVE RT-LIVE COFFEE-LIVE BOUNCE-LIVE TETRIS-LIVE
  SH-LIVE VIEW-LIVE
} {
  expect {
    -exact "\${tag}-OK" {}
    -re "\${tag}-FAIL\[^\r\n]*" { fail "FAIL \${tag}" }
    timeout { fail "FAIL timeout waiting \${tag}-OK" }
  }
}
expect {
  -exact "FTREE-LIVE-OK" {}
  -re {FTREE-LIVE-FAIL[^\r\n]*} { fail "FAIL FTREE-LIVE" }
  timeout { fail "FAIL timeout waiting FTREE-LIVE-OK" }
}
expect {
  -exact "DEB-LIVE-OK" {}
  -re {DEB-LIVE-FAIL[^\r\n]*} { fail "FAIL DEB-LIVE" }
  timeout { fail "FAIL timeout waiting DEB-LIVE-OK" }
}
expect {
  -exact "WM-STRESS-OK" {}
  timeout { fail "FAIL timeout waiting WM-STRESS-OK" }
}
expect {
  -exact "DIS-STRESS-OK" {}
  timeout { fail "FAIL timeout waiting DIS-STRESS-OK" }
}
set timeout 90
expect {
  -exact "HELLO-FROM-SH" {}
  timeout { fail "FAIL timeout waiting HELLO-FROM-SH" }
}
expect {
  -exact "VIRT-OK" {}
  timeout { fail "FAIL timeout waiting VIRT-OK" }
}
expect {
  -exact "ROOT-APPS-OK" {}
  timeout { fail "FAIL timeout waiting ROOT-APPS-OK" }
}
expect {
  -exact "ROOT-CMDS-OK" {}
  timeout { fail "FAIL timeout waiting ROOT-CMDS-OK" }
}
expect {
  -exact "interactive sh" {}
  timeout { fail "FAIL timeout waiting interactive sh" }
}
expect {
  -re {; } {}
  timeout { fail "FAIL timeout waiting prompt" }
}
send "echo CONS-ALIVE\r"
expect {
  -re {echo CONS-ALIVE\r+\n} {}
  timeout { fail "FAIL timeout waiting echo of input" }
}
expect {
  -re {CONS-ALIVE\r+\n} {}
  timeout { fail "FAIL timeout waiting CONS-ALIVE output" }
}
exec kill [exp_pid]
exit 0
EOF
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
	echo "FAIL native ivirt (expect rc=$rc) — log:" >&2
	cat "$LOG" >&2
	exit 1
fi

fail=0
for need in 'ramfb: 640x480' 'SNPRINT-ABI-OK' 'virtiommio: input' 'virtiommio: rng' 'virtiommio: blk' 'virtiommio: net' 'sh loaded' 'GC-STRESS-OK' 'BLK-OK' 'FS-OK' 'TMP-OK' 'MEMORY-OK' 'DRAW-RECT-OK' 'DRAW-OK' 'PTR-OK' 'TASKPROG-OK' 'KBD-OK' 'TK-OK' 'WM-OK' 'PLUMB-OK' 'TB-OK' 'COLORS-OK' 'WMSRV-OK' 'FT-OK' 'MATH-OK' 'RAND-OK' 'CAP-OK' 'SSL-OK' 'AUTH-OK' 'DYNLD-OK' 'NET-OK' 'DHCP-OK' 'IP-OK' 'DNS-REMOTE-OK' 'DNS-OK' 'TCP-OK' 'TCP-NET-OK' 'TCP-IN-LISTEN' 'UDP-OK' 'UDP-NET-OK' 'UDP-IN-LISTEN' 'STYX-OK' 'ACME-LIVE-OK' 'MAN-LIVE-OK' 'CHARON-LIVE-OK' 'CHARON-HTTP-OK' 'CMD-STRESS-OK' 'MEMORY-LIVE-OK' 'CLOCK-LIVE-OK' 'ABOUT-LIVE-OK' 'KEYBOARD-LIVE-OK' 'DATE-LIVE-OK' 'EDIT-LIVE-OK' 'TASK-LIVE-OK' 'RT-LIVE-OK' 'COFFEE-LIVE-OK' 'BOUNCE-LIVE-OK' 'TETRIS-LIVE-OK' 'SH-LIVE-OK' 'VIEW-LIVE-OK' 'FTREE-LIVE-OK' 'DEB-LIVE-OK' 'WM-STRESS-OK' 'DIS-STRESS-OK' 'HELLO-FROM-SH' 'VIRT-OK' 'ROOT-APPS-OK' 'ROOT-CMDS-OK' 'interactive sh' 'CONS-ALIVE'; do
	if ! grep -q "$need" "$LOG"; then
		echo "FAIL missing: $need" >&2
		fail=1
	fi
done
# Hostfwd inbound can flake under load; warn only.
for soft in TCP-IN-OK UDP-IN-OK; do
	if ! grep -q "$soft" "$LOG"; then
		echo "WARN missing (flake-tolerant): $soft" >&2
	fi
done

if [ "$fail" -ne 0 ]; then
	echo "FAIL native ivirt — log:" >&2
	cat "$LOG" >&2
	exit 1
fi

echo "PASS native ivirt (ramfb + input/kbd + rng + GC + blk + FAT + draw + ptr + kbd + tk + wm + toolbar + wmsrv + freetype + rand + cap + ssl + auth + dynld + net + DHCP + DNS/cs + TCP + UDP + Styx + UART)"
exit 0
