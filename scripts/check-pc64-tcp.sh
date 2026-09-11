#!/bin/sh
# Accept an inbound TCP connection on a native kernel.
#
# Every command this branch wrote for the cloud dials out -- hget, gcs,
# cloudfs, cloudinit -- so announce() and accept() had never run on a
# kernel at all.  This boots pc64 with a forwarded port, runs
# tcpserve(1), and connects to it from the host.
#
# usage: scripts/check-pc64-tcp.sh
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
PATH=$ROOT/MacOSX/arm64/bin:$PATH
export PATH ROOT
KERN=$ROOT/os/inferno/pc64/ipc64
[ -f "$KERN" ] || { echo "check-pc64-tcp: no $KERN; mk CONF=pc64 first" >&2; exit 1; }
WORK=`mktemp -d`
trap 'kill $QPID 2>/dev/null; sleep 1; pkill -f "cdrom $WORK/t.iso" 2>/dev/null; rm -rf "$WORK"' 0
INFERNO_KERNEL=$KERN sh "$ROOT/scripts/mkinferno-efi-iso.sh" "$WORK/t.iso" >/dev/null 2>&1
cp "$ROOT/.qemu/edk2-vars.fd" "$WORK/vars.fd"
# A free port, asked for rather than assumed: a fixed one collides with
# a guest left behind by an earlier run and the forward then silently
# fails to bind, which reads exactly like the kernel refusing to listen.
PORT=`python3 -c "
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()"`
python3 "$ROOT/scripts/serve-and-hold.py" "$WORK/p" 50 60 "$WORK/log" \
	'cloudinit; tcpserve' \
	qemu-system-x86_64 -machine q35 -m 1024 -display none -smp 2 \
	-drive if=pflash,format=raw,unit=0,readonly=on,file="$ROOT/.qemu/edk2-code.fd" \
	-drive if=pflash,format=raw,unit=1,file="$WORK/vars.fd" \
	-cdrom "$WORK/t.iso" \
	-netdev user,id=net0,hostfwd=tcp:127.0.0.1:$PORT-:6666 \
	-device virtio-net,netdev=net0 \
	-chardev pipe,id=c0,path="$WORK/p" -serial chardev:c0 >/dev/null 2>&1 &
QPID=$!
n=0
while [ ! -f "$WORK/p.ready" ] && [ $n -lt 40 ]; do sleep 3; n=`expr $n + 1`; done
sleep 12
if python3 -c "
import socket,sys
try:
    s=socket.create_connection(('127.0.0.1',$PORT),timeout=10)
    d=s.recv(100).decode(errors='replace')
    sys.exit(0 if 'INFERNO-ACCEPTED' in d else 1)
except Exception:
    sys.exit(1)
"; then
	echo "check-pc64-tcp: ok -- the kernel accepted an inbound connection"
	exit 0
fi
echo "check-pc64-tcp: FAIL -- no connection accepted" >&2
exit 1
