#!/bin/sh
set -eu

# Test MIME decomposition in upas/fs (mime(2)): serve an mbox whose one
# message is multipart/mixed with a text/plain part and a base64-encoded
# attachment, and check through the file system that the message is
# decomposed into numbered part directories with decoded bodies, correct
# content types, and the attachment filename - the way Plan 9 upas/fs
# decomposes MIME. Fully local; no network.

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
PATH="$root/MacOSX/arm64/bin:$PATH"
export PATH
test -x "$root/MacOSX/arm64/bin/emu-g" || { echo 'UPASMIME: emu-g not built' >&2; exit 2; }
test -f "$root/dis/upas/fs.dis" || { echo 'UPASMIME: dis/upas/fs.dis not built' >&2; exit 2; }
test -f "$root/dis/lib/mime.dis" || { echo 'UPASMIME: dis/lib/mime.dis not built' >&2; exit 2; }

work="$root/.upasmimetmp"
cleanup() { rm -rf "$work" "$root/mnt/upasmimetest"; }
trap cleanup EXIT INT TERM
rm -rf "$work"; mkdir -p "$work"
# aGVsbG8gYXR0YWNobWVudA== is base64 for "hello attachment"
cat > "$work/test.mbox" <<'MBOX'
From sender@example.com Mon Sep  4 12:00:00 2026
From: Sender <sender@example.com>
Subject: =?UTF-8?B?V2l0aCBhdHRhY2htZW50?=
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="BOUND"

--BOUND
Content-Type: text/plain

This is the text part.
--BOUND
Content-Type: application/octet-stream; name="hello.txt"
Content-Transfer-Encoding: base64
Content-Disposition: attachment; filename="hello.txt"

aGVsbG8gYXR0YWNobWVudA==
--BOUND--
MBOX

cat > "$work/exp.sh" <<'EMUSH'
/dis/upas/fs.dis -m /mnt/upasmimetest /.upasmimetmp/test.mbox
echo 'MARK subject'
cat /mnt/upasmimetest/1/subject
echo ''
echo 'MARK msgtype'
cat /mnt/upasmimetest/1/type
echo ''
echo 'MARK parts'
ls /mnt/upasmimetest/1
echo 'MARK p1type'
cat /mnt/upasmimetest/1/1/type
echo ''
echo 'MARK p1body'
cat /mnt/upasmimetest/1/1/body
echo ''
echo 'MARK p2type'
cat /mnt/upasmimetest/1/2/type
echo ''
echo 'MARK p2file'
cat /mnt/upasmimetest/1/2/filename
echo ''
echo 'MARK p2body'
cat /mnt/upasmimetest/1/2/body
echo ''
echo 'MARK body'
cat /mnt/upasmimetest/1/body
echo ''
echo 'MARK done'
EMUSH

log="$work/out.log"
timeout 60 "$root/MacOSX/arm64/bin/emu-g" -r"$root" sh /.upasmimetmp/exp.sh > "$log" 2>&1 || true
echo "===== log ====="; cat "$log"; echo "==============="

fail() { echo "UPASMIME: FAIL - $1" >&2; exit 1; }
between() { awk "/MARK $1/{f=1;next} /MARK /{f=0} f" "$log"; }

grep -q 'MARK done' "$log" || fail "did not complete"
# RFC 2047: the base64-encoded Subject must be decoded
between subject | grep -q '^With attachment$' || fail "RFC 2047 subject not decoded"
between msgtype | grep -q 'multipart/mixed' || fail "message not recognised as multipart/mixed"
between parts | grep -q '/1$' || fail "part 1 dir missing"
between parts | grep -q '/2$' || fail "part 2 dir missing"
between p1type | grep -q 'text/plain' || fail "part 1 type wrong"
between p1body | grep -q 'This is the text part' || fail "part 1 body wrong"
between p2type | grep -q 'application/octet-stream' || fail "part 2 type wrong"
between p2file | grep -q 'hello.txt' || fail "attachment filename wrong"
# base64 decoded attachment
between p2body | grep -q 'hello attachment' || fail "attachment not base64-decoded"
# the message body convenience = the text/plain part, decoded
between body | grep -q 'This is the text part' || fail "message body not the decoded text part"

echo 'UPASMIME: PASS - multipart decomposed into parts; base64 decoded; content types and filename correct'
