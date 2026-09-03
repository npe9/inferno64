#!/bin/sh
set -eu

# Prove a Dis-compiled cryptographic kernel equivalent to a Cryptol
# specification, using SAW - i.e. do Dis in SAW.
#
# SAW's native frontend is LLVM and Dis has none, so the pipeline is:
#   qr.b  --limbo-->  qr.dis  --disdump-->  Dis assembly
#         --dis2ll.py-->  LLVM IR  --llvm-as-->  bitcode  --saw-->  proof
# SAW then symbolically executes the bitcode and proves it equals the
# Cryptol spec (qrspec.cry) for ALL inputs (2^128 word-tuples), not a
# sample - a genuine equivalence proof, discharged by z3.
#
# This is stronger than tests/cryptolverify.sh (which checks outputs on
# N inputs) but narrower: dis2ll.py only accepts the STRAIGHT-LINE 32-bit
# word-arithmetic fragment - no branches, loops, calls, heap, or arrays
# - which is exactly what a crypto kernel's core compiles to, and where
# a Dis instruction maps one-to-one onto an LLVM SSA op. The translator
# rejects anything outside that fragment rather than mistranslate it.
#
# Needs: this tree's limbo/emu (built), the `saw` binary (on PATH or via
# SAW_DIR), and llvm-as (on PATH, or brew's at /opt/homebrew/opt/llvm).
# Skips (exit 2) if a tool is missing, like the other host-side tests.

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
PATH="$root/MacOSX/arm64/bin:$PATH"
export PATH

saw=$(command -v saw 2>/dev/null || true)
[ -z "$saw" ] && [ -n "${SAW_DIR:-}" ] && saw="$SAW_DIR/bin/saw"
[ -n "$saw" ] && [ -x "$saw" ] || { echo 'SAWVERIFY: saw not found (set SAW_DIR or PATH)' >&2; exit 2; }

llvmas=$(command -v llvm-as 2>/dev/null || true)
[ -z "$llvmas" ] && [ -x /opt/homebrew/opt/llvm/bin/llvm-as ] && llvmas=/opt/homebrew/opt/llvm/bin/llvm-as
[ -n "$llvmas" ] && [ -x "$llvmas" ] || { echo 'SAWVERIFY: llvm-as not found' >&2; exit 2; }

command -v limbo >/dev/null 2>&1 || { echo 'SAWVERIFY: limbo not built' >&2; exit 2; }
test -x "$root/MacOSX/arm64/bin/emu-g" || { echo 'SAWVERIFY: emu-g not built' >&2; exit 2; }

work="$root/.sawtmp"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
rm -rf "$work"; mkdir -p "$work"
cd "$root"
sawd="$root/tests/saw"
rc=0

echo "SAWVERIFY: using $($saw --version 2>/dev/null | head -1)"

# 1. compile the Limbo kernel to Dis, and disassemble it
(cd "$sawd" && ROOT="$root" limbo -o "$work/qr.dis" qr.b)
"$root/MacOSX/arm64/bin/emu-g" -r. disdump /.sawtmp/qr.dis 2>/dev/null > "$work/qr.dis.txt"
echo "SAWVERIFY: Dis kernel ($(grep -c . "$work/qr.dis.txt") instructions):"
sed 's/^/    /' "$work/qr.dis.txt"

# 2. translate Dis -> LLVM, assemble to bitcode
python3 "$sawd/dis2ll.py" "$work/qr.dis.txt" qr > "$work/qr.ll"
"$llvmas" "$work/qr.ll" -o "$work/qr.bc"

# 3. SAW: prove the Dis-derived bitcode == the Cryptol spec
cp "$sawd/qrspec.cry" "$sawd/qr.saw" "$work/"
if (cd "$work" && "$saw" qr.saw 2>&1) | grep -q "Proof succeeded"; then
	echo 'SAWVERIFY: Dis-compiled qr == Cryptol spec, proved for all inputs: PASS'
else
	echo 'SAWVERIFY: proof FAILED'; rc=1
fi

# 4. negative control: a deliberately wrong spec MUST make SAW fail,
#    proving the proof is load-bearing and not vacuous
sed 's/a  = a0 + b0/a  = a0 - b0/' "$sawd/qrspec.cry" > "$work/qrspec.cry"
if (cd "$work" && "$saw" qr.saw 2>&1) | grep -q "Proof failed"; then
	echo 'SAWVERIFY: negative control (wrong spec is rejected with a counterexample): PASS'
else
	echo 'SAWVERIFY: NEGATIVE CONTROL FAILED (wrong spec was not rejected)'; rc=1
fi

[ "$rc" -eq 0 ] && echo 'SAWVERIFY: ALL PASS' || echo 'SAWVERIFY: FAILURE'
exit $rc
