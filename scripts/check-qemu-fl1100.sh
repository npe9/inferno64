#!/bin/sh
# Check the patched QEMU's FL1100 (scripts/qemu-patches/0009,
# -device fl1100-xhci) against Linux's own xHCI driver before this
# kernel's usbxhci runs on it (doc/genesize-plan.ms, phase 16).  The
# bench's Linux (linux-lts 6.6.142) boots with the FL1100 behind a PCIe
# root port and a USB stick on it:
#
#	pci	the part as its datasheet has it: 1b73:1100 rev 00, its
#		MSI-X table and pending bits in BARs 2 and 4 of their own
#	irq	xhci-pci takes MSI-X, as on the real part (whose MSI
#		works; Linux 5.16 took back the broken-MSI quirk it had
#		been given), and its interrupts arrive
#	disk	the stick, through usb-storage, takes 4MiB and gives it
#		back, Linux not complaining of the transfer events, the
#		short ones among them completed as Success; and the 16
#		scratchpad pages the part asks for were given and left
#		alone (QEMU's log says nothing of them)
#
# usage: scripts/check-qemu-fl1100.sh
# needs: .qemu/local (scripts/mkqemu.sh), .guest/linux-lts-6.6.142-r0.apk
# and .guest/busybox (scripts/mklinuxguest.sh)
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
Q=$ROOT/.qemu/local/bin/qemu-system-x86_64
G=$ROOT/.guest
[ -x "$Q" ] || { echo "check-qemu-fl1100: no $Q; scripts/mkqemu.sh first" >&2; exit 1; }
WORK=`mktemp -d`
trap 'st=$?; rm -rf "$WORK" || true; exit $st' 0

python3 - "$G" "$WORK" <<'EOF'
import sys, tarfile, gzip, stat, io, re
G, W = sys.argv[1], sys.argv[2]
pkg = tarfile.open(G + '/linux-lts-6.6.142-r0.apk', 'r:gz')
base = 'lib/modules/6.6.142-0-lts/kernel/'
paths = {}
for m in pkg.getmembers():
	if m.name.startswith(base) and m.name.endswith('.ko.gz'):
		paths[m.name.rsplit('/', 1)[1][:-6].replace('-', '_')] = m.name
data = {}
def load(key):
	if key not in data:
		data[key] = gzip.decompress(pkg.extractfile(paths[key]).read())
	return data[key]
# the modules wanted, each after what its modinfo says it depends on
order = []
def want(name):
	key = name.replace('-', '_')
	if key in order:
		return
	d = re.search(rb'depends=([^\0]*)', load(key)).group(1).decode()
	for dep in filter(None, d.split(',')):
		want(dep)
	order.append(key)
for m in ('xhci_pci', 'usb_storage', 'sd_mod'):
	want(m)
open(W + '/vmlinuz', 'wb').write(pkg.extractfile('boot/vmlinuz-lts').read())
init = ('''#!/bin/busybox sh
B=/bin/busybox
say() { echo "FLTEST: $*"; }
$B mount -t proc proc /proc
$B mount -t sysfs sys /sys
$B mount -t devtmpfs dev /dev
for m in %s; do
	$B insmod /lib/$m.ko || say "insmod $m failed"
done
for i in 1 2 3 4 5 6 7 8 9 10; do [ -b /dev/sda ] && break; $B sleep 1; done
$B dmesg | $B grep -i 'xhci\\|usb 2-1:\\|usb-storage\\|sda' | $B sed 's/^/FLTEST: dmesg /'
for d in /sys/bus/pci/drivers/xhci_hcd/*:*; do
	[ -e $d ] || continue
	say "pci ${d##*/} `$B cat $d/vendor` `$B cat $d/device` rev `$B cat $d/revision`"
	n=0
	while read s e f; do
		[ "$s" != 0x0000000000000000 ] && say "pci bar $n $s-$e"
		n=$((n+1))
	done <$d/resource
done
$B grep -i xhci /proc/interrupts | $B sed 's/^ */FLTEST: irq /'
if [ -b /dev/sda ]; then
	$B head -c 4194304 /dev/urandom >/tmp/in
	$B dd if=/tmp/in of=/dev/sda bs=65536 conv=fsync 2>/dev/null
	echo 3 >/proc/sys/vm/drop_caches
	$B dd if=/dev/sda of=/tmp/out bs=65536 count=64 2>/dev/null
	a=`$B md5sum </tmp/in`; b=`$B md5sum </tmp/out`
	[ "$a" = "$b" ] && say "disk 4MiB written and read back md5 ${a%%%% *}" || say "disk read back differs"
else
	say "no /dev/sda"
fi
$B grep -i xhci /proc/interrupts | $B sed 's/^ */FLTEST: irq after /'
$B dmesg | $B grep -i 'xhci.*\\(WARN\\|ERROR\\|error\\)\\|Transfer error\\|reset .*USB device' | $B sed 's/^/FLTEST: complaint /'
say done
$B poweroff -f
''' % ' '.join(order)).encode()
ents = [('bin', stat.S_IFDIR | 0o755, b''), ('dev', stat.S_IFDIR | 0o755, b''),
	('proc', stat.S_IFDIR | 0o755, b''), ('sys', stat.S_IFDIR | 0o755, b''),
	('lib', stat.S_IFDIR | 0o755, b''), ('tmp', stat.S_IFDIR | 0o777, b''),
	('bin/busybox', stat.S_IFREG | 0o755, open(G + '/busybox', 'rb').read()),
	('init', stat.S_IFREG | 0o755, init)]
for m in order:
	ents.append(('lib/%s.ko' % m, stat.S_IFREG | 0o644, data[m]))
o = io.BytesIO()
def rec(ino, name, mode, d):
	name = name.encode() + b'\0'
	h = b'070701' + b''.join(b'%08x' % v for v in
		(ino, mode, 0, 0, 1, 0, len(d), 0, 0, 0, 0, len(name), 0))
	o.write(h + name)
	o.write(b'\0' * ((4 - (len(h) + len(name)) % 4) % 4))
	o.write(d)
	o.write(b'\0' * ((4 - len(d) % 4) % 4))
for i, (n, m, d) in enumerate(ents):
	rec(i + 1, n, m, d)
rec(0, 'TRAILER!!!', 0, b'')
open(W + '/fl.cpio', 'wb').write(o.getvalue())
EOF

dd if=/dev/zero of="$WORK/stick.img" bs=1m count=16 2>/dev/null
timeout 900 "$Q" -machine q35 -accel tcg -cpu max -smp 2 -m 1024 -display none \
	-serial stdio -d guest_errors -D "$WORK/qemu.log" \
	-device pcie-root-port,id=rp0,chassis=1 \
	-device fl1100-xhci,id=fl,bus=rp0 \
	-drive file="$WORK/stick.img",if=none,format=raw,id=stick \
	-device usb-storage,bus=fl.0,drive=stick \
	-kernel "$WORK/vmlinuz" -initrd "$WORK/fl.cpio" \
	-append "console=ttyS0 quiet loglevel=4" -no-reboot >"$WORK/fl.log" 2>&1 || true
tr -d '\r' <"$WORK/fl.log" >"$WORK/log"
[ -n "$FL1100_LOG" ] && cp "$WORK/log" "$FL1100_LOG"

fail=0
check() {
	name=$1
	shift
	if "$@"; then
		echo "check-qemu-fl1100: $name: pass"
	else
		echo "check-qemu-fl1100: $name: FAIL"
		fail=1
	fi
}
pci() {
	grep -q '^FLTEST: pci .* 0x1b73 0x1100 rev 0x00' "$WORK/log" &&
	grep -q '^FLTEST: pci bar 2 ' "$WORK/log" &&
	grep -q '^FLTEST: pci bar 4 ' "$WORK/log"
}
irq() {
	grep '^FLTEST: irq after .*PCI-MSIX.*xhci' "$WORK/log" |
		awk '{ for(i = 5; i <= NF && $i ~ /^[0-9]+$/; i++) n += $i } END { exit !(n > 0) }'
}
disk() {
	grep -q '^FLTEST: disk 4MiB written and read back' "$WORK/log" &&
	! grep -q '^FLTEST: complaint' "$WORK/log" &&
	! grep -q 'scratchpad' "$WORK/qemu.log"
}
check pci pci
check irq irq
check disk disk
grep '^FLTEST: ' "$WORK/log" | grep -v 'dmesg' | sed 's/^FLTEST: /	/'
grep '^FLTEST: dmesg .*\(hcc params\|SuperSpeed USB device\|sda\]\)' "$WORK/log" | sed 's/^FLTEST: /	/'
grep 'xhci' "$WORK/qemu.log" | head -5 | sed 's/^/	qemu: /'
exit $fail
