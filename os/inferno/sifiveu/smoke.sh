#!/bin/sh
# QEMU sifive_u serial smoke
set -e
ROOT=${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
KERN=$ROOT/Inferno/riscv64/bin/isifiveu
export PATH=$ROOT/MacOSX/arm64/bin:$PATH

if [ ! -x "$KERN" ]; then
	echo "missing $KERN — build with: cd os/sifiveu && mk SYSTARG=os OBJTYPE=riscv64 SHELLTYPE=sh INIT=sifiveuinit install" >&2
	exit 1
fi

LOG=${TMPDIR:-/tmp}/sifiveu-smoke.$$.log
trap 'rm -f "$LOG"' EXIT

timeout 20 qemu-system-riscv64 -M sifive_u -nographic -bios none \
	-kernel "$KERN" >"$LOG" 2>&1 || true

ok=0
grep -q 'SNPRINT-ABI-OK' "$LOG" && ok=$((ok+1))
grep -q 'SIFIVEU-OK' "$LOG" && ok=$((ok+1))
grep -q 'SIFIVEU-SH-OK' "$LOG" && ok=$((ok+1))
grep -q 'HELLO-FROM-SH' "$LOG" && ok=$((ok+1))
grep -q 'ethersifivegem:' "$LOG" && ok=$((ok+1))
grep -q '#l0: gem:' "$LOG" && ok=$((ok+1))

if [ "$ok" -eq 6 ]; then
	echo "sifive_u smoke PASS"
	exit 0
fi
echo "sifive_u smoke FAIL ($ok/6)" >&2
tail -40 "$LOG" >&2
exit 1
