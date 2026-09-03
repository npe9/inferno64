#!/bin/sh
set -eu

# Differential check of this tree's cryptographic primitives against
# formal Cryptol specifications. For each primitive, the SAME random
# inputs are fed to keyring(2) (through the cryptovec(1) Limbo driver,
# run under emu) and to a Cryptol spec, and the hex outputs are diffed.
#
# This is NOT a proof that the implementation equals the spec - that
# would need SAW over LLVM/JVM bitcode, and neither Dis bytecode nor
# plan9 C is a SAW target. It is the achievable, defensible thing:
# Cryptol as a formal EXECUTABLE SPECIFICATION used as a differential
# oracle, checking the implementation against the spec over many inputs.
#
# References: SHA-256/512 use Cryptol's bundled SuiteB (NSA Suite B);
# ChaCha20 uses Galois' public-domain chacha20 spec (vendored, RFC
# 8439); Poly1305 uses a spec written here from RFC 8439. Covered:
# the hashes plus the SSH transport's cipher and MAC. Out of scope
# (compositions, not primitives, or needing bespoke verify specs):
# RSA/PKCS#1, the TLS/SSH handshakes, ECDSA-P256 and Ed25519 verify.
#
# Needs the `cryptol` binary: on PATH, or CRYPTOL_DIR pointing at an
# unpacked release (containing bin/cryptol and share/cryptol). Skips
# (exit 2) if absent, like the other host-side tests here.

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
PATH="$root/MacOSX/arm64/bin:$PATH"
export PATH

cryptol=$(command -v cryptol 2>/dev/null || true)
if [ -z "$cryptol" ] && [ -n "${CRYPTOL_DIR:-}" ]; then
	cryptol="$CRYPTOL_DIR/bin/cryptol"
fi
if [ -z "$cryptol" ] || [ ! -x "$cryptol" ]; then
	echo 'CRYPTOLVERIFY: cryptol not found (set CRYPTOL_DIR or put it on PATH)' >&2
	exit 2
fi
share=$(CDPATH= cd -- "$(dirname "$cryptol")/../share/cryptol" && pwd)
export CRYPTOLPATH="$share:$root/tests/cryptol"
test -x "$root/MacOSX/arm64/bin/emu-g" || { echo 'CRYPTOLVERIFY: emu-g not built' >&2; exit 2; }

work="$root/.cvtmp"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
rm -rf "$work"; mkdir -p "$work"
cd "$root"
rc=0
N=${CRYPTOLVERIFY_N:-24}

# run the Inferno side for a primitive over the staged input file
inferno() { ./MacOSX/arm64/bin/emu-g -r. cryptovec "$1" /.cvtmp/inputs.txt 2>/dev/null; }

# compare two output files; $1 = label
compare() {
	if diff -q "$work/inferno.txt" "$work/cryptol.txt" >/dev/null; then
		echo "CRYPTOLVERIFY: $1: $N/$N match Cryptol spec: PASS"
	else
		echo "CRYPTOLVERIFY: $1: MISMATCH"; diff "$work/inferno.txt" "$work/cryptol.txt" | head; rc=1
	fi
}

# self-check: a corrupted Inferno output MUST diff against the spec,
# proving the harness actually detects differences
negcontrol() {
	perturbed="$work/inferno.bad"
	awk 'NR==1{ $0=substr($0,1,length($0)-1) (substr($0,length($0)) == "0" ? "1" : "0") } {print}' "$work/inferno.txt" > "$perturbed"
	if diff -q "$perturbed" "$work/cryptol.txt" >/dev/null; then
		echo "CRYPTOLVERIFY: $1: NEGATIVE CONTROL FAILED (perturbed output still matched)"; rc=1
	else
		echo "CRYPTOLVERIFY: $1: negative control (perturbed output is caught): PASS"
	fi
}

# ---- SHA-256 / SHA-512 (Cryptol SuiteB) ---------------------------
sha_test() {
	prim=$1; fn=$2
	python3 - "$work/inputs.txt" "$N" <<'PY'
import os,sys,random
random.seed(hash(sys.argv[1])&0xffff)
f=open(sys.argv[1],'w')
for _ in range(int(sys.argv[2])):
    f.write(os.urandom(random.randint(1,96)).hex()+"\n")
PY
	inferno "$prim" > "$work/inferno.txt"
	{ echo ':module SuiteB'; echo ':set base=16';
	  while read -r h; do bits=$(( ${#h} * 4 )); echo "$fn (0x$h : [$bits])"; done < "$work/inputs.txt"; } > "$work/s.icry"
	"$cryptol" -b "$work/s.icry" 2>/dev/null | grep '^0x' | sed 's/^0x//' > "$work/cryptol.txt"
	compare "$prim"; negcontrol "$prim"
}

# ---- ChaCha20 (vendored Galois spec) ------------------------------
chacha_test() {
	python3 - "$work/inputs.txt" "$work/params.txt" "$N" <<'PY'
import os,sys,random,struct
random.seed(7)
inp=open(sys.argv[1],'w'); par=open(sys.argv[2],'w')
for _ in range(int(sys.argv[3])):
    key=os.urandom(32); nonce=os.urandom(12); ctr=random.randint(0,2**31); pt=os.urandom(random.randint(1,96))
    inp.write((key+nonce+struct.pack('<I',ctr)+pt).hex()+"\n")
    par.write(f"{key.hex()} {ctr} {nonce.hex()} {pt.hex()}\n")
PY
	inferno chacha20 > "$work/inferno.txt"
	{ echo ':module chacha20'; echo ':set base=16';
	  while read -r key ctr nonce pt; do
	    echo "join (encrypt (split 0x$key) ($ctr : [32]) (split 0x$nonce) (split 0x$pt))"
	  done < "$work/params.txt"; } > "$work/c.icry"
	"$cryptol" -b "$work/c.icry" 2>/dev/null | grep '^0x' | sed 's/^0x//' > "$work/cryptol.txt"
	compare chacha20; negcontrol chacha20
}

# ---- Poly1305 (spec written here from RFC 8439) -------------------
poly_test() {
	python3 - "$work/inputs.txt" "$work/params.txt" "$N" <<'PY'
import os,sys,random
random.seed(11)
inp=open(sys.argv[1],'w'); par=open(sys.argv[2],'w')
for _ in range(int(sys.argv[3])):
    key=os.urandom(32); msg=os.urandom(random.randint(1,96))
    inp.write((key+msg).hex()+"\n")
    par.write(f"{key.hex()} {msg.hex()}\n")
PY
	inferno poly1305 > "$work/inferno.txt"
	{ echo ':module Poly1305'; echo ':set base=16';
	  while read -r key msg; do echo "join (poly1305 (split 0x$key) (split 0x$msg))"; done < "$work/params.txt"; } > "$work/p.icry"
	"$cryptol" -b "$work/p.icry" 2>/dev/null | grep '^0x' | sed 's/^0x//' > "$work/cryptol.txt"
	compare poly1305; negcontrol poly1305
}

echo "CRYPTOLVERIFY: using $($cryptol --version 2>/dev/null | head -1), $N inputs each"
sha_test sha256 sha256
sha_test sha512 sha512
chacha_test
poly_test

[ "$rc" -eq 0 ] && echo 'CRYPTOLVERIFY: ALL PASS' || echo 'CRYPTOLVERIFY: FAILURE'
exit $rc
