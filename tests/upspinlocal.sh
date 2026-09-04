#!/bin/sh
set -eu

# End-to-end test for upspin(1): the Upspin-style content namespace.
# Content is split into content-addressed blocks in a Store; a name maps
# to a signed DirEntry; a reader verifies through the KeyServer
# (name -> owner -> key). The three negative controls are what make this
# Upspin rather than a directory of files:
#   1. forged owner  - an entry stored under alice but signed by mallory
#      must be REJECTED (verification is by the name's owner key, not any
#      key in the entry).
#   2. tampered entry - changing a signed field must fail the signature.
#   3. tampered block - a store block that no longer hashes to its ref
#      must be rejected on read (content-addressing lives in the check).

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
PATH="$root/MacOSX/arm64/bin:$PATH"
export PATH
test -x "$root/MacOSX/arm64/bin/emu-g" || { echo 'UPSPIN: emu-g not built' >&2; exit 2; }
test -f "$root/dis/upspin.dis" || { echo 'UPSPIN: dis/upspin.dis not built' >&2; exit 2; }
test -f "$root/dis/lib/upspin.dis" || { echo 'UPSPIN: dis/lib/upspin.dis not built' >&2; exit 2; }

work="$root/.upspintmp"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT INT TERM
rm -rf "$work"; mkdir -p "$work"
printf 'hello upspin world\n' > "$work/hello.txt"
printf 'a different file entirely\n' > "$work/other.txt"

emu() { timeout 90 "$root/MacOSX/arm64/bin/emu-g" -r"$root" sh "$1" > "$2" 2>&1 || true; }
fail() { echo "UPSPIN: FAIL - $1" >&2; exit 1; }
between() { awk "/MARK $2/{f=1;next} /MARK /{f=0} f" "$1"; }

# ---- run 1: keygen, put two files, positive get, ls, forged put+get ----
cat > "$work/r1.sh" <<'EMUSH'
cd /.upspintmp
upspin -b base keygen alice@x.org alice.sk
upspin -b base keygen mallory@x.org mallory.sk
upspin -b base put alice@x.org/docs/hello hello.txt alice.sk
upspin -b base put alice@x.org/docs/other other.txt alice.sk
echo 'MARK get'
upspin -b base get alice@x.org/docs/hello
echo 'MARK ls'
upspin -b base ls alice@x.org
echo 'MARK forge'
upspin -b base put alice@x.org/evil hello.txt mallory.sk
upspin -b base get alice@x.org/evil
echo 'MARK done'
EMUSH
emu /.upspintmp/r1.sh "$work/r1.log"
echo "===== run 1 ====="; cat "$work/r1.log"

grep -q 'MARK done' "$work/r1.log" || fail "run 1 did not complete"
between "$work/r1.log" get | grep -q 'hello upspin world' || fail "get did not return the content"
between "$work/r1.log" ls | grep -q 'alice@x.org/docs/hello' || fail "ls missed a name"
between "$work/r1.log" ls | grep -q 'alice@x.org/docs/other' || fail "ls missed a name"
# negative control 1: forged owner
between "$work/r1.log" forge | grep -qi 'does not verify' || fail "forged-owner entry was ACCEPTED (control 1)"

# ---- tamper on disk: entry signature and a store block ----
entry="$work/base/dir/alice@x.org/docs/other.entry"
test -f "$entry" || fail "entry file not found for tamper"
# change the signed size field (line 3) -> signature must fail
sed '3s/.*/999999/' "$entry" > "$entry.tmp" && mv "$entry.tmp" "$entry"
# corrupt every stored block -> hello's block will fail its hash
for b in "$work"/base/store/*; do printf 'corruption' >> "$b"; done

# ---- run 2: the two on-disk tamper controls ----
cat > "$work/r2.sh" <<'EMUSH'
cd /.upspintmp
echo 'MARK sigtamper'
upspin -b base get alice@x.org/docs/other
echo 'MARK blocktamper'
upspin -b base get alice@x.org/docs/hello
echo 'MARK done'
EMUSH
emu /.upspintmp/r2.sh "$work/r2.log"
echo "===== run 2 ====="; cat "$work/r2.log"

grep -q 'MARK done' "$work/r2.log" || fail "run 2 did not complete"
# negative control 2: tampered signed field
between "$work/r2.log" sigtamper | grep -qi 'does not verify' || fail "tampered entry VERIFIED (control 2)"
# negative control 3: tampered block
between "$work/r2.log" blocktamper | grep -qi 'content hash' || fail "tampered block ACCEPTED (control 3)"

echo 'UPSPIN: PASS - content-addressed put/get/ls verified, with forged-owner, tampered-entry and tampered-block controls'
