#!/bin/sh
# The hypervisor's milestones on the QEMU bench (doc/genesize-plan.ms):
#
#	M1	a freestanding 32-bit guest runs under #H and exits cleanly
#		(os/inferno/pc64/pc64vm, os/inferno/init/vmtestinit.b);
#		in the same boot, and again on AMD-Vi, device release:
#		edu, assigned to a killed machine, is blocked and claimable
#	M2	an unmodified Linux boots to a shell that runs a command
#		typed from Limbo (pc64linux, linuxtestinit.b, vmlinux(1),
#		the guest of scripts/mklinuxguest.sh)
#		and in the same run tests/vm/acguest.c, at the guest's
#		CPL 3 with EFLAGS.AC set, takes its own #AC (SIGBUS)
#	M5	in the same run, the bench's virtio-serial function is
#		assigned to the guest, whose own virtio_console driver
#		writes through it to QEMU's chardev (.qemu/vmhost-hvc.log)
#	M8	in the same run, a file in a Limbo memfs is the guest's
#		virtio disk, served by the kernel's virtio-blk
#		(pc/vmvirtio.c): the guest's virtio_blk reads the marker
#		Limbo wrote and writes a sector Limbo reads back; and a
#		bridge port on the bench's virtio NIC is the guest's
#		virtio-net interface, on which it gets a DHCP lease from
#		QEMU's user network; and the guest makes an ext2 root on a
#		second virtio disk, on which a second guest then boots
#
#	M4	QEMU's edu in an IOMMU domain of its own (pc64dev,
#		pc64devinit.b): DMA through the domain reaches its pages,
#		DMA to a host page it does not map faults; under VT-d
#		(intel-iommu) and AMD-Vi (amd-iommu)
#
#	M3	a Linux guest with four processors (pc64smp,
#		smptestinit.b): all four online, eight busy workers run at
#		once and finish, every processor accounts time and takes
#		IPIs, and nothing in the guest complains
#
# All run on QEMU's TCG.  By default the processor has SVM and not VMX,
# and this checks the SVM backend; with CHECKVM_BACKEND=vmx it is an
# Intel processor with VMX and not SVM -- the patched QEMU implements
# VMX (scripts/qemu-patches/0006) -- and this checks the VMX backend.
# Bochs (scripts/bochs-vm.sh) is a second VMX, too slow for a routine
# check.
#
# usage: scripts/check-vm.sh
#	CHECKVM_STAGES="m1 m2 m4 m3" (the default) says which runs to make:
#	m2 is M2, M5 and M8, one boot.
#	CHECKVM_BACKEND=svm (the default) or vmx.
# needs: os/inferno/pc64/ipc64vm, os/inferno/pc64/ipc64linux, .qemu/edk2-*.fd
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
K=$ROOT/os/inferno/pc64
for k in ipc64vm ipc64linux ipc64smp; do
	[ -f "$K/$k" ] || { echo "check-vm: no $K/$k; mk CONF=${k#i} first" >&2; exit 1; }
done
B=${CHECKVM_BACKEND:-svm}
case $B in
svm)	;;
vmx)	VMHOST_CPU=vmx; export VMHOST_CPU ;;
*)	echo "check-vm: CHECKVM_BACKEND is svm or vmx" >&2; exit 2 ;;
esac
WORK=`mktemp -d`
trap 'st=$?; rm -rf "$WORK" || true; exit $st' 0
fail=0
STAGES=" ${CHECKVM_STAGES:-m1 m2 m4 m3} "
stage() {
	case "$STAGES" in
	*" $1 "*)	return 0;;
	esac
	return 1
}

stage m1 && {
sh "$ROOT/scripts/vmhost.sh" build "$K/ipc64vm" >/dev/null 2>&1
sh "$ROOT/scripts/vmhost.sh" run 120 >"$WORK/m1.log" 2>&1 || true
# the backend the kernel chose ("vm: vmx: no VMX ..." is a refusal)
if tr -d '\r' <"$WORK/m1.log" | grep -q "^vm: $B\$" && grep -q 'VMTEST: M1 PASS' "$WORK/m1.log" \
&& grep -q 'VMTEST: killed' "$WORK/m1.log"; then
	echo "check-vm: M1 ($B): pass"
	grep 'VMTEST: nil' "$WORK/m1.log" | sed 's/^/	/'
else
	echo "check-vm: M1 ($B): FAIL"
	grep 'VMTEST\|panic' "$WORK/m1.log" | sed 's/^/	/' | tail -8
	fail=1
fi
# a Limbo nil dereference is the program's exception (pc64's page 0
# is unmapped, trap.c's disfault), not a read of zeros or a panic
if [ `grep -c 'VMTEST: nil caught .*dereference of nil' "$WORK/m1.log"` -eq 2 ]; then
	echo "check-vm: nil dereference ($B host): pass"
else
	echo "check-vm: nil dereference ($B host): FAIL"
	fail=1
fi
# device release (phase 17): edu, assigned to a machine that is then
# killed, DMAs to a host page; it must be in the blocking domain and
# fault, then be claimable from it.  On VT-d (this boot) and AMD-Vi.
for iommu in intel amd; do
	name=vt-d
	log="$WORK/m1.log"
	if [ $iommu = amd ]; then
		name=amd-vi
		log="$WORK/m1-amd.log"
		VMHOST_IOMMU=amd sh "$ROOT/scripts/vmhost.sh" run 120 >"$log" 2>&1 || true
	fi
	if grep -q 'released: blocked' "$log" && grep -q 'VMTEST: RELEASE-BLOCKED-OK' "$log" \
	&& grep -q 'VMTEST: RELEASE-CLAIMED-OK' "$log" && ! grep -q 'VMTEST: FAIL release' "$log"; then
		echo "check-vm: device release ($name): pass"
		grep 'released: \|VMTEST: release\|VMTEST: RELEASE' "$log" | sed 's/^/	/'
	else
		echo "check-vm: device release ($name): FAIL"
		grep 'released\|VMTEST: \(release\|RELEASE\|FAIL\)\|panic' "$log" | sed 's/^/	/' | tail -8
		fail=1
	fi
done
}

stage m2 && {
sh "$ROOT/scripts/vmhost.sh" build "$K/ipc64linux" >/dev/null 2>&1
sh "$ROOT/scripts/vmhost.sh" run 1200 >"$WORK/m2.log" 2>&1 || true
if grep -q '^Linux 6' "$WORK/m2.log" && grep -q '^LINUXGUEST: ran' "$WORK/m2.log"; then
	echo "check-vm: M2 ($B): pass"
	grep 'LINUXGUEST: up\|platform handled' "$WORK/m2.log" | sed 's/^/	/'
else
	echo "check-vm: M2 ($B): FAIL"
	grep 'LINUXGUEST\|LINUXTEST\|vmlinux:\|panic' "$WORK/m2.log" | sed 's/^/	/' | tail -10
	fail=1
fi
# #AC at the guest's CPL 3 (tests/vm/acguest.c): the backend leaves
# it to the guest, whose Linux sends SIGBUS (status 135)
if grep -q '^ACGUEST: aligned store with EFLAGS.AC set' "$WORK/m2.log" \
&& grep -q '^LINUXGUEST: acguest status 135' "$WORK/m2.log"; then
	echo "check-vm: #AC in the guest ($B): pass"
	grep '^ACGUEST\|acguest status' "$WORK/m2.log" | sed 's/^/	/'
else
	echo "check-vm: #AC in the guest ($B): FAIL"
	grep 'ACGUEST\|acguest' "$WORK/m2.log" | sed 's/^/	/' | tail -4
	fail=1
fi
if grep -q 'hello-from-the-guest' "$ROOT/.qemu/vmhost-hvc.log" 2>/dev/null; then
	echo "check-vm: M5 ($B): pass"
	grep '^pci 00\|PCI-MSIX' "$WORK/m2.log" | sort -u | sed 's/^/	/'
else
	echo "check-vm: M5 ($B): FAIL -- the guest's virtio console output did not reach QEMU"
	grep '^pci 00\|PCI-MSIX\|virtio' "$WORK/m2.log" | sort -u | sed 's/^/	/' | tail -8
	fail=1
fi
# the function M5 assigned, released when its machine ended (blocked,
# reset by FLR, its configuration put back) and assigned again to the
# boot on the virtio disk, whose console it carries
if grep -q 'PCI.5.0.0: released: blocked, reset by FLR' "$WORK/m2.log" \
&& grep -q 'hello-after-release' "$ROOT/.qemu/vmhost-hvc.log" 2>/dev/null; then
	echo "check-vm: device release and reuse ($B): pass"
	grep -a -o 'vm[0-9]*.PCI.5.0.0: released: [^\r]*' "$WORK/m2.log" | sed 's/^/	/'
else
	echo "check-vm: device release and reuse ($B): FAIL"
	grep -a -o 'vm[0-9]*.PCI.5.0.0: released: [^\r]*\|LINUXGUEST: wrote hvc0.*' "$WORK/m2.log" | sed 's/^/	/'
	fail=1
fi
if grep -q '^LINUXGUEST: disk vda 2048 sectors' "$WORK/m2.log" \
&& grep -q '^LINUXGUEST: vda says INFERNO-VIRTIO-DISK' "$WORK/m2.log" \
&& grep -q 'LINUXTEST: disk sector 1: guest-wrote-this' "$WORK/m2.log"; then	# Limbo's line can land mid-line, among vmlinux's
	echo "check-vm: M8 disk ($B): pass"
	grep 'virtio blk\|vda' "$WORK/m2.log" | grep -v 'echo\|then' | sort -u | sed 's/^/	/'
else
	echo "check-vm: M8 disk ($B): FAIL"
	grep 'virtio\|vda\|LINUXTEST: disk' "$WORK/m2.log" | sort -u | sed 's/^/	/' | tail -8
	fail=1
fi
if grep -q '^LINUXGUEST: dhcp udhcpc: lease of' "$WORK/m2.log" \
&& grep -q '^LINUXGUEST: eth0 rx [0-9]* packets 0 length errors' "$WORK/m2.log"; then
	echo "check-vm: M8 net ($B): pass"
	grep '^LINUXGUEST: dhcp\|^LINUXGUEST: eth0\|virtio net' "$WORK/m2.log" | sort -u | sed 's/^/	/'
else
	echo "check-vm: M8 net ($B): FAIL"
	grep 'LINUXGUEST: dhcp\|LINUXGUEST: eth0\|LINUXGUEST: net\|virtio net' "$WORK/m2.log" | sort -u | sed 's/^/	/' | tail -8
	fail=1
fi
if grep -q '^LINUXGUEST: made a root on vdb' "$WORK/m2.log" \
&& grep -q '^LINUXGUEST: root /dev/vda ext2' "$WORK/m2.log" \
&& grep -q '^LINUXGUEST: on disk' "$WORK/m2.log"; then
	echo "check-vm: M8 boot on the virtio disk ($B): pass"
	grep '^LINUXGUEST: made a root\|^LINUXGUEST: root\|^LINUXGUEST: mount\|^LINUXGUEST: on disk' "$WORK/m2.log" | sed 's/^/	/'
else
	echo "check-vm: M8 boot on the virtio disk ($B): FAIL"
	grep 'LINUXGUEST: made\|LINUXGUEST: root\|LINUXGUEST: no root\|LINUXGUEST: insmod\|LINUXTEST: booting\|LINUXGUEST: mount' "$WORK/m2.log" | sed 's/^/	/' | tail -8
	fail=1
fi
}

# M4: pc64dev's test (pc64devinit.b) puts QEMU's edu in an IOMMU domain
# of its own: a DMA through it reaches its pages, one to a host page the
# domain does not map faults and leaves that page untouched.  Under
# VT-d (intel-iommu) and AMD-Vi (amd-iommu).
stage m4 && {
sh "$ROOT/scripts/vmhost.sh" build "$K/ipc64dev" >/dev/null 2>&1
for iommu in intel amd; do
	VMHOST_IOMMU=$iommu sh "$ROOT/scripts/vmhost.sh" run 200 >"$WORK/m4-$iommu.log" 2>&1 || true
	name=vt-d
	[ $iommu = amd ] && name=amd-vi
	if grep -q 'IOMMU-DMA-MAPPED-OK' "$WORK/m4-$iommu.log" && grep -q 'IOMMU-DMA-BLOCKED-OK' "$WORK/m4-$iommu.log" \
	&& ! grep -q 'IOMMU-FAIL' "$WORK/m4-$iommu.log"; then
		echo "check-vm: M4 ($name): pass"
		grep 'iommu: \|DEVTEST: IOMMU-DMA\|^0 0' "$WORK/m4-$iommu.log" | sed 's/^/	/'
	else
		echo "check-vm: M4 ($name): FAIL"
		grep 'iommu\|amdvi\|vtd\|DEVTEST\|panic' "$WORK/m4-$iommu.log" | sed 's/^/	/' | tail -10
		fail=1
	fi
done
}

# A QEMU thread for each host processor (MTTCG), as the other stages:
# the host's triple faults there were QEMU's IGNNE# emulation
# rewriting the first processor's flags from another's thread
# (scripts/qemu-patches/0004, doc/genesize-plan.ms, phase 5).
stage m3 && {
sh "$ROOT/scripts/vmhost.sh" build "$K/ipc64smp" >/dev/null 2>&1
sh "$ROOT/scripts/vmhost.sh" run 2400 >"$WORK/m3.log" 2>&1 || true
ok=1
grep -q '^LINUXGUEST: smp 4 processors, online 0-3' "$WORK/m3.log" || ok=0
[ `grep -c '^LINUXGUEST: worker [1-8] done' "$WORK/m3.log"` -eq 8 ] || ok=0
for c in 0 1 2 3; do
	# user and system time of /proc/stat's cpuN line
	grep "^LINUXGUEST: cpu$c " "$WORK/m3.log" | awk '{ if ($3 + $5 > 0) found = 1 } END { exit !found }' || ok=0
done
# rescheduling or function-call IPIs taken on more than one processor
grep '^LINUXGUEST: irq *\(RES\|CAL\):' "$WORK/m3.log" | awk '{ n = 0; for (i = 4; i <= 7; i++) if ($i > 0) n++; if (n > 1) found = 1 } END { exit !found }' || ok=0
grep -q '^LINUXGUEST: ran' "$WORK/m3.log" || ok=0
grep -q 'BUG\|soft lockup\|rcu.*stall\|vcpu[0-9] exit' "$WORK/m3.log" && ok=0
if [ $ok = 1 ]; then
	echo "check-vm: M3 ($B): pass"
	grep '^LINUXGUEST: smp\|^LINUXGUEST: cpu\|^LINUXGUEST: irq\|platform ipis' "$WORK/m3.log" | sed 's/^/	/'
else
	echo "check-vm: M3 ($B): FAIL"
	grep 'LINUXGUEST: smp\|LINUXGUEST: worker\|LINUXGUEST: cpu\|LINUXGUEST: irq\|BUG\|lockup\|stall\|vcpu[0-9] exit\|Brought up' "$WORK/m3.log" | sed 's/^/	/' | tail -20
	fail=1
fi
}
exit $fail
