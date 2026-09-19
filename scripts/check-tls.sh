#!/bin/sh
# TLS works on a booted pc64 kernel, and plain HTTP is the control.
#
# hget over https is how this branch fetches anything from a storage
# service, and on rented instances it stopped working -- gcs died at
# "tls: record write: wrote -1/6: Hangup", the first write of the
# handshake, while hget over http to the same host got a real reply
# from the same server.  So the fault is in TLS and not in DNS,
# routing or TCP, and this check says so in one boot: it fetches the
# same URL twice, once each way, and reports both.
#
# The control matters.  A failure of the plain fetch means the run says
# nothing about TLS -- QEMU's user networking, the DNS it hands out or
# the host's own egress can all take it away -- so this reports that
# case as "cannot tell" rather than as a TLS failure.
#
# usage: scripts/check-tls.sh [url]
# needs: os/inferno/pc64/ipc64, .qemu/edk2-code.fd, .qemu/edk2-vars.fd
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
PATH=$ROOT/MacOSX/arm64/bin:$PATH
export PATH ROOT

URL=${1:-example.com/}
KERN=$ROOT/os/inferno/pc64/ipc64
[ -f "$KERN" ] || { echo "check-tls: no $KERN; mk CONF=pc64 first" >&2; exit 1; }
for f in "$ROOT/.qemu/edk2-code.fd" "$ROOT/.qemu/edk2-vars.fd"; do
	[ -f "$f" ] || { echo "check-tls: no $f" >&2; exit 1; }
done

WORK=`mktemp -d`
trap 'rm -rf "$WORK"' 0

INFERNO_KERNEL=$KERN sh "$ROOT/scripts/mkinferno-efi-iso.sh" "$WORK/t.iso" >/dev/null 2>&1
cp "$ROOT/.qemu/edk2-vars.fd" "$WORK/vars.fd"

# Each fetch prints its own marker and status, so a hang is told apart
# from a failure: a hang leaves the marker with no status after it.
CMD='cloudinit
echo PLAIN-BEGIN
hget http://'$URL' | read 60
echo PLAIN-END $status
echo TLS-BEGIN
hget https://'$URL' | read 60
echo TLS-END $status'
CMD=`echo "$CMD" | tr '\n' ';'`

INFERNO_CONSOLE_WAITFOR='
; ' INFERNO_CONSOLE_HOLD=${HOLD:-240} \
timeout ${TIMEOUT:-600} python3 "$ROOT/scripts/type-at-console.py" "$WORK/p" 90 "$CMD" \
	qemu-system-x86_64 -machine q35 -m 1024 -display none -no-reboot \
	-drive if=pflash,format=raw,unit=0,readonly=on,file="$ROOT/.qemu/edk2-code.fd" \
	-drive if=pflash,format=raw,unit=1,file="$WORK/vars.fd" \
	-cdrom "$WORK/t.iso" \
	-netdev user,id=net0 -device virtio-net,netdev=net0 \
	-chardev pipe,id=c0,path="$WORK/p" -serial chardev:c0 \
	>"$WORK/log" 2>/dev/null || true

plain=no; tls=no
grep -q 'PLAIN-END ' "$WORK/log" && plain=yes
grep -q 'TLS-END ' "$WORK/log" && tls=yes

if [ $plain = no ]; then
	echo "check-tls: cannot tell -- the plain http control did not finish"
	sed -n '/PLAIN-BEGIN/,$p' "$WORK/log" | grep -vE '^vmq|^dis:' | tail -5
	exit 1
fi
if [ $tls = yes ]; then
	echo "check-tls: ok -- http and https both fetched $URL"
	grep -E 'PLAIN-END|TLS-END' "$WORK/log" | tail -2
	exit 0
fi
echo "check-tls: FAIL -- http fetched $URL and https did not"
sed -n '/TLS-BEGIN/,$p' "$WORK/log" | grep -vE '^vmq|^dis:' | tail -6
exit 1
