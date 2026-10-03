#!/bin/sh
# The Linux guest for phase 4 of doc/genesize-plan.ms: an unmodified
# distribution kernel and a busybox initramfs, fetched and checked by
# checksum, so every boot of "Linux under Inferno" is of the same bytes.
#
#	.guest/vmlinuz-virt	Alpine 3.20's linux-virt 6.6.142-r0, a stock bzImage
#	.guest/busybox		busybox 1.35.0, static, x86_64 musl
#	.guest/initramfs.cpio	busybox, an /init, and the package's
#				virtio_blk, virtio_net (and what it needs),
#				ext2 and af_packet modules, cpio "newc"
#	.guest/lts/		the same from linux-lts-6.6.142-r0.apk,
#				whose igbvf (an 82576 VF's driver, M7)
#				linux-virt does not build
#	.guest/rv/Image		for the RISC-V backend (M12): Alpine 3.22's
#				riscv64 linux-lts 6.12.111-r0, its Image
#				uncompressed (vmlinux loads it as it is)
#	.guest/rv/initramfs.cpio	busybox-static 1.37.0-r20 for riscv64,
#				the same /init, and the package's virtio
#				(core, ring, mmio, blk, net) and af_packet
#				modules
#
# Kernel and modules come from one versioned package, so they match;
# the package is pinned by checksum (Alpine's netboot vmlinuz-virt,
# used before, is replaced in place on every point release).
#
# The /init mounts /proc and /sys, loads the modules, prints LINUXGUEST:
# lines a check can look for -- the kernel version, the processor count,
# uptime, the virtio disks and interfaces it found -- and then runs a
# shell on the console.  Given linuxguest.root=vda on the command line
# it boots on the guest's first virtio disk instead: mounts it (ext2),
# and if it holds a root made by the same /init (with /ONDISK), switches
# to it, where the disk's own copy of this /init says which root it is
# on and runs the shell.  A first boot makes such a root on a disk with
# busybox's mke2fs and a copy of /bin, /lib and /init.
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
# the M7 guest: linux-virt has no igbvf; linux-lts does
LPKG=linux-lts-6.6.142-r0.apk
LURL=https://dl-cdn.alpinelinux.org/alpine/v3.20/main/x86_64/$LPKG
LSUM=6a2c64473187c27b6030e146653e940672ef0eb5dd0f4905da8c0d15e4da6bb4
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
fetch "$LURL" "$LPKG" "$LSUM"
fetch "$BURL" busybox "$BSUM"
chmod +x busybox
# the RISC-V guest
mkdir -p rv
RPKG=linux-lts-6.12.111-r0.apk
RURL=https://dl-cdn.alpinelinux.org/alpine/v3.22/main/riscv64/$RPKG
RSUM=c00dba7cf81eb529e9438951a015405469227e125bf48d081294be6a69e04824
RBPKG=busybox-static-1.37.0-r20.apk
RBURL=https://dl-cdn.alpinelinux.org/alpine/v3.22/main/riscv64/$RBPKG
RBSUM=29072f0a72ff8f2ff19a8be703cf0e68d4722ea4dc0acf4830acc932f98cf31c
fetch "$RURL" "rv/$RPKG" "$RSUM"
fetch "$RBURL" "rv/$RBPKG" "$RBSUM"

python3 - "$G" "$PKG" "$LPKG" "rv/$RPKG" "rv/$RBPKG" <<'EOF'
import os, sys, stat, gzip, tarfile, io
g = sys.argv[1]

def unpack(pkgfile):
	# an apk is gzip members (signature, control, data) of concatenated
	# tar streams; read past each one's end-of-archive blocks
	pkg = tarfile.open(fileobj=io.BytesIO(gzip.open(os.path.join(g, pkgfile)).read()), ignore_zeros=True)
	members = {m.name: m for m in pkg.getmembers()}
	kver = [n.split('/')[2] for n in members if n.startswith('lib/modules/') and n.count('/') >= 3][0]
	return pkg, members, kver

def modules(pkg, members, kver, rels):
	mods = []
	for rel in rels:
		data = gzip.decompress(pkg.extractfile(members['lib/modules/%s/%s' % (kver, rel)]).read())
		mods.append((os.path.basename(rel)[:-3], data))
	return mods

pkg, members, kver = unpack(sys.argv[2])
open(os.path.join(g, 'vmlinuz-virt'), 'wb').write(pkg.extractfile(members['boot/vmlinuz-virt']).read())
# in load order: virtio_net needs net_failover, which needs failover;
# af_packet is the packet sockets udhcpc uses; ext2 (and mbcache) for a
# root on a virtio disk
mods = modules(pkg, members, kver, ('kernel/net/packet/af_packet.ko.gz',
		'kernel/fs/mbcache.ko.gz', 'kernel/fs/ext2/ext2.ko.gz',
		'kernel/net/core/failover.ko.gz', 'kernel/drivers/net/net_failover.ko.gz',
		'kernel/drivers/net/virtio_net.ko.gz', 'kernel/drivers/block/virtio_blk.ko.gz'))
init = b'''#!/bin/busybox sh
/bin/busybox echo "LINUXGUEST: init"
/bin/busybox mkdir -p /proc /sys /dev /tmp
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sys /sys
/bin/busybox mount -t devtmpfs dev /dev 2>/dev/null
/bin/busybox --install -s /bin
export PATH=/bin
if [ -e /ONDISK ]; then
	echo "LINUXGUEST: root `awk '$2 == "/" { r = $1 " " $3 } END { print r }' /proc/mounts`"
else
	for m in `cat /lib/modules/order`; do
		insmod /lib/modules/$m.ko || echo "LINUXGUEST: insmod $m failed"
	done
	if grep -q linuxguest.root=vda /proc/cmdline; then
		mkdir -p /newroot
		if mount -t ext2 /dev/vda /newroot && [ -e /newroot/ONDISK ]; then
			umount /proc /sys /dev
			exec switch_root /newroot /init
		fi
		echo "LINUXGUEST: no root on vda"
	fi
fi
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

def pad(n):
	return b'\0' * ((4 - n % 4) % 4)

def cpio(mods, path, busybox=busybox):
	order = ''.join(name[:-3] + '\n' for name, data in mods).encode()
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
		('lib/modules/order', stat.S_IFREG | 0o644, order),
	] + [('lib/modules/%s' % name, stat.S_IFREG | 0o644, data) for name, data in mods]
	out = bytearray()
	ino = 1
	def add(name, mode, data, rdev=(0, 0)):
		nonlocal ino, out
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
	open(path, 'wb').write(out)

cpio(mods, os.path.join(g, 'initramfs.cpio'))

# the M7 guest: linux-lts, whose igbvf drives an 82576 VF
pkg, members, kver = unpack(sys.argv[3])
os.makedirs(os.path.join(g, 'lts'), exist_ok=True)
open(os.path.join(g, 'lts', 'vmlinuz-lts'), 'wb').write(pkg.extractfile(members['boot/vmlinuz-lts']).read())
cpio(modules(pkg, members, kver, ('kernel/net/packet/af_packet.ko.gz',
		'kernel/drivers/net/ethernet/intel/igbvf/igbvf.ko.gz')),
	os.path.join(g, 'lts', 'initramfs.cpio'))

# the RISC-V guest: linux-lts for riscv64, whose Image (an EFI-stub
# PE that is also a bare Image, header at 0x30) is gzipped in the
# package; and busybox-static's busybox
pkg, members, kver = unpack(sys.argv[4])
open(os.path.join(g, 'rv', 'Image'), 'wb').write(gzip.decompress(pkg.extractfile(members['boot/vmlinuz-lts']).read()))
bpkg = tarfile.open(fileobj=io.BytesIO(gzip.open(os.path.join(g, sys.argv[5])).read()), ignore_zeros=True)
# virtio itself is a module here: the core and ring first, then the
# MMIO transport, the PCI one (for a function assigned to the guest),
# the disk, the console, the network and what udhcpc needs
cpio(modules(pkg, members, kver, ('kernel/drivers/virtio/virtio.ko.gz',
		'kernel/drivers/virtio/virtio_ring.ko.gz', 'kernel/drivers/virtio/virtio_mmio.ko.gz',
		'kernel/drivers/virtio/virtio_pci_legacy_dev.ko.gz', 'kernel/drivers/virtio/virtio_pci_modern_dev.ko.gz',
		'kernel/drivers/virtio/virtio_pci.ko.gz', 'kernel/drivers/char/virtio_console.ko.gz',
		'kernel/drivers/block/virtio_blk.ko.gz', 'kernel/net/core/failover.ko.gz',
		'kernel/drivers/net/net_failover.ko.gz', 'kernel/drivers/net/virtio_net.ko.gz',
		'kernel/net/packet/af_packet.ko.gz')),
	os.path.join(g, 'rv', 'initramfs.cpio'), bpkg.extractfile('bin/busybox.static').read())
EOF
ls -l "$G/vmlinuz-virt" "$G/initramfs.cpio" "$G/rv/Image" "$G/rv/initramfs.cpio"
