#!/bin/sh
set -eu

# End-to-end test for pkg(1) milestone 2 (signing + verification). In one
# emu shell: generate two keypairs (alice, mallory), pack and sign a
# package with alice's key, verify and install it with alice's public key
# pinned, and run its command. The two negative controls are the point:
# installing with mallory's key pinned must be REJECTED (wrong signer),
# and verifying a tampered copy of the archive must FAIL (the signature is
# over the content). Without those, "signed" would mean nothing.

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
PATH="$root/MacOSX/arm64/bin:$PATH"
export PATH
test -x "$root/MacOSX/arm64/bin/emu-g" || { echo 'PKGSIGN: emu-g not built' >&2; exit 2; }
test -f "$root/dis/pkg.dis" || { echo 'PKGSIGN: dis/pkg.dis not built' >&2; exit 2; }

work="$root/.pkgsigntmp"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT INT TERM
rm -rf "$work"
mkdir -p "$work/stg/pkg" "$work/stg/dis"
cp "$root/dis/date.dis" "$work/stg/dis/pkgdemo.dis"
cat > "$work/stg/pkg/manifest" <<'MANIFEST'
name util/pkgdemo
version 1.0
category util
keywords demo signed
provides pkgdemo
MANIFEST

cat > "$work/exp.sh" <<'EMUSH'
cd /.pkgsigntmp
pkg genkey alice alice.sk
pkg genkey mallory mallory.sk
pkg pack stg hello.tar
pkg sign hello.tar alice.sk
echo 'MARK verify-good'
pkg verify -k alice.sk.pk hello.tar
echo 'MARK install-good'
pkg install -k alice.sk.pk hello.tar
pkgdemo
echo 'MARK wrongkey'
pkg install -k mallory.sk.pk hello.tar
echo 'MARK tamper'
cp hello.tar bad.tar
cp hello.tar.sig bad.tar.sig
echo corruption >> bad.tar
pkg verify bad.tar
echo 'MARK done'
EMUSH

log="$work/out.log"
timeout 90 "$root/MacOSX/arm64/bin/emu-g" -r"$root" sh /.pkgsigntmp/exp.sh > "$log" 2>&1 || true

echo "===== emu log ====="; cat "$log"; echo "==================="

fail() { echo "PKGSIGN: FAIL - $1" >&2; exit 1; }
between() { awk "/MARK $1/{f=1;next} /MARK /{f=0} f" "$log"; }

grep -q 'MARK done' "$log" || fail "script did not run to completion"
grep -q '^signed hello.tar' "$log" || fail "sign did not complete"
between verify-good | grep -q 'signature ok' || fail "verify with correct key failed"
between install-good | grep -q 'installed util/pkgdemo' || fail "signed install failed"
between install-good | grep -qE '(Mon|Tue|Wed|Thu|Fri|Sat|Sun) ' || fail "command did not run after signed install"
# negative control 1: wrong pinned key must be rejected
between wrongkey | grep -qi 'does not match' || fail "wrong signer key was ACCEPTED (negative control 1)"
# negative control 2: tampered archive must fail verification
between tamper | grep -qi 'does not verify' || fail "tampered archive VERIFIED (negative control 2)"

echo 'PKGSIGN: PASS - genkey/sign/verify/install-pin verified with wrong-key and tamper controls'
