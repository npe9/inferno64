#!/bin/sh
set -eu

# End-to-end test for pkg(1) milestone 3 (repository + install by name).
# A repository is a directory tree repo/<name>/<version>.tar walked by
# name - the local form of the naming layer. In one emu shell: sign and
# publish two versions (1.0 then 1.1) of a package, then `pkg install` it
# BY NAME (not a file path). It must resolve to the NEWEST version, verify
# the signature, install, and run. Negative control: installing a name
# that is not in the repository must fail rather than silently do nothing.

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
PATH="$root/MacOSX/arm64/bin:$PATH"
export PATH
test -x "$root/MacOSX/arm64/bin/emu-g" || { echo 'PKGREPO: emu-g not built' >&2; exit 2; }
test -f "$root/dis/pkg.dis" || { echo 'PKGREPO: dis/pkg.dis not built' >&2; exit 2; }

work="$root/.pkgrepotmp"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT INT TERM
rm -rf "$work"
mkdir -p "$work/stg/pkg" "$work/stg/dis"
cp "$root/dis/date.dis" "$work/stg/dis/pkgdemo.dis"
# version written into the manifest is overwritten per build below
cat > "$work/stg/pkg/manifest" <<'MANIFEST'
name util/pkgdemo
version 1.0
category util
keywords demo repo
provides pkgdemo
MANIFEST

cat > "$work/exp.sh" <<'EMUSH'
cd /.pkgrepotmp
pkg genkey alice alice.sk
# publish version 1.0
pkg pack stg v10.tar
pkg sign v10.tar alice.sk
pkg publish repo v10.tar
# publish version 1.1 (edit the manifest version, repack)
echo 'name util/pkgdemo' > stg/pkg/manifest
echo 'version 1.1' >> stg/pkg/manifest
echo 'category util' >> stg/pkg/manifest
pkg pack stg v11.tar
pkg sign v11.tar alice.sk
pkg publish repo v11.tar
echo 'MARK resolve'
pkg install -r repo -k alice.sk.pk util/pkgdemo
echo 'MARK run'
pkgdemo
echo 'MARK list'
pkg list
echo 'MARK notfound'
pkg install -r repo util/nosuchthing
echo 'MARK done'
EMUSH

log="$work/out.log"
timeout 90 "$root/MacOSX/arm64/bin/emu-g" -r"$root" sh /.pkgrepotmp/exp.sh > "$log" 2>&1 || true

echo "===== emu log ====="; cat "$log"; echo "==================="

fail() { echo "PKGREPO: FAIL - $1" >&2; exit 1; }
between() { awk "/MARK $1/{f=1;next} /MARK /{f=0} f" "$log"; }

grep -q 'MARK done' "$log" || fail "script did not run to completion"
grep -q 'published util/pkgdemo 1.0' "$log" || fail "publish 1.0 failed"
grep -q 'published util/pkgdemo 1.1' "$log" || fail "publish 1.1 failed"
# resolution must pick the newest version (1.1) and verify it
between resolve | grep -q '1.1.tar' || fail "did not resolve to newest version 1.1"
between resolve | grep -q 'signature ok' || fail "resolved package signature not verified"
between resolve | grep -q 'installed util/pkgdemo 1.1' || fail "install-by-name failed"
between run | grep -qE '(Mon|Tue|Wed|Thu|Fri|Sat|Sun) ' || fail "command did not run after install-by-name"
between list | grep -q 'util/pkgdemo' || fail "pkg list did not show the package"
# negative control: a name absent from the repository must fail
between notfound | grep -qi 'no package' || fail "installing a missing name did not fail (negative control)"

echo 'PKGREPO: PASS - publish + install-by-name (newest version, verified) with not-found control'
