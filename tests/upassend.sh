#!/bin/sh
set -eu

# Test message composition in upas/send: compose (dry-run, -N, no network)
# a message with a subject, a text body and a file attachment, then serve
# the result through upas/fs and check that it round-trips - the composed
# multipart parses back into a text part and a base64 attachment with the
# right filename and decoded content. Fully local; no network, no account.

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
PATH="$root/MacOSX/arm64/bin:$PATH"
export PATH
test -x "$root/MacOSX/arm64/bin/emu-g" || { echo 'UPASSEND: emu-g not built' >&2; exit 2; }
test -f "$root/dis/upas/send.dis" || { echo 'UPASSEND: dis/upas/send.dis not built' >&2; exit 2; }
test -f "$root/dis/upas/fs.dis" || { echo 'UPASSEND: dis/upas/fs.dis not built' >&2; exit 2; }

work="$root/.upassendtmp"
cleanup() { rm -rf "$work" "$root/mnt/upassendtest"; }
trap cleanup EXIT INT TERM
rm -rf "$work"; mkdir -p "$work"
printf 'This is the email body.\n' > "$work/body.txt"
printf 'attachment payload here\n' > "$work/attach.txt"

cat > "$work/exp.sh" <<'EMUSH'
# compose (no network) to a file
/dis/upas/send.dis -N -f me@example.com -t you@example.com -j 'Test Subject' -A /.upassendtmp/attach.txt /.upassendtmp/body.txt > /.upassendtmp/composed.eml
# wrap as a one-message mbox and serve it
{echo 'From compose@local'; cat /.upassendtmp/composed.eml} > /.upassendtmp/msg.mbox
/dis/upas/fs.dis -m /mnt/upassendtest /.upassendtmp/msg.mbox
echo 'MARK subject'
cat /mnt/upassendtest/1/subject
echo ''
echo 'MARK type'
cat /mnt/upassendtest/1/type
echo ''
echo 'MARK p1body'
cat /mnt/upassendtest/1/1/body
echo ''
echo 'MARK p2file'
cat /mnt/upassendtest/1/2/filename
echo ''
echo 'MARK p2body'
cat /mnt/upassendtest/1/2/body
echo ''
echo 'MARK done'
EMUSH

log="$work/out.log"
timeout 60 "$root/MacOSX/arm64/bin/emu-g" -r"$root" sh /.upassendtmp/exp.sh > "$log" 2>&1 || true
echo "===== log ====="; cat "$log"; echo "==============="

fail() { echo "UPASSEND: FAIL - $1" >&2; exit 1; }
between() { awk "/MARK $1/{f=1;next} /MARK /{f=0} f" "$log"; }

grep -q 'MARK done' "$log" || fail "did not complete"
between subject | grep -q '^Test Subject$' || fail "subject wrong"
between type | grep -q 'multipart/mixed' || fail "composed message not multipart/mixed"
between p1body | grep -q 'This is the email body' || fail "text body wrong"
between p2file | grep -q '^attach.txt$' || fail "attachment filename wrong"
between p2body | grep -q 'attachment payload here' || fail "attachment content not round-tripped (base64)"

echo 'UPASSEND: PASS - composed message with attachment round-trips through MIME (text part + base64 attachment)'
