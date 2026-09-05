#!/usr/bin/env bash
#
# mkbootfs9front.sh -- build a 9front kernel's boot file system out of
# the programs this tree built.
#
# A 9front kernel carries a small file system inside it: paqfs and
# factotum as separate images, and bootfs.paq, a paq archive holding
# the dozen or so programs the boot needs before there is a real root
# -- rc, bind, mount, ip/ipconfig, aux/kbdfs and the rest.  What goes
# in it is named by proto files under os/9front/boot, and which of
# those apply depends on what devices the configuration links: a
# kernel with devsd, devfs or devusb also takes disk.proto, and a
# kernel with a driver that has a proto beside it takes that too.
# That is the rule sys/src/9/boot/bootmkfile states, and it is the
# rule followed here.
#
# On 9front this is two commands in /bin, mkpaqfs and disk/mkfs, and
# the kernel mkfile runs them.  Here they run on the build machine:
# 9front-glue/host/mkhost.sh builds mkpaqfs from 9front's own source
# and mkbootfs -- the part of disk/mkfs a boot file system needs --
# from ours.
#
# The tree it archives comes from $ROOT/9front, which is the root the
# build fills in, so what the kernel boots into is what this
# toolchain compiled.  Run scripts/mkroot9front.sh first: the proto
# names rc scripts and keyboard maps that no compiler produces.
#
# The archive is written where the kernel mkfile takes it from,
# which is os/9front/boot rather than the configuration's own
# directory: bootmkfile has a rule copying it across, and writing
# only the copy would leave the next mk restoring the old one over
# it.
#
# Usage: scripts/mkbootfs9front.sh [-o objtype] [kernel-directory]
# Default kernel directory: os/9front/pc64.

set -eu

cd "$(dirname "$0")/.."
ROOT=$PWD
export ROOT

objtype=amd64
if [ "${1:-}" = "-o" ]; then objtype=$2; shift 2; fi
export objtype

dir=${1:-os/9front/pc64}
conf=$(basename "$dir")
cd "$ROOT/$dir"

bin=$ROOT/9front/host/bin
bash "$ROOT/9front-glue/host/mkhost.sh" >/dev/null

#
# Which protos apply, by the rule in 9front's boot/bootmkfile: the
# configuration's own if it has one, else the kernel's, else the
# generic; then disk.proto if the kernel has a disk-shaped device;
# then any driver proto whose name matches an object that was built.
#
protos=
for p in "$conf.bootfs.proto" bootfs.proto ../boot/bootfs.proto; do
	if [ -r "$p" ]; then protos=$p; break; fi
done
[ -n "$protos" ] || { echo "no bootfs proto for $conf" >&2; exit 1; }

for d in devfs devsd devusb; do
	if ls "$d".[0-9a-z] >/dev/null 2>&1; then
		protos="$protos ../boot/disk.proto"
		break
	fi
done
for p in ../boot/*.proto; do
	b=$(basename "$p" .proto)
	case "$b" in
	bootfs|disk)	continue;;
	esac
	if ls "$b".[0-9a-z] >/dev/null 2>&1; then
		protos="$protos $p"
	fi
done

out=$ROOT/os/9front/boot/$conf.bootfs.paq

echo "protos: $protos"
rm -rf "$conf.bootfs"
# shellcheck disable=SC2086
"$bin/mkbootfs" -d "$conf.bootfs" -s "$ROOT/9front" $protos
n=$(find "$conf.bootfs" -type f | wc -l | tr -d ' ')
"$bin/mkpaqfs" -9 -b 65536 -o "$out" "$conf.bootfs"
rm -rf "$conf.bootfs"
rm -f "$conf.bootfs.paq"

echo "$out: $n files, $(wc -c < "$out" | tr -d ' ') bytes"
