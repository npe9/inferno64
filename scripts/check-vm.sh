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
#
# Both run on QEMU's TCG, which emulates SVM and not VMX, so this
# checks the SVM backend; the VMX backend is checked on Bochs
# (scripts/bochs-vm.sh), which is too slow for a routine check.
#
# usage: scripts/check-vm.sh
# needs: os/inferno/pc64/ipc64vm, os/inferno/pc64/ipc64linux, .qemu/edk2-*.fd
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
K=$ROOT/os/inferno/pc64
for k in ipc64vm ipc64linux; do
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
sh "$ROOT/scripts/vmhost.sh" run 600 >"$WORK/m2.log" 2>&1 || true
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
exit $fail
