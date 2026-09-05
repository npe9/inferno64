#!/bin/sh
set -eu

# End-to-end test for upas/fs: presenting a mailbox as a file system.
# Serves a two-message Unix mbox and checks, through the mounted file
# system, that each message is a numbered directory whose parsed header
# fields and body read correctly with cat - the Plan 9 upas "mail as a
# file system" model. Fully local; no network.

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
PATH="$root/MacOSX/arm64/bin:$PATH"
export PATH
test -x "$root/MacOSX/arm64/bin/emu-g" || { echo 'UPASFS: emu-g not built' >&2; exit 2; }
test -f "$root/dis/upas/fs.dis" || { echo 'UPASFS: dis/upas/fs.dis not built' >&2; exit 2; }

work="$root/.upasfstmp"
cleanup() { rm -rf "$work" "$root/mnt/upasfstest"; }
trap cleanup EXIT INT TERM
rm -rf "$work"; mkdir -p "$work"
cat > "$work/test.mbox" <<'MBOX'
From alice@example.com Mon Sep  4 10:00:00 2026
From: Alice <alice@example.com>
To: Bob <bob@example.com>
Subject: Hello Bob
Date: Mon, 4 Sep 2026 10:00:00 +0000

Hi Bob, this is the first message body.

From carol@example.com Mon Sep  4 11:00:00 2026
From: Carol <carol@example.com>
Subject: Meeting tomorrow

Second message body here.
MBOX

cat > "$work/exp.sh" <<'EMUSH'
/dis/upas/fs.dis -m /mnt/upasfstest /.upasfstmp/test.mbox
echo 'MARK ls'
ls /mnt/upasfstest
ls /mnt/upasfstest/mbox
echo 'MARK dir'
ls /mnt/upasfstest/mbox/1
echo 'MARK subj1'
cat /mnt/upasfstest/mbox/1/subject
echo ''
echo 'MARK from1'
cat /mnt/upasfstest/mbox/1/from
echo ''
echo 'MARK subj2'
cat /mnt/upasfstest/mbox/2/subject
echo ''
echo 'MARK body1'
cat /mnt/upasfstest/mbox/1/body
echo 'MARK done'
EMUSH

log="$work/out.log"
timeout 60 "$root/MacOSX/arm64/bin/emu-g" -r"$root" sh /.upasfstmp/exp.sh > "$log" 2>&1 || true
echo "===== log ====="; cat "$log"; echo "==============="

fail() { echo "UPASFS: FAIL - $1" >&2; exit 1; }
between() { awk "/MARK $1/{f=1;next} /MARK /{f=0} f" "$log"; }

grep -q 'MARK done' "$log" || fail "did not run to completion"
# two messages listed
between ls | grep -q '/1$' || fail "message 1 not listed"
between ls | grep -q '/2$' || fail "message 2 not listed"
# a message dir exposes parsed fields
for fld in body from header raw subject to date; do
	between dir | grep -q "/$fld\$" || fail "message dir missing field $fld"
done
# fields parse correctly
between subj1 | grep -q '^Hello Bob$' || fail "subject 1 wrong"
between from1 | grep -q 'Alice <alice@example.com>' || fail "from 1 wrong"
between subj2 | grep -q '^Meeting tomorrow$' || fail "subject 2 wrong"
between body1 | grep -q 'first message body' || fail "body 1 wrong"

echo 'UPASFS: PASS - mailbox served as a file system; per-message fields and body parse and read'
