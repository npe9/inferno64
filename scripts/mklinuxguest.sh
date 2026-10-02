#!/bin/sh
# The Linux guest for phase 4 of doc/genesize-plan.ms: an unmodified
# distribution kernel and a busybox initramfs, fetched and checked by
# checksum, so every boot of "Linux under Inferno" is of the same bytes.
#
#	.guest/vmlinuz-virt	Alpine 3.20's linux-virt 6.6.142-r0, a stock bzImage
#	.guest/busybox		busybox 1.35.0, static, x86_64 musl
#	.guest/initramfs.cpio	busybox, an /init, and the package's
#				virtio_blk, virtio_net (and what it needs)
#				and af_packet modules, cpio "newc"
#
# Kernel and modules come from one versioned package, so they match;
# the package is pinned by checksum (Alpine's netboot vmlinuz-virt,
# used before, is replaced in place on every point release).
#
# The /init mounts /proc and /sys, loads the modules, prints LINUXGUEST:
# lines a check can look for -- the kernel version, the processor count,
# uptime, the virtio disks and interfaces it found -- and then runs a
# shell on the console.
#
# usage: scripts/mklinuxguest.sh
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
G=$ROOT/.guest
mkdir -p "$G"
cd "$G"

PKG=linux-virt-6.6.142-r0.apk
PURL=https://dl-cdn.alpinelinux.org/alpine/v3.20/main/x86_64/$PKG
PSUM=0d84e30c04c52426b0bf10b01616c45f7d0c5384a59552e4c4a6caeb13a3f6e7
BURL=https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox
BSUM=6e123e7f3202a8c1e9b1f94d8941580a25135382b99e8d3e34fb858bba311348

fetch() {
	url=$1; out=$2; sum=$3
	if [ ! -f "$out" ] || [ "`shasum -a 256 "$out" | cut -d' ' -f1`" != "$sum" ]; then
		curl -fsSL -o "$out.new" "$url"
		got=`shasum -a 256 "$out.new" | cut -d' ' -f1`
		if [ "$got" != "$sum" ]; then
			echo "mklinuxguest: $url has sha256 $got, not $sum" >&2
			rm -f "$out.new"
			exit 1
		fi
		mv "$out.new" "$out"
	fi
}
fetch "$PURL" "$PKG" "$PSUM"
fetch "$BURL" busybox "$BSUM"
chmod +x busybox

python3 - "$G" "$PKG" <<'EOF'
import os, sys, stat, gzip, tarfile, io
g = sys.argv[1]
# an apk is gzip members (signature, control, data) of concatenated tar
# streams; read past each one's end-of-archive blocks
pkg = tarfile.open(fileobj=io.BytesIO(gzip.open(os.path.join(g, sys.argv[2])).read()), ignore_zeros=True)
members = {m.name: m for m in pkg.getmembers()}
open(os.path.join(g, 'vmlinuz-virt'), 'wb').write(pkg.extractfile(members['boot/vmlinuz-virt']).read())
kver = [n.split('/')[2] for n in members if n.startswith('lib/modules/') and n.count('/') >= 3][0]
mods = []	# in load order: virtio_net needs net_failover, which needs failover;
		# af_packet is the packet sockets udhcpc uses
for rel in ('kernel/net/packet/af_packet.ko.gz',
		'kernel/net/core/failover.ko.gz', 'kernel/drivers/net/net_failover.ko.gz',
		'kernel/drivers/net/virtio_net.ko.gz', 'kernel/drivers/block/virtio_blk.ko.gz'):
	data = gzip.decompress(pkg.extractfile(members['lib/modules/%s/%s' % (kver, rel)]).read())
	mods.append((os.path.basename(rel)[:-3], data))
init = b'''#!/bin/busybox sh
/bin/busybox echo "LINUXGUEST: init"
/bin/busybox mkdir -p /proc /sys /dev /tmp
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sys /sys
/bin/busybox mount -t devtmpfs dev /dev 2>/dev/null
/bin/busybox --install -s /bin
export PATH=/bin
for m in af_packet failover net_failover virtio_net virtio_blk; do
	insmod /lib/modules/$m.ko || echo "LINUXGUEST: insmod $m failed"
done
echo "LINUXGUEST: up `uname -r` cpus `grep -c ^processor /proc/cpuinfo` uptime `cut -d' ' -f1 /proc/uptime`"
for d in /sys/block/vd*; do
	[ -e $d ] && echo "LINUXGUEST: disk ${d##*/} `cat $d/size` sectors"
done
for n in /sys/class/net/eth*; do
	[ -e $n ] && echo "LINUXGUEST: net ${n##*/} `cat $n/address`"
done
echo "LINUXGUEST: shell"
/bin/sh
# pid 1 must not exit: a shell given end of file on its input would
# otherwise panic the kernel
echo "LINUXGUEST: shell exited"
while :; do sleep 3600; done
'''
busybox = open(os.path.join(g, 'busybox'), 'rb').read()
entries = [
	('.', stat.S_IFDIR | 0o755, b''),
	('bin', stat.S_IFDIR | 0o755, b''),
	('dev', stat.S_IFDIR | 0o755, b''),
	('proc', stat.S_IFDIR | 0o755, b''),
	('sys', stat.S_IFDIR | 0o755, b''),
	('tmp', stat.S_IFDIR | 0o1777, b''),
	('bin/busybox', stat.S_IFREG | 0o755, busybox),
	('init', stat.S_IFREG | 0o755, init),
	('lib', stat.S_IFDIR | 0o755, b''),
	('lib/modules', stat.S_IFDIR | 0o755, b''),
] + [('lib/modules/%s' % name, stat.S_IFREG | 0o644, data) for name, data in mods]
def pad(n):
	return b'\0' * ((4 - n % 4) % 4)
out = bytearray()
ino = 1
def add(name, mode, data, rdev=(0, 0)):
	global ino, out
	nb = name.encode() + b'\0'
	hdr = b'070701' + b''.join(b'%08X' % v for v in (
		ino, mode, 0, 0, 1, 0, len(data), 0, 0, rdev[0], rdev[1], len(nb), 0))
	out += hdr + nb + pad(110 + len(nb)) + data + pad(len(data))
	ino += 1
for name, mode, data in entries:
	add(name, mode, data)
# the console, before devtmpfs is mounted
add('dev/console', stat.S_IFCHR | 0o600, b'', (5, 1))
add('TRAILER!!!', 0, b'')
out += b'\0' * ((512 - len(out) % 512) % 512)
open(os.path.join(g, 'initramfs.cpio'), 'wb').write(out)
EOF
ls -l "$G/vmlinuz-virt" "$G/initramfs.cpio"
