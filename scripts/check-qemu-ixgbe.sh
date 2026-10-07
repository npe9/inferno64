#!/bin/sh
# Check the patched QEMU's 82599 (X520) model, scripts/qemu-patches/0007,
# against Linux's drivers for the part before trusting it with
# os/inferno's (doc/genesize-plan.ms, phase 16).  The bench's Linux
# (linux-lts 6.6.142, its ixgbe and ixgbevf modules) boots on QEMU
# with the 82599 behind a PCIe root port on a user network, and:
#
#	pf	ixgbe binds the physical function, reads its EEPROM and
#		SFP+ module, brings the link up at 10Gb/s, gets an address
#		by DHCP and pings the gateway
#	vf	two virtual functions made through sriov_numvfs, each
#		bound by ixgbevf, which talks to ixgbe over the mailbox
#	switch	the two VFs, one in a network namespace of its own,
#		ping each other through the 82599's internal switch, and
#		2MB goes over TCP from one VF to the other and from the
#		PF to a VF, with the drivers' TSO and checksum offloads
#
#	rss	without VFs, eight UDP flows into the PF spread over its
#		receive queues: the 82599's RSS hash and redirection table
#
# usage: scripts/check-qemu-ixgbe.sh
# needs: .qemu/local (scripts/mkqemu.sh), .guest/linux-lts-6.6.142-r0.apk
# and .guest/busybox (scripts/mklinuxguest.sh)
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
Q=$ROOT/.qemu/local/bin/qemu-system-x86_64
G=$ROOT/.guest
[ -x "$Q" ] || { echo "check-qemu-ixgbe: no $Q; scripts/mkqemu.sh first" >&2; exit 1; }
[ -f "$G/linux-lts-6.6.142-r0.apk" ] || {
	echo "check-qemu-ixgbe: no $G/linux-lts-6.6.142-r0.apk" >&2; exit 1; }
WORK=`mktemp -d`
trap 'st=$?; rm -rf "$WORK" || true; exit $st' 0

python3 - "$G" "$WORK" <<'EOF'
import sys, tarfile, gzip, stat, io
G, W = sys.argv[1], sys.argv[2]
pkg = tarfile.open(G + '/linux-lts-6.6.142-r0.apk', 'r:gz')
base = 'lib/modules/6.6.142-0-lts/kernel/'
mods = [('hwmon', 'drivers/hwmon/hwmon.ko.gz'), ('dca', 'drivers/dca/dca.ko.gz'),
	('libphy', 'drivers/net/phy/libphy.ko.gz'),
	('mdio_devres', 'drivers/net/phy/mdio_devres.ko.gz'),
	('mdio', 'drivers/net/mdio.ko.gz'),
	('ixgbe', 'drivers/net/ethernet/intel/ixgbe/ixgbe.ko.gz'),
	('ixgbevf', 'drivers/net/ethernet/intel/ixgbevf/ixgbevf.ko.gz'),
	('af_packet', 'net/packet/af_packet.ko.gz')]
open(W + '/vmlinuz', 'wb').write(pkg.extractfile('boot/vmlinuz-lts').read())
init = b'''#!/bin/busybox sh
B=/bin/busybox
say() { echo "IXGBETEST: $*"; }
fail() { say "FAIL $*"; $B dmesg | $B grep -i 'ixgbe\\|vf' | $B sed 's/^/IXGBETEST: dmesg /'; $B poweroff -f; }
$B mount -t proc proc /proc
$B mount -t sysfs sys /sys
$B mount -t devtmpfs dev /dev
for m in af_packet hwmon dca libphy mdio_devres mdio ixgbe ixgbevf; do
	$B insmod /lib/$m.ko || say "insmod $m failed"
done
$B ip link set lo up
$B sleep 2
pf=`$B ls /sys/bus/pci/drivers/ixgbe | $B grep :`
[ -n "$pf" ] || fail "ixgbe bound nothing"
pfn=`$B ls /sys/bus/pci/devices/$pf/net`
say "pf $pf $pfn"
$B dmesg | $B grep 'ixgbe ' | $B sed 's/^/IXGBETEST: dmesg /'
$B ip link set $pfn up
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
	[ "`$B cat /sys/class/net/$pfn/carrier 2>/dev/null`" = 1 ] && break
	$B sleep 1
done
[ "`$B cat /sys/class/net/$pfn/carrier 2>/dev/null`" = 1 ] || fail "pf link down"
say "pf link up speed `$B cat /sys/class/net/$pfn/speed`"
$B udhcpc -i $pfn -n -q -t 5 -s /dhcp.sh 2>&1 | $B sed 's/^/IXGBETEST: dhcp /'
$B ip addr show $pfn | $B grep 'inet ' | $B sed 's/^ */IXGBETEST: pf /'
$B ping -c 3 -W 2 10.0.2.2 >/tmp/ping 2>&1 || { $B cat /tmp/ping; fail "pf ping"; }
say "pf ping `$B grep received /tmp/ping`"
say "pf pass"

# RSS: eight UDP flows from the host, one to each forwarded port, a
# listener on each so that nothing is sent back; each receive queue's
# interrupts before and after
for p in 9001 9002 9003 9004 9005 9006 9007 9008; do
	$B nc -u -l -p $p >/dev/null 2>&1 &
done
irqs() { $B awk '/eth0-TxRx/ { s = 0; for(i = 2; i < NF - 2; i++) s += $i; print $NF, s }' /proc/interrupts; }
irqs >/tmp/before
say "rss ready"
$B sleep 30
irqs >/tmp/after
$B awk 'NR == FNR { b[$1] = $2; next } { print "IXGBETEST: rss", $1, "+" ($2 - b[$1]) }' /tmp/before /tmp/after

echo 2 >/sys/class/net/$pfn/device/sriov_numvfs || fail "sriov_numvfs"
$B sleep 6
vfs=`$B ls /sys/bus/pci/drivers/ixgbevf | $B grep :`
set -- $vfs
[ $# = 2 ] || fail "ixgbevf bound $# functions"
vf1=`$B ls /sys/bus/pci/devices/$1/net`
vf2=`$B ls /sys/bus/pci/devices/$2/net`
say "vf $1 $vf1 `$B cat /sys/class/net/$vf1/address`"
say "vf $2 $vf2 `$B cat /sys/class/net/$vf2/address`"
$B ip link show $pfn | $B grep vf | $B sed 's/^ */IXGBETEST: pf /'
say "vf pass"

$B unshare -n $B sleep 600 &
ns=$!
$B sleep 1
$B ip link set $vf2 netns $ns || fail "netns"
$B nsenter -t $ns -n $B ip link set lo up
$B nsenter -t $ns -n $B ip addr add 192.168.77.2/24 dev $vf2
$B nsenter -t $ns -n $B ip link set $vf2 up
$B ip addr add 192.168.77.1/24 dev $vf1
$B ip link set $vf1 up
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
	[ "`$B cat /sys/class/net/$vf1/carrier 2>/dev/null`" = 1 ] && break
	$B sleep 1
done
$B sleep 2
$B ping -c 3 -W 2 192.168.77.2 >/tmp/ping 2>&1 || { $B cat /tmp/ping; fail "vf ping"; }
say "switch ping `$B grep received /tmp/ping`"
$B nsenter -t $ns -n $B ping -c 3 -W 2 192.168.77.1 >/tmp/ping 2>&1 || { $B cat /tmp/ping; fail "vf ping back"; }
say "switch ping back `$B grep received /tmp/ping`"
$B mkdir -p /www
$B head -c 2097152 /dev/urandom >/www/blob
sum=`$B md5sum </www/blob`
$B nsenter -t $ns -n $B httpd -p 8080 -h /www
$B httpd -p 8080 -h /www
$B sleep 1
$B wget -q -O /tmp/blob http://192.168.77.2:8080/blob || fail "vf tcp"
[ "`$B md5sum </tmp/blob`" = "$sum" ] || fail "vf tcp data differs"
say "switch tcp vf to vf 2097152 bytes md5 ${sum%% *}"
$B nsenter -t $ns -n $B ip addr add 10.0.2.16/24 dev $vf2
$B nsenter -t $ns -n $B wget -q -O /tmp/blob2 http://10.0.2.15:8080/blob || fail "pf tcp"
[ "`$B md5sum </tmp/blob2`" = "$sum" ] || fail "pf tcp data differs"
say "switch tcp pf to vf 2097152 bytes md5 ${sum%% *}"
$B grep 'eth\\|ixgbe' /proc/interrupts | $B sed 's/^ */IXGBETEST: irq /'
say "switch pass"
say PASS
$B poweroff -f
'''
dhcp = b'''#!/bin/busybox sh
case "$1" in
bound|renew)
	/bin/busybox ifconfig $interface $ip netmask $subnet up
	[ -n "$router" ] && /bin/busybox route add default gw $router
	;;
esac
exit 0
'''
ents = [('bin', stat.S_IFDIR | 0o755, b''), ('dev', stat.S_IFDIR | 0o755, b''),
	('proc', stat.S_IFDIR | 0o755, b''), ('sys', stat.S_IFDIR | 0o755, b''),
	('lib', stat.S_IFDIR | 0o755, b''), ('tmp', stat.S_IFDIR | 0o777, b''),
	('bin/busybox', stat.S_IFREG | 0o755, open(G + '/busybox', 'rb').read()),
	('init', stat.S_IFREG | 0o755, init), ('dhcp.sh', stat.S_IFREG | 0o755, dhcp)]
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
open(W + '/ixgbe.cpio', 'wb').write(o.getvalue())
EOF

# eight host ports forwarded to the guest's 9001-9008, for RSS
PORTS=`python3 -c "
import socket
ss = [socket.socket(socket.AF_INET, socket.SOCK_DGRAM) for i in range(8)]
for x in ss: x.bind(('127.0.0.1', 0))
print(' '.join(str(x.getsockname()[1]) for x in ss))"`
FWD= i=9001
for p in $PORTS; do FWD="$FWD,hostfwd=udp:127.0.0.1:$p-:$i"; i=`expr $i + 1`; done
timeout 900 "$Q" -machine q35 -accel tcg -cpu max -smp 2 -m 1024 -display none \
	-serial stdio -device pcie-root-port,id=rp0,chassis=1 \
	-netdev user,id=n0$FWD -device ixgbe,bus=rp0,netdev=n0,mac=52:54:00:82:59:01 \
	-kernel "$WORK/vmlinuz" -initrd "$WORK/ixgbe.cpio" \
	-append "console=ttyS0 quiet loglevel=4" -no-reboot >"$WORK/ixgbe.log" 2>&1 &
QPID=$!
n=0
until grep -q 'IXGBETEST: rss ready' "$WORK/ixgbe.log" 2>/dev/null; do
	sleep 2
	n=`expr $n + 1`
	[ $n -gt 300 ] && break
	kill -0 $QPID 2>/dev/null || break
done
python3 -c "
import socket, sys, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
for k in range(40):
	for p in sys.argv[1:]:
		s.sendto(b'rss %d' % k, ('127.0.0.1', int(p)))
	time.sleep(0.05)" $PORTS
wait $QPID || true
tr -d '\r' <"$WORK/ixgbe.log" >"$WORK/log"
[ -n "$IXGBE_LOG" ] && cp "$WORK/log" "$IXGBE_LOG"
fail=0
# RSS: every receive queue took some of the flows
if [ `grep -c '^IXGBETEST: rss eth0-TxRx-[0-9]* +[1-9]' "$WORK/log"` -ge 2 ]; then
	echo "check-qemu-ixgbe: rss: pass"
else
	echo "check-qemu-ixgbe: rss: FAIL"
	fail=1
fi
for t in pf vf switch; do
	if grep -q "^IXGBETEST: $t pass" "$WORK/log"; then
		echo "check-qemu-ixgbe: $t: pass"
	else
		echo "check-qemu-ixgbe: $t: FAIL"
		fail=1
	fi
done
grep '^IXGBETEST: ' "$WORK/log" | grep -v ' pass$' | sed 's/^IXGBETEST: /	/'
grep -q '^IXGBETEST: PASS' "$WORK/log" || fail=1
exit $fail
