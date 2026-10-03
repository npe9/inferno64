#!/bin/sh
# M12 of doc/genesize-plan.ms, the RISC-V H-extension backend, on
# QEMU's TCG (qemu-system-riscv64 -M virt, whose rv64 has the H
# extension): os/inferno/virt/virtvm boots with rvtestinit.b as init,
# which runs a freestanding guest in VS-mode through #H -- the SBI
# answered by the kernel, a G-stage fault handed up as mmio, a WFI
# slept through to a timer interrupt delivered by hvip, and the SBI's
# shutdown.
#
# And M2 and M8 on the same backend: virtlinux (rvlinuxinit.b) boots
# Alpine's riscv64 linux-lts with vmlinux(1) to a busybox shell, types a
# command at it through the emulated 16550, and the guest's answer comes
# back; the guest reads a marker from its virtio-mmio disk (a memfs
# file) and writes a sector Limbo reads back, and gets a DHCP lease on
# a virtio-net bridge port on the host's second NIC (QEMU's user
# network), both devices' interrupts through the platform's PLIC.
#
# And M3: virtsmp (rvsmpinit.b) boots the guest with four harts, the
# rest started by the SBI's hart_start; all come online, eight busy
# workers finish, every hart accounts time and takes IPIs.
#
# usage: scripts/check-rv.sh
# needs: os/inferno/virt/ivirtvm, ivirtlinux and ivirtsmp (mk CONF=...
# in os/inferno/virt), .guest/rv (scripts/mklinuxguest.sh),
# qemu-system-riscv64
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
timeout 1500 qemu-system-riscv64 -M virt -m 256 -display none -bios none -kernel "$K" \
	-netdev user,id=n0 -device virtio-net-device,netdev=n0 \
	-netdev user,id=n1 -device virtio-net-device,netdev=n1 \
	-monitor none -serial file:"$SER" </dev/null >/dev/null 2>&1 &
n=0
until tr -d '\r' <"$SER" >"$LOG"; grep -q 'RVLINUX: done\|panic' "$LOG"; do
	sleep 5
	n=`expr $n + 1`
	[ $n -gt 290 ] && break
done
pkill -f "qemu-system-riscv6[4].*$K" 2>/dev/null
tr -d '\r' <"$SER" >"$LOG"
grep -a 'ttyS0 at\|riscv-plic\|^LINUXGUEST: \(up\|typed\|vda\|wrote\|dhcp.*lease\|irq\|ran\)\|^Linux 6\|vmlinux: exit\|^vcpu0 handled\|^plic\|^mmio\|RVLINUX: disk\|panic' "$LOG" | sed 's/^/	/'
if grep -q '^LINUXGUEST: up' "$LOG" && grep -q '^LINUXGUEST: typed' "$LOG" && grep -q '^LINUXGUEST: ran' "$LOG"; then
	echo "check-rv: M2 (riscv-h, QEMU TCG): pass"
else
	echo "check-rv: M2 (riscv-h, QEMU TCG): FAIL"
	tail -20 "$LOG" | sed 's/^/	/'
	fail=1
fi
if grep -q '^LINUXGUEST: vda says INFERNO-VIRTIO-DISK' "$LOG" && grep -q 'RVLINUX: disk sector 1: guest-wrote-this' "$LOG"; then
	echo "check-rv: M8 disk (riscv-h, virtio-mmio, QEMU TCG): pass"
else
	echo "check-rv: M8 disk (riscv-h, virtio-mmio, QEMU TCG): FAIL"
	fail=1
fi
if grep -q '^LINUXGUEST: dhcp udhcpc: lease of' "$LOG"; then
	echo "check-rv: M8 net (riscv-h, virtio-mmio, QEMU TCG): pass"
else
	echo "check-rv: M8 net (riscv-h, virtio-mmio, QEMU TCG): FAIL"
	fail=1
fi
K=$ROOT/os/inferno/virt/ivirtsmp
[ -f "$K" ] || { echo "check-rv: no $K; mk CONF=virtsmp in os/inferno/virt first" >&2; exit 1; }
: >"$SER"
timeout 3000 qemu-system-riscv64 -M virt -m 256 -display none -bios none -kernel "$K" \
	-monitor none -serial file:"$SER" </dev/null >/dev/null 2>&1 &
n=0
until tr -d '\r' <"$SER" >"$LOG"; grep -q 'RVSMP: done\|panic' "$LOG"; do
	sleep 5
	n=`expr $n + 1`
	[ $n -gt 580 ] && break
done
pkill -f "qemu-system-riscv6[4].*$K" 2>/dev/null
tr -d '\r' <"$SER" >"$LOG"
grep -a 'smp: Brought up\|^LINUXGUEST: \(smp\|cpu\|irq IPI[01]\)\|^platform\|panic\|BUG\|stall\|lockup' "$LOG" | sed 's/^/	/'
ok=1
grep -q '^LINUXGUEST: smp 4 processors, online 0-3' "$LOG" || ok=0
[ `grep -c '^LINUXGUEST: worker [1-8] done' "$LOG"` -eq 8 ] || ok=0
for c in 0 1 2 3; do
	grep "^LINUXGUEST: cpu$c " "$LOG" | awk '{ if ($3 + $5 > 0) found = 1 } END { exit !found }' || ok=0
done
grep '^LINUXGUEST: irq IPI[01]:' "$LOG" | awk '{ n = 0; for (i = 4; i <= 7; i++) if ($i > 0) n++; if (n > 1) found = 1 } END { exit !found }' || ok=0
grep -q 'BUG\|soft lockup\|rcu.*stall' "$LOG" && ok=0
if [ $ok = 1 ]; then
	echo "check-rv: M3 (riscv-h, 4 harts, QEMU TCG): pass"
else
	echo "check-rv: M3 (riscv-h, 4 harts, QEMU TCG): FAIL"
	tail -20 "$LOG" | sed 's/^/	/'
	fail=1
fi
exit $fail
