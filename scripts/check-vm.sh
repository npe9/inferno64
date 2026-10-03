#!/bin/sh
# The hypervisor's milestones on the QEMU bench (doc/genesize-plan.ms):
#
#	M1	a freestanding 32-bit guest runs under #H and exits cleanly
#		(os/inferno/pc64/pc64vm, os/inferno/init/vmtestinit.b)
#	M2	an unmodified Linux boots to a shell that runs a command
#		typed from Limbo (pc64linux, linuxtestinit.b, vmlinux(1),
#		the guest of scripts/mklinuxguest.sh)
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
#	M3	a Linux guest with four processors (pc64smp,
#		smptestinit.b): all four online, eight busy workers run at
#		once and finish, every processor accounts time and takes
#		IPIs, and nothing in the guest complains
#
# All run on QEMU's TCG, which emulates SVM and not VMX, so this
# checks the SVM backend; the VMX backend is checked on Bochs
# (scripts/bochs-vm.sh), which is too slow for a routine check.
#
# usage: scripts/check-vm.sh
# needs: os/inferno/pc64/ipc64vm, os/inferno/pc64/ipc64linux, .qemu/edk2-*.fd
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
K=$ROOT/os/inferno/pc64
for k in ipc64vm ipc64linux ipc64smp; do
	[ -f "$K/$k" ] || { echo "check-vm: no $K/$k; mk CONF=${k#i} first" >&2; exit 1; }
done
WORK=`mktemp -d`
trap 'st=$?; rm -rf "$WORK" || true; exit $st' 0
fail=0

sh "$ROOT/scripts/vmhost.sh" build "$K/ipc64vm" >/dev/null 2>&1
sh "$ROOT/scripts/vmhost.sh" run 120 >"$WORK/m1.log" 2>&1 || true
if grep -q 'VMTEST: M1 PASS' "$WORK/m1.log" && grep -q 'VMTEST: killed' "$WORK/m1.log"; then
	echo "check-vm: M1 (svm): pass"
else
	echo "check-vm: M1 (svm): FAIL"
	grep 'VMTEST\|panic' "$WORK/m1.log" | sed 's/^/	/' | tail -8
	fail=1
fi

sh "$ROOT/scripts/vmhost.sh" build "$K/ipc64linux" >/dev/null 2>&1
sh "$ROOT/scripts/vmhost.sh" run 1200 >"$WORK/m2.log" 2>&1 || true
if grep -q '^Linux 6' "$WORK/m2.log" && grep -q '^LINUXGUEST: ran' "$WORK/m2.log"; then
	echo "check-vm: M2 (svm): pass"
	grep 'LINUXGUEST: up\|platform handled' "$WORK/m2.log" | sed 's/^/	/'
else
	echo "check-vm: M2 (svm): FAIL"
	grep 'LINUXGUEST\|LINUXTEST\|vmlinux:\|panic' "$WORK/m2.log" | sed 's/^/	/' | tail -10
	fail=1
fi
if grep -q 'hello-from-the-guest' "$ROOT/.qemu/vmhost-hvc.log" 2>/dev/null; then
	echo "check-vm: M5 (svm): pass"
	grep '^pci 00\|PCI-MSIX' "$WORK/m2.log" | sort -u | sed 's/^/	/'
else
	echo "check-vm: M5 (svm): FAIL -- the guest's virtio console output did not reach QEMU"
	grep '^pci 00\|PCI-MSIX\|virtio' "$WORK/m2.log" | sort -u | sed 's/^/	/' | tail -8
	fail=1
fi
if grep -q '^LINUXGUEST: disk vda 2048 sectors' "$WORK/m2.log" \
&& grep -q '^LINUXGUEST: vda says INFERNO-VIRTIO-DISK' "$WORK/m2.log" \
&& grep -q 'LINUXTEST: disk sector 1: guest-wrote-this' "$WORK/m2.log"; then	# Limbo's line can land mid-line, among vmlinux's
	echo "check-vm: M8 disk (svm): pass"
	grep 'virtio blk\|vda' "$WORK/m2.log" | grep -v 'echo\|then' | sort -u | sed 's/^/	/'
else
	echo "check-vm: M8 disk (svm): FAIL"
	grep 'virtio\|vda\|LINUXTEST: disk' "$WORK/m2.log" | sort -u | sed 's/^/	/' | tail -8
	fail=1
fi
if grep -q '^LINUXGUEST: dhcp udhcpc: lease of' "$WORK/m2.log" \
&& grep -q '^LINUXGUEST: eth0 rx [0-9]* packets 0 length errors' "$WORK/m2.log"; then
	echo "check-vm: M8 net (svm): pass"
	grep '^LINUXGUEST: dhcp\|^LINUXGUEST: eth0\|virtio net' "$WORK/m2.log" | sort -u | sed 's/^/	/'
else
	echo "check-vm: M8 net (svm): FAIL"
	grep 'LINUXGUEST: dhcp\|LINUXGUEST: eth0\|LINUXGUEST: net\|virtio net' "$WORK/m2.log" | sort -u | sed 's/^/	/' | tail -8
	fail=1
fi
if grep -q '^LINUXGUEST: made a root on vdb' "$WORK/m2.log" \
&& grep -q '^LINUXGUEST: root /dev/vda ext2' "$WORK/m2.log" \
&& grep -q '^LINUXGUEST: on disk' "$WORK/m2.log"; then
	echo "check-vm: M8 boot on the virtio disk (svm): pass"
	grep '^LINUXGUEST: made a root\|^LINUXGUEST: root\|^LINUXGUEST: mount\|^LINUXGUEST: on disk' "$WORK/m2.log" | sed 's/^/	/'
else
	echo "check-vm: M8 boot on the virtio disk (svm): FAIL"
	grep 'LINUXGUEST: made\|LINUXGUEST: root\|LINUXGUEST: no root\|LINUXGUEST: insmod\|LINUXTEST: booting\|LINUXGUEST: mount' "$WORK/m2.log" | sed 's/^/	/' | tail -8
	fail=1
fi
# One QEMU thread for the four host processors: with a thread each
# (MTTCG) the host has triple-faulted right after a VMRUN with the
# guest's TR and GS still loaded, which one thread has not shown
# (doc/genesize-plan.ms, phase 5).
sh "$ROOT/scripts/vmhost.sh" build "$K/ipc64smp" >/dev/null 2>&1
VMHOST_ACCEL=tcg,thread=single sh "$ROOT/scripts/vmhost.sh" run 2400 >"$WORK/m3.log" 2>&1 || true
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
	echo "check-vm: M3 (svm): pass"
	grep '^LINUXGUEST: smp\|^LINUXGUEST: cpu\|^LINUXGUEST: irq\|platform ipis' "$WORK/m3.log" | sed 's/^/	/'
else
	echo "check-vm: M3 (svm): FAIL"
	grep 'LINUXGUEST: smp\|LINUXGUEST: worker\|LINUXGUEST: cpu\|LINUXGUEST: irq\|BUG\|lockup\|stall\|vcpu[0-9] exit\|Brought up' "$WORK/m3.log" | sed 's/^/	/' | tail -20
	fail=1
fi
exit $fail
