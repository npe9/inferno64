#!/bin/sh
# M12 of doc/genesize-plan.ms, the RISC-V H-extension backend, on
# QEMU's TCG (qemu-system-riscv64 -M virt, whose rv64 has the H
# extension): os/inferno/virt/virtvm boots with rvtestinit.b as init,
# which runs a freestanding guest in VS-mode through #H -- the SBI
# answered by the kernel, a G-stage fault handed up as mmio, a WFI
# slept through to a timer interrupt delivered by hvip, and the SBI's
# shutdown.
#
# And M2 on the same backend: virtlinux (rvlinuxinit.b) boots Alpine's
# riscv64 linux-lts with vmlinux(1) to a busybox shell, types a command
# at it through the emulated 16550, and the guest's answer comes back.
#
# usage: scripts/check-rv.sh
# needs: os/inferno/virt/ivirtvm and ivirtlinux (mk CONF=virtvm,
# CONF=virtlinux), .guest/rv (scripts/mklinuxguest.sh), qemu-system-riscv64
ROOT=`cd \`dirname "$0"\`/.. && pwd`
K=$ROOT/os/inferno/virt/ivirtvm
[ -f "$K" ] || { echo "check-rv: no $K; mk CONF=virtvm in os/inferno/virt first" >&2; exit 1; }
SER=`mktemp`
LOG=`mktemp`
trap 'rm -f "$SER" "$LOG"' 0
# the serial port straight to a file (through a pipe, the last lines
# wait in a buffer); its lines end with \r
timeout 120 qemu-system-riscv64 -M virt -m 256 -display none -bios none -kernel "$K" \
	-monitor none -serial file:"$SER" </dev/null >/dev/null 2>&1 &
n=0
until tr -d '\r' <"$SER" >"$LOG"; grep -q 'RVTEST: M1 PASS\|RVTEST: FAIL\|panic' "$LOG"; do
	sleep 2
	n=`expr $n + 1`
	[ $n -gt 50 ] && break
done
sleep 1
pkill -f "qemu-system-riscv6[4].*$K" 2>/dev/null
tr -d '\r' <"$SER" >"$LOG"
grep 'RVTEST: \(backend\|exit\|the guest\|FAIL\|M1\)\|^vcpu0 handled\|^platform\|panic' "$LOG" | sed 's/^/	/'
fail=0
if grep -q 'RVTEST: M1 PASS' "$LOG"; then
	echo "check-rv: M1 (riscv-h, QEMU TCG): pass"
else
	echo "check-rv: M1 (riscv-h, QEMU TCG): FAIL"
	tail -20 "$LOG" | sed 's/^/	/'
	fail=1
fi

K=$ROOT/os/inferno/virt/ivirtlinux
[ -f "$K" ] || { echo "check-rv: no $K; mk CONF=virtlinux in os/inferno/virt first" >&2; exit 1; }
: >"$SER"
timeout 900 qemu-system-riscv64 -M virt -m 256 -display none -bios none -kernel "$K" \
	-monitor none -serial file:"$SER" </dev/null >/dev/null 2>&1 &
n=0
until tr -d '\r' <"$SER" >"$LOG"; grep -q 'RVLINUX: done\|panic' "$LOG"; do
	sleep 5
	n=`expr $n + 1`
	[ $n -gt 170 ] && break
done
pkill -f "qemu-system-riscv6[4].*$K" 2>/dev/null
tr -d '\r' <"$SER" >"$LOG"
grep -a '^Linux version\|SBI .*detected\|ttyS0 at\|^LINUXGUEST: \(up\|typed\|ran\)\|^Linux 6\|cpuinfo isa\|vmlinux: exit\|^vcpu0 handled\|^platform\|^uart\|panic' "$LOG" | sed 's/^/	/'
if grep -q '^LINUXGUEST: up' "$LOG" && grep -q '^LINUXGUEST: typed' "$LOG" && grep -q '^LINUXGUEST: ran' "$LOG"; then
	echo "check-rv: M2 (riscv-h, QEMU TCG): pass"
else
	echo "check-rv: M2 (riscv-h, QEMU TCG): FAIL"
	tail -20 "$LOG" | sed 's/^/	/'
	fail=1
fi
exit $fail
