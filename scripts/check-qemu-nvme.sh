#!/bin/sh
# Check the patched QEMU's NVMe additions, scripts/qemu-patches/0008,
# against Linux's own nvme driver before this kernel's sdnvme runs on
# them (doc/genesize-plan.ms, phase 16).  The bench's Linux (linux-lts
# 6.6.142, its nvme modules) boots on QEMU with one controller as a
# newer drive has it -- asking for a host memory buffer (hmpre, hmmin)
# and offering autonomous power state transitions (apst) -- and two
# namespaces, the first of 4096-byte sectors, the second of 512:
#
#	hmb	Linux's driver gives the controller its buffer; the
#		controller says it is enabled, of the size given, and
#		after a controller reset Linux gives it back and it is
#		enabled again; the host never wrote over it (QEMU's log)
#	apst	the driver turns APST on with a table of transitions;
#		idle, the controller goes down to its deepest state, and
#		a read brings it back
#	ns	both namespaces, at their sector sizes, take a write and
#		read it back
#
# usage: scripts/check-qemu-nvme.sh
# needs: x86_64-elf-gcc; .qemu/local (scripts/mkqemu.sh),
# .guest/linux-lts-6.6.142-r0.apk and .guest/busybox (mklinuxguest.sh)
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
Q=$ROOT/.qemu/local/bin/qemu-system-x86_64
G=$ROOT/.guest
[ -x "$Q" ] || { echo "check-qemu-nvme: no $Q; scripts/mkqemu.sh first" >&2; exit 1; }
WORK=`mktemp -d`
trap 'st=$?; rm -rf "$WORK" || true; exit $st' 0

x86_64-elf-gcc -static -nostdlib -ffreestanding -mgeneral-regs-only -fno-pic \
	-no-pie -O2 -o "$WORK/nvmetest" "$ROOT/tests/vm/nvmetest.c"
python3 - "$G" "$WORK" <<'EOF'
import sys, tarfile, gzip, stat, io
G, W = sys.argv[1], sys.argv[2]
pkg = tarfile.open(G + '/linux-lts-6.6.142-r0.apk', 'r:gz')
base = 'lib/modules/6.6.142-0-lts/kernel/'
mods = [('crc64', 'lib/crc64.ko.gz'),
	('crc64_rocksoft_generic', 'crypto/crc64_rocksoft_generic.ko.gz'),
	('crc64-rocksoft', 'lib/crc64-rocksoft.ko.gz'),
	('t10-pi', 'block/t10-pi.ko.gz'),
	('nvme-common', 'drivers/nvme/common/nvme-common.ko.gz'),
	('hwmon', 'drivers/hwmon/hwmon.ko.gz'),
	('nvme-core', 'drivers/nvme/host/nvme-core.ko.gz'),
	('nvme', 'drivers/nvme/host/nvme.ko.gz')]
open(W + '/vmlinuz', 'wb').write(pkg.extractfile('boot/vmlinuz-lts').read())
init = b'''#!/bin/busybox sh
B=/bin/busybox
say() { echo "NVMETEST: $*"; }
$B mount -t proc proc /proc
$B mount -t sysfs sys /sys
$B mount -t devtmpfs dev /dev
for m in crc64 crc64_rocksoft_generic crc64-rocksoft t10-pi nvme-common hwmon nvme-core nvme; do
	$B insmod /lib/$m.ko || say "insmod $m failed"
done
$B sleep 3
$B dmesg | $B grep 'nvme' | $B sed 's/^/NVMETEST: dmesg /'
for n in nvme0n1 nvme0n2; do
	[ -e /sys/block/$n ] || { say "ns $n missing"; continue; }
	lbs=`$B cat /sys/block/$n/queue/logical_block_size`
	$B head -c 1048576 /dev/urandom >/tmp/$n.in
	$B dd if=/tmp/$n.in of=/dev/$n bs=1048576 count=1 conv=fsync 2>/dev/null
	echo 3 >/proc/sys/vm/drop_caches
	$B dd if=/dev/$n of=/tmp/$n.out bs=1048576 count=1 2>/dev/null
	a=`$B md5sum </tmp/$n.in`
	b=`$B md5sum </tmp/$n.out`
	if [ "$a" = "$b" ]; then
		say "ns $n lbs $lbs sectors `$B cat /sys/block/$n/size` 1MiB written and read back md5 ${a%% *}"
	else
		say "ns $n lbs $lbs read back differs"
	fi
done
/nvmetest
echo 1 >/sys/class/nvme/nvme0/reset_controller
$B sleep 3
$B dmesg | $B grep 'nvme' | $B tail -3 | $B sed 's/^/NVMETEST: after reset dmesg /'
/nvmetest | $B grep 'hmb\\|apst enabled' | $B sed 's/NVMETEST: /NVMETEST: after reset /'
$B poweroff -f
'''
ents = [('bin', stat.S_IFDIR | 0o755, b''), ('dev', stat.S_IFDIR | 0o755, b''),
	('proc', stat.S_IFDIR | 0o755, b''), ('sys', stat.S_IFDIR | 0o755, b''),
	('lib', stat.S_IFDIR | 0o755, b''), ('tmp', stat.S_IFDIR | 0o777, b''),
	('bin/busybox', stat.S_IFREG | 0o755, open(G + '/busybox', 'rb').read()),
	('init', stat.S_IFREG | 0o755, init),
	('nvmetest', stat.S_IFREG | 0o755, open(W + '/nvmetest', 'rb').read())]
for name, rel in mods:
	ents.append(('lib/%s.ko' % name, stat.S_IFREG | 0o644,
		gzip.decompress(pkg.extractfile(base + rel).read())))
o = io.BytesIO()
def rec(ino, name, mode, data):
	name = name.encode() + b'\0'
	h = b'070701' + b''.join(b'%08x' % v for v in
		(ino, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(name), 0))
	o.write(h + name)
	o.write(b'\0' * ((4 - (len(h) + len(name)) % 4) % 4))
	o.write(data)
	o.write(b'\0' * ((4 - len(data) % 4) % 4))
for i, (n, m, d) in enumerate(ents):
	rec(i + 1, n, m, d)
rec(0, 'TRAILER!!!', 0, b'')
open(W + '/nvme.cpio', 'wb').write(o.getvalue())
EOF

dd if=/dev/zero of="$WORK/ns1.img" bs=1m count=64 2>/dev/null
dd if=/dev/zero of="$WORK/ns2.img" bs=1m count=64 2>/dev/null
timeout 900 "$Q" -machine q35 -accel tcg -cpu max -smp 2 -m 1024 -display none \
	-serial stdio -d guest_errors -D "$WORK/qemu.log" \
	-drive file="$WORK/ns1.img",if=none,format=raw,id=d1 \
	-drive file="$WORK/ns2.img",if=none,format=raw,id=d2 \
	-device pcie-root-port,id=rp0,chassis=1 \
	-device nvme,id=nv0,bus=rp0,serial=nvmetest,hmpre=8192,hmmin=2048,apst=on \
	-device nvme-ns,bus=nv0,drive=d1,nsid=1,logical_block_size=4096,physical_block_size=4096 \
	-device nvme-ns,bus=nv0,drive=d2,nsid=2 \
	-kernel "$WORK/vmlinuz" -initrd "$WORK/nvme.cpio" \
	-append "console=ttyS0 quiet loglevel=4" -no-reboot >"$WORK/nvme.log" 2>&1 || true
tr -d '\r' <"$WORK/nvme.log" >"$WORK/log"
[ -n "$NVME_LOG" ] && cp "$WORK/log" "$NVME_LOG"

fail=0
check() {
	name=$1
	shift
	if "$@"; then
		echo "check-qemu-nvme: $name: pass"
	else
		echo "check-qemu-nvme: $name: FAIL"
		fail=1
	fi
}
hmb() {
	grep -q 'nvme nvme0: allocated 32 MiB host memory buffer' "$WORK/log" &&
	grep -q '^NVMETEST: hmb enabled 1 hsize 8192 pages' "$WORK/log" &&
	grep -q '^NVMETEST: after reset hmb enabled 1 hsize 8192 pages' "$WORK/log" &&
	! grep -q 'written by the host' "$WORK/qemu.log"
}
apst() {
	grep -q '^NVMETEST: apst enabled 1' "$WORK/log" &&
	grep -q '^NVMETEST: idle 3s found in ps4' "$WORK/log" &&
	grep -q '^NVMETEST: after a read found in ps0' "$WORK/log"
}
ns() {
	grep -q '^NVMETEST: ns nvme0n1 lbs 4096 .*read back md5' "$WORK/log" &&
	grep -q '^NVMETEST: ns nvme0n2 lbs 512 .*read back md5' "$WORK/log"
}
check hmb hmb
check apst apst
check ns ns
grep '^NVMETEST: ' "$WORK/log" | grep -v 'dmesg' | sed 's/^NVMETEST: /	/'
grep '^NVMETEST: dmesg .*\(host memory\|nvme0:\)' "$WORK/log" | sed 's/^NVMETEST: /	/'
grep 'nvme' "$WORK/qemu.log" | head -5 | sed 's/^/	qemu: /'
exit $fail
