#!/bin/sh
# M12 of doc/genesize-plan.ms, the RISC-V H-extension backend, on
# QEMU's TCG (qemu-system-riscv64 -M virt, whose rv64 has the H
# extension): os/inferno/virt/virtvm boots with rvtestinit.b as init,
# which runs a freestanding guest in VS-mode through #H -- the SBI
# answered by the kernel, a G-stage fault handed up as mmio, a WFI
# slept through to a timer interrupt delivered by hvip, and the SBI's
# shutdown.
#
# usage: scripts/check-rv.sh
# needs: os/inferno/virt/ivirtvm (mk CONF=virtvm), qemu-system-riscv64
ROOT=`cd \`dirname "$0"\`/.. && pwd`
K=$ROOT/os/inferno/virt/ivirtvm
[ -f "$K" ] || { echo "check-rv: no $K; mk CONF=virtvm in os/inferno/virt first" >&2; exit 1; }
LOG=`mktemp`
trap 'rm -f "$LOG"' 0
# QEMU's -nographic console ends lines with \r
timeout 120 qemu-system-riscv64 -M virt -m 256 -nographic -bios none -kernel "$K" \
	-monitor none -serial stdio </dev/null 2>&1 | tr -d '\r' >"$LOG" &
n=0
until grep -q 'RVTEST: M1 PASS\|RVTEST: FAIL\|panic' "$LOG"; do
	sleep 2
	n=`expr $n + 1`
	[ $n -gt 50 ] && break
done
sleep 1
pkill -f "qemu-system-riscv6[4].*$K" 2>/dev/null
grep 'RVTEST: \(backend\|exit\|the guest\|FAIL\|M1\)\|^vcpu0 handled\|^platform\|panic' "$LOG" | sed 's/^/	/'
if grep -q 'RVTEST: M1 PASS' "$LOG"; then
	echo "check-rv: M1 (riscv-h, QEMU TCG): pass"
	exit 0
fi
echo "check-rv: M1 (riscv-h, QEMU TCG): FAIL"
tail -20 "$LOG" | sed 's/^/	/'
exit 1
