#!/bin/sh
# Build the QEMU the hypervisor bench runs on: upstream QEMU with the
# patches in scripts/qemu-patches applied.
#
# Each patch corrects a place where QEMU's model of a device disagrees
# with the real part, and says so in its own comment.  The kernel is
# written to the hardware; where the emulator differs, the emulator is
# what gets fixed (doc/genesize-plan.ms, section 4).
#
#	0001-igb-autonegotiate-after-reset.patch
#		the 82576 PHY negotiates by itself out of reset;
#		QEMU's waited for the driver to ask
#	0002-igb-port-status-link-bit.patch
#		PHY register 17 reports link in bit 10 on the 82576;
#		QEMU's never set it
#	0003-igb-legacy-rx-descriptors.patch
#		SRRCTL.DESCTYPE 0 means legacy receive descriptors;
#		QEMU's always wrote the advanced format (a TODO stub)
#	0004-i386-ignne-atomic.patch
#		IGNNE# is a chipset pin; QEMU's is a bit of the first
#		processor's hflags2 that any other processor's FXRSTOR
#		rewrote, unlocked, under MTTCG -- undoing the first's
#		nested-paging switch at VMRUN or #VMEXIT
#	0005-amd-iommu-bus-number-at-translation.patch
#		a requester ID carries its bus's number as it is now;
#		QEMU's AMD-Vi took it before firmware numbered the bus,
#		so a device behind a bridge was bus 0.  Also: a
#		not-present PTE is an I/O page fault, an event's
#		address is kept, and its RW flag is bit 5
#
# usage: scripts/mkqemu.sh      installs into $ROOT/.qemu/local;
#                               scripts/vmhost.sh uses it when present
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
VER=${QEMU_VERSION:-10.1.3}
SRC=$ROOT/.qemu/src
DEST=$ROOT/.qemu/local
mkdir -p "$SRC"
cd "$SRC"
[ -f qemu-$VER.tar.xz ] ||
	curl -fL -o qemu-$VER.tar.xz https://download.qemu.org/qemu-$VER.tar.xz
rm -rf qemu-$VER
tar xJf qemu-$VER.tar.xz
cd qemu-$VER
for p in "$ROOT"/scripts/qemu-patches/*.patch; do
	echo "patch: `basename $p`"
	patch -p1 <"$p"
done
# On Linux keep KVM: the nested-KVM bench (VMHOST_ACCEL=kvm) runs
# this same patched binary, and its igb needs the same corrections.
accel="--enable-tcg"
case `uname` in Linux) accel="$accel --enable-kvm";; esac
./configure --prefix="$DEST" --target-list=x86_64-softmmu \
	--without-default-features $accel --enable-slirp \
	--disable-werror >"$SRC/configure.log" 2>&1
make -j`sysctl -n hw.ncpu 2>/dev/null || nproc` >"$SRC/make.log" 2>&1
make install >>"$SRC/make.log" 2>&1
"$DEST/bin/qemu-system-x86_64" --version
