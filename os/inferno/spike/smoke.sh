#!/bin/sh
# QEMU spike HTIF serial smoke
set -e
ROOT=${ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}
KERN=$ROOT/Inferno/riscv64/bin/ispike
export PATH=$ROOT/MacOSX/arm64/bin:$PATH

if [ ! -x "$KERN" ]; then
	echo "missing $KERN — build with: cd os/spike && mk SYSTARG=os OBJTYPE=riscv64 SHELLTYPE=sh INIT=spikeinit install" >&2
	exit 1
fi

LOG=${TMPDIR:-/tmp}/spike-smoke.$$.log
trap 'rm -f "$LOG"' EXIT

timeout 20 qemu-system-riscv64 -M spike -nographic -bios none \
	-kernel "$KERN" >"$LOG" 2>&1 || true

if grep -q 'Invalid htif' "$LOG"; then
	echo "spike smoke FAIL (Invalid htif)" >&2
	tail -40 "$LOG" >&2
	exit 1
fi

ok=0
grep -q 'SNPRINT-ABI-OK' "$LOG" && ok=$((ok+1))
grep -q 'SPIKE-OK' "$LOG" && ok=$((ok+1))
grep -q 'SPIKE-SH-OK' "$LOG" && ok=$((ok+1))
grep -q 'HELLO-FROM-SH' "$LOG" && ok=$((ok+1))
# The device tree QEMU hands this kernel in a1.  SPIKE-FDT-OK asserts
# agreement and not merely that nodes were found, and the blob line is
# the one that shows the allocator was kept off the tree: xalloc's top
# has to be the blob's own address, since -M spike puts the tree
# 2MB below the top of RAM, inside the range confinit() hands out.
grep -q 'SPIKE-FDT-OK' "$LOG" && ok=$((ok+1))
# The console ends its lines with CR LF, so nothing here anchors on $.
blob=$(sed -n 's/^fdt: blob @ 0x\([0-9a-f]*\) .*/\1/p' "$LOG" | tr -d '\r' | head -1)
top=$(sed -n 's/^[0-9a-f][0-9a-f]* \([0-9a-f][0-9a-f]*\) [0-9][0-9]*.*/\1/p' "$LOG" | tr -d '\r' | head -1)
if [ -n "$blob" ] && [ "$blob" = "$top" ]; then
	ok=$((ok+1))
else
	echo "spike smoke: xalloc top '$top' is not the dtb at '$blob'" >&2
fi

if [ "$ok" -eq 6 ]; then
	echo "spike smoke PASS"
	exit 0
fi
echo "spike smoke FAIL ($ok/6)" >&2
tail -40 "$LOG" >&2
exit 1
