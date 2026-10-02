#!/bin/sh
# The reference hypervisor host: the machine the Inferno hypervisor is
# developed against before it meets the workstation (doc/genesize-plan.ms,
# phase 0 and section 4).
#
#	q35, x86-64, four processors, 2 GB
#	Intel IOMMU (VT-d) with interrupt remapping
#	PCIe root ports, each device behind its own
#	igb (Intel 82576) -- MSI-X, and the SR-IOV capability with VFs
#	NVMe -- MSI-X, a DMA-capable device
#	edu -- QEMU's teaching device: a DMA engine driven through BAR0,
#		which is what the IOMMU tests aim at addresses; its DMA mask
#		is widened from 28 bits to 48, as a real engine's would be
#	virtio-net (1.0) -- the host's own network, as cloud-port boots it
#	serial console, edk2 firmware, the tree's UEFI loader
#
# The kernel boots from the same UEFI ISO the cloud images use
# (scripts/mkinferno-efi-iso.sh).
#
# usage: scripts/vmhost.sh build [kernel]     make .qemu/vmhost.iso
#        scripts/vmhost.sh run [seconds] [extra qemu args]
#        scripts/vmhost.sh debug [extra qemu args]
#
# run with seconds captures the serial console to .qemu/vmhost.log and
# prints it; run without seconds is interactive on stdio.  debug starts
# the machine stopped with a gdb stub on tcp::1234 ("target remote
# :1234"), console on stdio.
#
# VMHOST_IOMMU=0 and VMHOST_IGB=0 leave the IOMMU or the igb out, to
# tell a fault in either from one in the rest of the machine.
#
# VMHOST_ACCEL=tcg (default) or kvm.  Under TCG the processor is "max",
# which has SVM with nested paging and no VMX: TCG does not implement
# VMX.  Under KVM on an Intel host with nested virtualization it is
# "host", which has VMX; the emulated IOMMU then needs the interrupt
# controller split between the kernel and QEMU.
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
Q=$ROOT/.qemu
ISO=$Q/vmhost.iso
LOG=$Q/vmhost.log
NVME=$Q/vmhost-nvme.raw
ACCEL=${VMHOST_ACCEL:-tcg}
# the patched QEMU from scripts/mkqemu.sh when it has been built; its
# igb behaves as the 82576 does, upstream's does not
QEMU=qemu-system-x86_64
[ -x "$Q/local/bin/qemu-system-x86_64" ] && QEMU=$Q/local/bin/qemu-system-x86_64

cmd=${1:-run}
[ $# -gt 0 ] && shift

case $cmd in
build)
	KERN=${1:-$ROOT/os/inferno/pc64/ipc64dev}
	[ -f "$KERN" ] || { echo "vmhost: no kernel $KERN" >&2; exit 1; }
	INFERNO_KERNEL=$KERN sh "$ROOT/scripts/mkinferno-efi-iso.sh" "$ISO"
	exit 0
	;;
run|debug)
	;;
*)
	echo "usage: vmhost.sh build [kernel] | run [seconds] [qemu args] | debug [qemu args]" >&2
	exit 2
	;;
esac

[ -f "$ISO" ] || { echo "vmhost: no $ISO; vmhost.sh build first" >&2; exit 1; }
for f in edk2-code.fd edk2-vars.fd; do
	[ -f "$Q/$f" ] || { echo "vmhost: no $Q/$f (see scripts/qemu-inferno-efi.sh)" >&2; exit 1; }
done
[ -f "$NVME" ] || dd if=/dev/zero of="$NVME" bs=1m count=64 2>/dev/null
cp "$Q/edk2-vars.fd" "$Q/edk2-vars-vmhost.fd"

case $ACCEL in
tcg)	MACHINE=q35; CPU=max ;;
kvm)	MACHINE=q35,kernel-irqchip=split; CPU=host ;;
*)	echo "vmhost: VMHOST_ACCEL is tcg or kvm" >&2; exit 2 ;;
esac

secs=
if [ $cmd = run ] && [ $# -gt 0 ]; then
	case $1 in
	[0-9]*)	secs=$1; shift ;;
	esac
fi

IOMMU="-device intel-iommu,intremap=on"
[ "${VMHOST_IOMMU:-1}" = 0 ] && IOMMU=
IGB="-netdev user,id=net1 -device igb,netdev=net1,bus=rp2"
[ "${VMHOST_IGB:-1}" = 0 ] && IGB=

# The IOMMU comes first: QEMU wants it created before the devices whose
# DMA it is to translate.
set -- \
	-machine $MACHINE -accel $ACCEL -cpu $CPU -smp 4 -m 2048 \
	-drive if=pflash,format=raw,unit=0,readonly=on,file="$Q/edk2-code.fd" \
	-drive if=pflash,format=raw,unit=1,file="$Q/edk2-vars-vmhost.fd" \
	$IOMMU \
	-device pcie-root-port,id=rp1,chassis=1,slot=1 \
	-device pcie-root-port,id=rp2,chassis=2,slot=2 \
	-device pcie-root-port,id=rp3,chassis=3,slot=3 \
	-device pcie-root-port,id=rp4,chassis=4,slot=4 \
	-netdev user,id=net0 \
	-device virtio-net-pci,netdev=net0,bus=rp1,disable-legacy=on \
	$IGB \
	-drive if=none,id=nvm0,format=raw,file="$NVME" \
	-device nvme,drive=nvm0,serial=vmhost0,bus=rp3 \
	-device edu,bus=rp4,dma_mask=0xffffffffffff \
	-cdrom "$ISO" \
	-display none -no-reboot \
	"$@"

if [ $cmd = debug ]; then
	exec $QEMU "$@" -serial mon:stdio -S -gdb tcp::1234
fi
if [ -z "$secs" ]; then
	exec $QEMU "$@" -serial mon:stdio
fi
rm -f "$LOG"
timeout "$secs" $QEMU "$@" -serial "file:$LOG" >"$Q/vmhost-qemu.err" 2>&1 || true
sed -e 's/\x1b\[[0-9;=]*[a-zA-Z]//g' -e 's/\r$//' "$LOG"
[ -s "$Q/vmhost-qemu.err" ] && sed 's/^/qemu: /' "$Q/vmhost-qemu.err" >&2
exit 0
