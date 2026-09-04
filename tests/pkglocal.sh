#!/bin/sh
set -eu

# End-to-end test for pkg(1) milestone 1 (local format + install-by-mount).
# Drives the real user-facing flow inside a single emu shell so the
# namespace binds performed by `pkg install` persist across steps - the
# load-bearing property of the whole design. A package (a tar of
# pkg/manifest + dis/pkgdemo.dis, where pkgdemo is date under a new name)
# is packed, inspected, installed, run BY BARE NAME, listed, removed, and
# run again. The two negative controls are the point: pkgdemo must NOT
# resolve before install nor after remove, and MUST run in between -
# otherwise "install" and "remove" are not actually composing the
# namespace. A unique command name avoids accidentally resolving a real
# /dis command.

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
PATH="$root/MacOSX/arm64/bin:$PATH"
export PATH
test -x "$root/MacOSX/arm64/bin/emu-g" || { echo 'PKGLOCAL: emu-g not built' >&2; exit 2; }
test -f "$root/dis/pkg.dis" || { echo 'PKGLOCAL: dis/pkg.dis not built (mk install in appl/cmd)' >&2; exit 2; }
test -f "$root/dis/tarfs.dis" || { echo 'PKGLOCAL: dis/tarfs.dis missing' >&2; exit 2; }

# emu's / is the tree root, so staging must live under $root to be visible
# inside emu. Never committed.
work="$root/.pkgtesttmp"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT INT TERM
rm -rf "$work"
mkdir -p "$work/stg/pkg" "$work/stg/dis"
cp "$root/dis/date.dis" "$work/stg/dis/pkgdemo.dis"
cat > "$work/stg/pkg/manifest" <<'MANIFEST'
name util/pkgdemo
version 1.0
category util
keywords demo date example
provides pkgdemo
description demo package - date under a new name
MANIFEST

cat > "$work/exp.sh" <<'EMUSH'
echo 'MARK start'
cd /.pkgtesttmp
pkg pack stg hello.tar
echo 'MARK packed'
pkg info hello.tar
echo 'MARK neg-before'
pkgdemo
echo 'MARK install'
pkg install hello.tar
echo 'MARK run'
pkgdemo
echo 'MARK list'
pkg list
echo 'MARK remove'
pkg remove util/pkgdemo
echo 'MARK neg-after'
pkgdemo
echo 'MARK done'
EMUSH

log="$work/out.log"
# a backgrounded tarfs keeps emu alive after the script ends, so cap it.
timeout 90 "$root/MacOSX/arm64/bin/emu-g" -r"$root" sh /.pkgtesttmp/exp.sh > "$log" 2>&1 || true

echo "===== emu log ====="
cat "$log"
echo "==================="

fail() { echo "PKGLOCAL: FAIL - $1" >&2; exit 1; }

# section extractor: lines strictly between two MARK lines
between() { awk "/MARK $1/{f=1;next} /MARK /{f=0} f" "$log"; }

grep -q 'MARK done' "$log" || fail "script did not run to completion"
grep -q 'MARK packed' "$log" || fail "pack did not complete"
grep -q '^name util/pkgdemo' "$log" || fail "info did not show the manifest"
grep -q '^content-sha256 ' "$log" || fail "info did not show the content hash"

# negative control 1: pkgdemo must fail before install
between neg-before | grep -qi 'does not exist' || fail "pkgdemo resolved BEFORE install (negative control 1)"
# positive: after install, pkgdemo runs and prints a date (GMT weekday)
between run | grep -qE '(Mon|Tue|Wed|Thu|Fri|Sat|Sun) ' || fail "pkgdemo did not run after install"
# list shows it
between list | grep -q 'util/pkgdemo' || fail "pkg list did not show the package"
# remove reports success
grep -q 'removed util/pkgdemo' "$log" || fail "remove did not report success"
# negative control 2: pkgdemo must fail again after remove
between neg-after | grep -qi 'does not exist' || fail "pkgdemo still resolved AFTER remove (negative control 2)"

echo 'PKGLOCAL: PASS - pack/info/install/run/list/remove verified with both negative controls'
