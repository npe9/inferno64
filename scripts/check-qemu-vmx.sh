#!/bin/sh
# Check the patched QEMU's VMX (scripts/qemu-patches/0006) against
# clients that are not this kernel, before trusting it with
# os/inferno/pc64/vmx.c (doc/genesize-plan.ms, phase 16):
#
#	kvm-unit-tests	the VMX tests (x86/vmx.flat), at a pinned commit:
#			the [vmx] and [ept] groups of its unittests.cfg,
#			and the two-processor INIT and APIC tests
#	kvm_intel	Linux's own VMX hypervisor: the bench's guest
#			kernel (.guest/vmlinuz-virt, scripts/mklinuxguest.sh)
#			boots on QEMU with VMX, loads kvm_intel from its
#			package, and tests/vm/kvmtest.c runs a real-mode
#			guest through /dev/kvm (unrestricted guest, EPT)
#
#	actest		#AC itself, outside any guest (tests/vm/kut-actest.c,
#			built in kvm-unit-tests' tree): what patch 0010
#			gives TCG -- a misaligned 2, 4 or 8 byte access at
#			CPL 3 with CR0.AM and EFLAGS.AC set raises #AC, an
#			aligned one and an unaligned MOVUPS do not, nor does
#			anything with EFLAGS.AC clear
#
# One of kvm-unit-tests' checks is left out, for QEMU's TCG rather than
# its VMX: rdtsc_vmexit_diff_test (its bound is in TSC ticks, and
# TCG's TSC is the host clock, here at a microsecond).
#
# usage: scripts/check-qemu-vmx.sh
# needs: x86_64-elf-gcc, gmake, git; .qemu/local (scripts/mkqemu.sh)
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
Q=$ROOT/.qemu/local/bin/qemu-system-x86_64
KUT=$ROOT/.qemu/src/kvm-unit-tests
KUTREV=5a221342a025948fa7d84f0c404748f6ba57f3ad
CPU=max,+vmx,-svm,vendor=GenuineIntel
[ -x "$Q" ] || { echo "check-qemu-vmx: no $Q; scripts/mkqemu.sh first" >&2; exit 1; }
WORK=`mktemp -d`
trap 'st=$?; rm -rf "$WORK" || true; exit $st' 0
fail=0

# kvm-unit-tests, built for x86_64 with the cross compiler
if [ ! -d "$KUT/.git" ]; then
	git init -q "$KUT"
	git -C "$KUT" fetch -q --depth 1 https://gitlab.com/kvm-unit-tests/kvm-unit-tests.git $KUTREV
	git -C "$KUT" checkout -q FETCH_HEAD
fi
[ "`git -C "$KUT" rev-parse HEAD`" = $KUTREV ] || {
	echo "check-qemu-vmx: $KUT is not at $KUTREV" >&2; exit 1; }
(
	cd "$KUT"
	[ -f config.mak ] || ./configure --arch=x86_64 --cross-prefix=x86_64-elf- >/dev/null
	gmake x86/vmx.flat >/dev/null
	cp "$ROOT/tests/vm/kut-actest.c" x86/actest.c
	gmake x86/actest.flat >/dev/null
)

# kut name flat smp mem args: one run of vmx.flat; it passes when no
# check failed and it ran to its summary.  An XPASS, which the summary
# counts as unexpected, is a check marked as failing on KVM that the
# emulated processor passes (vmx_db_test's MOV SS shadow).
kut() {
	name=$1 flat=$2 smp=$3 mem=$4
	shift 4
	timeout 3600 "$Q" -nodefaults -device pc-testdev \
		-device isa-debug-exit,iobase=0xf4,iosize=0x4 -display none \
		-serial stdio -device pci-testdev -machine accel=tcg \
		-m $mem -smp $smp -cpu $CPU -kernel $flat -append "$*" \
		>"$WORK/$name.log" 2>&1 || true
	sum=`grep '^SUMMARY:' "$WORK/$name.log" | tail -1`
	if [ -n "$sum" ] && ! grep -q '^FAIL\|Unhandled' "$WORK/$name.log"; then
		echo "check-qemu-vmx: kvm-unit-tests $name: pass"
		echo "	$sum"
		grep '^XPASS' "$WORK/$name.log" | sed 's/^/	/'
	else
		echo "check-qemu-vmx: kvm-unit-tests $name: FAIL"
		grep '^FAIL\|Unhandled\|SUMMARY' "$WORK/$name.log" | sed 's/^/	/' | tail -12
		fail=1
	fi
}
# unittests.cfg's [vmx] list, and rdtsc_vmexit_diff_test
kut actest "$KUT/x86/actest.flat" 1 512 ""
kut vmx "$KUT/x86/vmx.flat" 1 512 "-exit_monitor_from_l2_test -ept_access* -vmx_smp* -vmx_vmcs_shadow_test -atomic_switch_overflow_msrs_test -vmx_init_signal_test -vmx_apic_passthrough_tpr_threshold_test -apic_reg_virt_test -virt_x2apic_mode_test -vmx_pf_exception_test -vmx_pf_exception_forced_emulation_test -vmx_pf_no_vpid_test -vmx_pf_invvpid_test -vmx_pf_vpid_test -vmx_basic_vid_test -vmx_eoi_virt_test -vmx_posted_interrupts_test -rdtsc_vmexit_diff_test"
kut ept "$KUT/x86/vmx.flat" 1 2560 "ept_access*"
kut init_signal "$KUT/x86/vmx.flat" 2 2048 vmx_init_signal_test
kut apic_passthrough_thread "$KUT/x86/vmx.flat" 2 2048 vmx_apic_passthrough_thread_test

# Linux's kvm_intel, with tests/vm/kvmtest.c as its user
x86_64-elf-gcc -static -nostdlib -ffreestanding -mgeneral-regs-only -fno-pic \
	-no-pie -O2 -o "$WORK/kvmtest" "$ROOT/tests/vm/kvmtest.c"
python3 - "$ROOT/.guest" "$WORK/kvmtest" "$WORK/kvmtest.cpio" <<'EOF'
import sys, tarfile, gzip, stat, io
G, kvmtest, out = sys.argv[1], sys.argv[2], sys.argv[3]
pkg = tarfile.open(G + '/linux-virt-6.6.142-r0.apk', 'r:gz')
base = 'lib/modules/6.6.142-0-virt/kernel/'
mods = [('irqbypass', 'virt/lib/irqbypass.ko.gz'), ('kvm', 'arch/x86/kvm/kvm.ko.gz'),
	('kvm-intel', 'arch/x86/kvm/kvm-intel.ko.gz')]
init = b'''#!/bin/busybox sh
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sys /sys
/bin/busybox mount -t devtmpfs dev /dev
for m in irqbypass kvm kvm-intel; do
	/bin/busybox insmod /lib/$m.ko || echo "KVMTEST: insmod $m failed"
done
/bin/busybox lsmod | /bin/busybox sed "s/^/KVMTEST: lsmod /"
/kvmtest
/bin/busybox poweroff -f
'''
ents = [('bin', stat.S_IFDIR | 0o755, b''), ('dev', stat.S_IFDIR | 0o755, b''),
	('proc', stat.S_IFDIR | 0o755, b''), ('sys', stat.S_IFDIR | 0o755, b''),
	('lib', stat.S_IFDIR | 0o755, b''),
	('bin/busybox', stat.S_IFREG | 0o755, open(G + '/busybox', 'rb').read()),
	('init', stat.S_IFREG | 0o755, init),
	('kvmtest', stat.S_IFREG | 0o755, open(kvmtest, 'rb').read())]
for name, rel in mods:
	ents.append(('lib/%s.ko' % name, stat.S_IFREG | 0o644,
		gzip.decompress(pkg.extractfile(base + rel).read())))
o = io.BytesIO()
def rec(ino, name, mode, data):
	name = name.encode() + b'\0'
	h = b'070701' + b''.join(b'%08x' % v for v in
		(ino, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(name), 0))
	o.write(h + name)
	o.write(b'\0' * ((4 - (len(h) + len(name)) % 4) % 4))
	o.write(data)
	o.write(b'\0' * ((4 - len(data) % 4) % 4))
for i, (n, m, d) in enumerate(ents):
	rec(i + 1, n, m, d)
rec(0, 'TRAILER!!!', 0, b'')
open(out, 'wb').write(o.getvalue())
EOF
timeout 900 "$Q" -machine q35 -accel tcg -cpu $CPU -m 512 -display none \
	-serial stdio -kernel "$ROOT/.guest/vmlinuz-virt" -initrd "$WORK/kvmtest.cpio" \
	-append "console=ttyS0 quiet" -no-reboot >"$WORK/kvmtest.log" 2>&1 || true
if tr -d '\r' <"$WORK/kvmtest.log" | grep -q '^KVMTEST: PASS'; then
	echo "check-qemu-vmx: kvm_intel: pass"
else
	echo "check-qemu-vmx: kvm_intel: FAIL"
	fail=1
fi
tr -d '\r' <"$WORK/kvmtest.log" | grep 'KVMTEST: \(lsmod kvm\|guest\|FAIL\|insmod\)' | sed 's/^/	/'
exit $fail
