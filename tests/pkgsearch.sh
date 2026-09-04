#!/bin/sh
set -eu

# End-to-end test for pkg(1) milestone 4 (search). Publishes three
# packages with distinct manifest metadata into a repository, then
# searches it. Checks that: a keyword matches the right packages and only
# those; multiple terms are ANDed (narrowing the result); a term matching
# nothing returns no packages; and a bare search lists everything. Search
# is a name-space walk of the repository reading each manifest, so this
# also exercises the recursive descent through category subdirectories.

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
PATH="$root/MacOSX/arm64/bin:$PATH"
export PATH
test -x "$root/MacOSX/arm64/bin/emu-g" || { echo 'PKGSEARCH: emu-g not built' >&2; exit 2; }
test -f "$root/dis/pkg.dis" || { echo 'PKGSEARCH: dis/pkg.dis not built' >&2; exit 2; }

work="$root/.pkgsearchtmp"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT INT TERM
rm -rf "$work"

# three packages: name : category : keywords : description
set -- \
 "net/ssh:net:ssh secure-shell remote crypto:secure shell client" \
 "net/tls:net:tls ssl crypto secure:transport layer security" \
 "util/date:util:time clock date:print the date"
i=0
for spec in "$@"; do
	i=$((i+1))
	name=$(echo "$spec" | cut -d: -f1)
	cat=$(echo "$spec"  | cut -d: -f2)
	kw=$(echo "$spec"   | cut -d: -f3)
	desc=$(echo "$spec" | cut -d: -f4)
	mkdir -p "$work/p$i/pkg" "$work/p$i/dis"
	cp "$root/dis/date.dis" "$work/p$i/dis/pkgdemo.dis"
	printf 'name %s\nversion 1.0\ncategory %s\nkeywords %s\ndescription %s\n' \
		"$name" "$cat" "$kw" "$desc" > "$work/p$i/pkg/manifest"
done

cat > "$work/exp.sh" <<'EMUSH'
cd /.pkgsearchtmp
pkg pack p1 t1.tar; pkg publish repo t1.tar
pkg pack p2 t2.tar; pkg publish repo t2.tar
pkg pack p3 t3.tar; pkg publish repo t3.tar
echo 'MARK crypto'
pkg search -r repo crypto
echo 'MARK two'
pkg search -r repo secure client
echo 'MARK none'
pkg search -r repo nonexistentxyz
echo 'MARK all'
pkg search -r repo
echo 'MARK done'
EMUSH

log="$work/out.log"
timeout 90 "$root/MacOSX/arm64/bin/emu-g" -r"$root" sh /.pkgsearchtmp/exp.sh > "$log" 2>&1 || true

echo "===== emu log ====="; cat "$log"; echo "==================="

fail() { echo "PKGSEARCH: FAIL - $1" >&2; exit 1; }
between() { awk "/MARK $1/{f=1;next} /MARK /{f=0} f" "$log"; }

grep -q 'MARK done' "$log" || fail "script did not run to completion"

# 'crypto' matches ssh and tls, not date
between crypto | grep -q 'net/ssh'  || fail "crypto search missed net/ssh"
between crypto | grep -q 'net/tls'  || fail "crypto search missed net/tls"
between crypto | grep -q 'util/date' && fail "crypto search wrongly matched util/date"
# two terms are ANDed: 'secure client' -> ssh only (tls has secure, not client)
between two | grep -q 'net/ssh'  || fail "AND search missed net/ssh"
between two | grep -q 'net/tls'  && fail "AND search wrongly matched net/tls (terms not ANDed)"
# no match
between none | grep -qi 'no matching' || fail "impossible term returned matches"
# bare search lists all three
for p in net/ssh net/tls util/date; do
	between all | grep -q "$p" || fail "bare search missed $p"
done

echo 'PKGSEARCH: PASS - keyword, ANDed terms, no-match and list-all all verified'
