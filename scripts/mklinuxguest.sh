#!/bin/sh
# The Linux guest for phase 4 of doc/genesize-plan.ms: an unmodified
# distribution kernel and a busybox initramfs, fetched and checked by
# checksum, so every boot of "Linux under Inferno" is of the same bytes.
#
#	.guest/vmlinuz-virt	Alpine 3.20's linux-virt, a stock bzImage
#	.guest/busybox		busybox 1.35.0, static, x86_64 musl
#	.guest/initramfs.cpio	busybox and an /init, cpio "newc"
#
# The /init mounts /proc and /sys, prints LINUXGUEST: lines a check can
# look for -- the kernel version, the processor count, uptime -- and
# then runs a shell on the console.
#
# The kernel is pinned by checksum.  Alpine replaces the file in place
# on a point release; if the checksum no longer matches, the script
# says so and stops rather than boot a different kernel under the same
# name.  Set LINUXGUEST_KERNEL_SHA256 to accept a new one deliberately.
#
# usage: scripts/mklinuxguest.sh
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
G=$ROOT/.guest
mkdir -p "$G"
cd "$G"

KURL=https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/netboot/vmlinuz-virt
KSUM=${LINUXGUEST_KERNEL_SHA256:-be523954ad673a78c9cdfd3d473a8d39609f5901adfcc68402c67dc037a64c7e}
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
fetch "$KURL" vmlinuz-virt "$KSUM"
fetch "$BURL" busybox "$BSUM"
chmod +x busybox

python3 - "$G" <<'EOF'
import os, sys, stat
g = sys.argv[1]
init = b'''#!/bin/busybox sh
/bin/busybox echo "LINUXGUEST: init"
/bin/busybox mkdir -p /proc /sys /dev /tmp
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sys /sys
/bin/busybox mount -t devtmpfs dev /dev 2>/dev/null
/bin/busybox --install -s /bin
export PATH=/bin
echo "LINUXGUEST: up `uname -r` cpus `grep -c ^processor /proc/cpuinfo` uptime `cut -d' ' -f1 /proc/uptime`"
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
]
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
