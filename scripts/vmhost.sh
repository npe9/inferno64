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
#	virtio-serial (1.0, modern only) with one console port written to
#		.qemu/vmhost-hvc.log -- the function assigned to a Linux
#		guest in the phase 6 test; Inferno has no driver for it.
#		iommu_platform=on is not optional: without it QEMU's virtio
#		devices bypass the emulated IOMMU altogether -- an emulator
#		convenience no real device has -- and an assigned one DMAs to
#		the host's memory at the guest's addresses
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
# VMHOST_FWD=port forwards that host port to the guest's 5640, where
# os/inferno/init/vmserveinit.b exports the hypervisor over Styx.  The
# forward is on the igb's network: it is ether0, the interface a DHCP
# loop tries first.
#
# VMHOST_IOMMU=amd puts QEMU's amd-iommu (AMD-Vi) where VT-d would be.
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
# VMHOST_TAG runs another instance beside the first: its own serial
# log, firmware variables, NVMe image and console file (the ISO is read
# only and shared).  VMHOST_MEM and VMHOST_SMP size it.
T=${VMHOST_TAG:+-$VMHOST_TAG}
ISO=${VMHOST_ISO:-$Q/vmhost.iso}	# VMHOST_ISO: an image of its own, for a run beside another
LOG=$Q/vmhost$T.log
NVME=$Q/vmhost$T-nvme.raw
HVC=$Q/vmhost$T-hvc.log
VARS=$Q/edk2-vars-vmhost$T.fd
ACCEL=${VMHOST_ACCEL:-tcg}
# the patched QEMU from scripts/mkqemu.sh when it has been built; its
# igb behaves as the 82576 does, upstream's does not
QEMU=qemu-system-x86_64
[ -x "$Q/local/bin/qemu-system-x86_64" ] && QEMU=$Q/local/bin/qemu-system-x86_64
# VMHOST_QEMU: another QEMU binary, an instrumented build say
[ -n "$VMHOST_QEMU" ] && QEMU=$VMHOST_QEMU

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
cp "$Q/edk2-vars.fd" "$VARS"

case $ACCEL in
tcg|tcg,*)	MACHINE=q35; CPU=max ;;	# tcg,thread=single: one host thread for every vCPU
kvm)	MACHINE=q35,kernel-irqchip=split; CPU=host ;;
*)	echo "vmhost: VMHOST_ACCEL is tcg[,options] or kvm" >&2; exit 2 ;;
esac

secs=
if [ $cmd = run ] && [ $# -gt 0 ]; then
	case $1 in
	[0-9]*)	secs=$1; shift ;;
	esac
fi

FWD=
[ -n "$VMHOST_FWD" ] && FWD=",hostfwd=tcp:127.0.0.1:$VMHOST_FWD-:5640"
IOMMU="-device intel-iommu,intremap=on"
[ "${VMHOST_IOMMU:-1}" = 0 ] && IOMMU=
# VMHOST_IOMMU=amd: AMD-Vi (QEMU's amd-iommu) in place of VT-d
[ "$VMHOST_IOMMU" = amd ] && IOMMU="-device amd-iommu"
# VMHOST_NIC1=e1000: that model (an 82540EM, as Bochs has) in place of the igb
IGB="-netdev user,id=net1$FWD -device ${VMHOST_NIC1:-igb},netdev=net1,bus=rp2"
[ "${VMHOST_IGB:-1}" = 0 ] && IGB=

NOREBOOT=-no-reboot
[ "$VMHOST_REBOOT" = 1 ] && NOREBOOT=
# The IOMMU comes first: QEMU wants it created before the devices whose
# DMA it is to translate.
set -- \
	-machine $MACHINE -accel $ACCEL -cpu $CPU -smp ${VMHOST_SMP:-4} -m ${VMHOST_MEM:-2048} \
	-drive if=pflash,format=raw,unit=0,readonly=on,file="$Q/edk2-code.fd" \
	-drive if=pflash,format=raw,unit=1,file="$VARS" \
	$IOMMU \
	-device pcie-root-port,id=rp1,chassis=1,slot=1 \
	-device pcie-root-port,id=rp2,chassis=2,slot=2 \
	-device pcie-root-port,id=rp3,chassis=3,slot=3 \
	-device pcie-root-port,id=rp4,chassis=4,slot=4 \
	-device pcie-root-port,id=rp5,chassis=5,slot=5 \
	-netdev user,id=net0 \
	-device virtio-net-pci,netdev=net0,bus=rp1,disable-legacy=on \
	$IGB \
	-drive if=none,id=nvm0,format=raw,file="$NVME" \
	-device nvme,drive=nvm0,serial=vmhost0,bus=rp3 \
	-device edu,bus=rp4,dma_mask=0xffffffffffff \
	-device virtio-serial-pci,bus=rp5,disable-legacy=on,iommu_platform=on \
	-chardev file,id=hvc0,path="$HVC" \
	-device virtconsole,chardev=hvc0 \
	-cdrom "$ISO" \
	-display none $NOREBOOT \
	"$@"
# VMHOST_REBOOT=1: a reset reboots, rather than ending QEMU, so that with
# VMHOST_D=cpu_reset the log has every processor's state at a triple fault
# VMHOST_MON: a QEMU monitor on that TCP port of localhost, for a run
[ -n "$VMHOST_MON" ] && set -- "$@" -monitor "tcp:127.0.0.1:$VMHOST_MON,server,nowait"
# VMHOST_D: QEMU's -d log items (cpu_reset, guest_errors, ...), in .qemu/vmhost-d.log
[ -n "$VMHOST_D" ] && set -- "$@" -d "$VMHOST_D" -D "$Q/vmhost$T-d.log"

if [ $cmd = debug ]; then
	exec $QEMU "$@" -serial mon:stdio -S -gdb tcp::1234
fi
if [ -z "$secs" ]; then
	exec $QEMU "$@" -serial mon:stdio
fi
rm -f "$LOG" "$HVC"
# QEMU's exit status, if not 0 or timeout's 124, goes with its output:
# a QEMU killed by a signal otherwise leaves nothing behind
timeout "$secs" $QEMU "$@" -serial "file:$LOG" >"$Q/vmhost$T-qemu.err" 2>&1 || {
	st=$?
	[ $st = 124 ] || echo "qemu-system-x86_64 exit status $st at `date +%T`" >>"$Q/vmhost$T-qemu.err"
}
sed -e 's/\x1b\[[0-9;=]*[a-zA-Z]//g' -e 's/\r$//' "$LOG"
[ -s "$Q/vmhost$T-qemu.err" ] && sed 's/^/qemu: /' "$Q/vmhost$T-qemu.err" >&2
exit 0
