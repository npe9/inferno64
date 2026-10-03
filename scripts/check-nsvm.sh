#!/bin/sh
# Phase 12 of doc/genesize-plan.ms: a machine assembled from a namespace
# of resources, its disk a file on another machine.
#
# This machine (the Mac) makes a 1 MiB disk image with a marker in its
# first sector and exports its directory over Styx from hosted Inferno
# (emu).  The native host (os/inferno/pc64/pc64nsvm, nsvminit.b) boots
# on the vmhost bench with the port in plan9.ini, mounts that directory,
# assembles a machine in its own namespace -- the kernel and initrd
# from its root, the disk bound from the Mac's mount, the bench's
# virtio NIC bound as its network -- and boots it with vmlinux -N.  The
# guest's virtio disk is then read and written over Styx, to and from
# the file here: it must say the Mac's marker, the file must hold what
# it wrote, and it must get a DHCP lease on the bound network.
#
# usage: scripts/check-nsvm.sh
# needs: os/inferno/pc64/ipc64nsvm, emu
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
PATH=$ROOT/MacOSX/arm64/bin:$PATH
export PATH ROOT
KERN=$ROOT/os/inferno/pc64/ipc64nsvm
[ -f "$KERN" ] || { echo "check-nsvm: no $KERN; mk CONF=pc64nsvm first" >&2; exit 1; }
WORK=`mktemp -d`
PORT=`python3 -c "
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()"`
D=$ROOT/tmp/nsvm		# emu's /tmp/nsvm
trap 'st=$?; kill $EMU 2>/dev/null || true; pkill -f "qemu-system-x86_64.*vmhost-nsvm" 2>/dev/null || true; rm -rf "$WORK" "$D" || true; exit $st' 0

mkdir -p "$D"
python3 - "$D/disk.img" <<'EOF'
import sys
b = bytearray(1024*1024)
b[0:15] = b"DISK-ON-THE-MAC"
open(sys.argv[1], 'wb').write(b)
EOF

# the Mac's directory, over Styx
emu -r"$ROOT" /dis/sh.dis -c "ndb/cs; styxlisten -A 'tcp!*!$PORT' export /tmp/nsvm; echo NSVM-MAC: listening; sleep 100000" >"$WORK/emu.log" 2>&1 &
EMU=$!
n=0
until grep -q 'NSVM-MAC: listening' "$WORK/emu.log"; do
	sleep 1
	n=`expr $n + 1`
	[ $n -gt 30 ] && { echo "check-nsvm: FAIL -- emu did not listen"; cat "$WORK/emu.log"; exit 1; }
done

export VMHOST_TAG=nsvm VMHOST_ISO=$ROOT/.qemu/vmhost-nsvm.iso
INFERNO_INI="nsvmport=$PORT" sh "$ROOT/scripts/vmhost.sh" build "$KERN" >"$WORK/build.out" 2>&1 \
|| { echo "check-nsvm: FAIL -- building the bench image"; tail -5 "$WORK/build.out"; exit 1; }
sh "$ROOT/scripts/vmhost.sh" run 1200 >/dev/null 2>&1 &
L=$ROOT/.qemu/vmhost-nsvm.log
n=0
until grep -a -q 'NSVM: done\|NSVM: FAIL' "$L" 2>/dev/null; do
	sleep 5
	n=`expr $n + 1`
	[ $n -gt 230 ] && break
done
pkill -f "qemu-system-x86_64.*vmhost-nsvm" 2>/dev/null || true
tr -d '\r' <"$L" | grep -a 'NSVM\|vmlinux: \(machine\|virtio\|go\)\|LINUXGUEST: \(vda\|wrote\|dhcp\|ran\)\|^--\|^d-\|/tmp/m' | grep -v 'echo\|then' | sed 's/^/host: /'

ok=1
tr -d '\r' <"$L" | grep -a -q '^LINUXGUEST: vda says DISK-ON-THE-MAC' || { echo "check-nsvm: the guest did not read the Mac's marker"; ok=0; }
got=`dd if="$D/disk.img" bs=512 skip=1 count=1 2>/dev/null | head -c 20`
[ "$got" = "written-by-the-guest" ] || { echo "check-nsvm: the file on the Mac does not hold the guest's write (has '$got')"; ok=0; }
tr -d '\r' <"$L" | grep -a -q '^LINUXGUEST: dhcp udhcpc: lease of' || { echo "check-nsvm: no DHCP lease on the bound network"; ok=0; }
if [ $ok = 1 ]; then
	echo "check-nsvm: pass -- a machine built from a namespace: its disk a file on the Mac over Styx, read and written by the guest; its network a bound ether(3) directory"
	exit 0
fi
echo "check-nsvm: FAIL"
exit 1
