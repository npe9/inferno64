#!/bin/sh
# One Dis binary, two processor families, over a mounted namespace.
#
# doc/inferno-cloud-modern.ms item 11: "the same Dis binary, unmodified,
# on an amd64 instance and an arm64 instance, sharing one namespace.
# Migrating between processor families is a live and expensive industry
# problem that is normally solved by recompiling and re-qualifying an
# entire stack; here there is nothing to recompile, and that is worth
# demonstrating rather than asserting."
#
# The rented instances are still wanted -- they would add a real cloud
# network and two real machines -- but the claim itself does not need
# them.  It needs two processor families, and QEMU has both.  A pc64
# guest and a virtarm64 guest each mount the same directory from the
# same server and run the same file out of it.
#
# The program is compiled once, here, and neither guest has it in its
# image: finding it proves the mount, and running it proves the
# bytecode is what crosses the architecture boundary.  The check prints
# the file's checksum so that "the same binary" is a fact about bytes
# rather than a turn of phrase.
#
# usage: scripts/check-crossarch.sh
# needs: os/inferno/pc64/ipc64, os/inferno/virtarm64/ivirtarm64cloud,
#        .qemu/edk2-code.fd, .qemu/edk2-vars.fd, .qemu/edk2-aarch64-code.fd
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
PATH=$ROOT/MacOSX/arm64/bin:$PATH
export PATH ROOT

X86=$ROOT/os/inferno/pc64/ipc64
ARM=$ROOT/os/inferno/virtarm64/ivirtarm64cloud
for f in "$X86" "$ARM" "$ROOT/.qemu/edk2-code.fd" "$ROOT/.qemu/edk2-aarch64-code.fd"; do
	[ -f "$f" ] || { echo "check-crossarch: missing $f" >&2; exit 1; }
done

WORK=`mktemp -d`
trap 'st=$?; kill $SP 2>/dev/null || true; sleep 1; rm -rf "$WORK" || true; rm -rf "$ROOT/tmp" 2>/dev/null || true; exit $st' 0
mkdir -p "$WORK/dis" "$ROOT/tmp"

cat >"$WORK/crossarch.b" <<'LIMBO'
implement Crossarch;
include "sys.m";
	sys: Sys;
include "draw.m";
Crossarch: module { init: fn(nil: ref Draw->Context, nil: list of string); };
init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	sys->print("CROSSARCH-RAN\n");
}
LIMBO
(cd "$WORK" && limbo -I"$ROOT/module" -o "$WORK/dis/crossarch.dis" crossarch.b)
SUM=`md5sum "$WORK/dis/crossarch.dis" 2>/dev/null | awk '{print $1}'`
[ -n "$SUM" ] || SUM=`md5 -q "$WORK/dis/crossarch.dis"`

for k in "$X86" "$ARM"; do
	if strings "$k" | grep -q crossarch; then
		echo "check-crossarch: crossarch is in `basename $k`; the test would" >&2
		echo "  pass without proving the mount." >&2
		exit 1
	fi
done

PORT=`python3 -c "
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()"`

cat >"$ROOT/tmp/ca-srv.sh" <<EOF
bind -c '#U*$WORK/dis' /n/local
styxlisten -A 'tcp!*!$PORT' export /n/local
EOF
emu -r"$ROOT" /dis/sh.dis /tmp/ca-srv.sh >"$WORK/srv.log" 2>&1 &
SP=$!
sleep 5

# The guests reach this host at 10.0.2.2 through QEMU's user networking.
CMD="cloudinit; mount {mntgen} /n; mount -A tcp!10.0.2.2!$PORT /n/x; bind -a /n/x /dis; crossarch"

# amd64
cp "$ROOT/.qemu/edk2-vars.fd" "$WORK/x86vars.fd"
INFERNO_KERNEL=$X86 sh "$ROOT/scripts/mkinferno-efi-iso.sh" "$WORK/x.iso" >/dev/null 2>&1
INFERNO_CONSOLE_WAITFOR='
; ' INFERNO_CONSOLE_HOLD=45 \
timeout 420 python3 "$ROOT/scripts/type-at-console.py" "$WORK/px" 300 "$CMD" \
	qemu-system-x86_64 -machine q35 -m 1024 -display none -no-reboot \
	-drive if=pflash,format=raw,unit=0,readonly=on,file="$ROOT/.qemu/edk2-code.fd" \
	-drive if=pflash,format=raw,unit=1,file="$WORK/x86vars.fd" \
	-cdrom "$WORK/x.iso" \
	-netdev user,id=net0 -device virtio-net,netdev=net0 \
	-chardev pipe,id=c0,path="$WORK/px" -serial chardev:c0 \
	>"$WORK/x86.log" 2>/dev/null || true

# arm64
dd if=/dev/zero of="$WORK/armvars.fd" bs=1m count=64 2>/dev/null
INFERNO_KERNEL=$ARM sh "$ROOT/scripts/mkinferno-efi-disk-arm64.sh" \
	"$WORK/a.img" >/dev/null 2>&1
INFERNO_CONSOLE_WAITFOR='
; ' INFERNO_CONSOLE_HOLD=45 \
timeout 480 python3 "$ROOT/scripts/type-at-console.py" "$WORK/pa" 300 "$CMD" \
	qemu-system-aarch64 -M virt -cpu cortex-a72 -m 1024 -display none -no-reboot \
	-drive if=pflash,format=raw,readonly=on,file="$ROOT/.qemu/edk2-aarch64-code.fd" \
	-drive if=pflash,format=raw,file="$WORK/armvars.fd" \
	-drive if=none,id=hd,format=raw,file="$WORK/a.img" \
	-device virtio-blk-device,drive=hd \
	-netdev user,id=net0 -device virtio-net-device,netdev=net0 \
	-chardev pipe,id=c0,path="$WORK/pa" -serial chardev:c0 \
	>"$WORK/arm.log" 2>/dev/null || true

# "CROSSARCH-RAN" does not appear in the command, which says "crossarch",
# so only the program can have printed it.
ok=1
grep -q 'CROSSARCH-RAN' "$WORK/x86.log" || {
	echo "check-crossarch: FAIL -- amd64 did not run it" >&2
	sed -n '/mount -A/,$p' "$WORK/x86.log" | tail -8 >&2; ok=0; }
grep -q 'CROSSARCH-RAN' "$WORK/arm.log" || {
	echo "check-crossarch: FAIL -- arm64 did not run it" >&2
	sed -n '/mount -A/,$p' "$WORK/arm.log" | tail -8 >&2; ok=0; }
[ $ok = 1 ] || exit 1

echo "check-crossarch: ok -- one Dis binary ran on two processor families"
echo "  md5 $SUM  crossarch.dis, compiled once, in neither image"
echo "  amd64  pc64 under qemu-system-x86_64"
echo "  arm64  virtarm64 under qemu-system-aarch64"
echo "  each mounted it from the same server and ran it out of the mount"
