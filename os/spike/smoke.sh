#!/bin/sh
# QEMU spike HTIF serial smoke
set -e
ROOT=${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
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

if [ "$ok" -eq 4 ]; then
	echo "spike smoke PASS"
	exit 0
fi
echo "spike smoke FAIL ($ok/4)" >&2
tail -40 "$LOG" >&2
exit 1
