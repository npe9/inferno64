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
#	0006-i386-tcg-vmx.patch
#		VMX, which TCG did not implement: VMXON and the VMCS
#		instructions, VM entry with its checks, VM exits, the
#		execution controls, EPT, VPID, unrestricted guest
#		(target/i386/tcg/system/vmx_helper.c), advertised in
#		the capability MSRs only as far as it goes.  And what
#		kvm-unit-tests' VMX tests found TCG's processor doing
#		that a real one does not: no #GP for CR0 bits 63:32;
#		MWAIT with no MONITOR halting; IA32_TSC reading 0;
#		#GP, not #SS, for a non-canonical stack address;
#		walks under nested paging reporting reads as writes;
#		an accessed flag set in a PAE PDPTE (bit 5 is
#		reserved there); no PDPTE registers; DR6 written for
#		a #DB that exits; no accessed flag set on loading CS
#		or SS; LTR leaving TR not busy; one interrupt shadow
#		for STI and MOV SS.  scripts/check-qemu-vmx.sh checks
#		it against kvm-unit-tests and Linux's kvm_intel
#	0007-net-ixgbe-82599-sriov.patch
#		the 82599 (X520), which QEMU did not have: an SR-IOV
#		physical function (-device ixgbe) with an SFP+ direct-
#		attach cable read over bit-banged I2C, its EEPROM,
#		semaphores, link and interrupt registers, 128 queue
#		pairs with offloads, and its virtual functions with
#		the PF/VF mailbox, VF resets and the internal switch
#		between pools (hw/net/ixgbe.c).  scripts/check-qemu-
#		ixgbe.sh checks it against Linux's ixgbe and ixgbevf
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
