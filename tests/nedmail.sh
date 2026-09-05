#!/bin/sh
set -eu

# End-to-end test for upas/nedmail, the interactive reader, driving it over a
# real upas/fs. A three-message mbox is served; nedmail is fed a command
# script on stdin. Verifies: the mailbox is listed and messages print; a
# search address finds a message; `d' + `q' deletes through /mail/fs/ctl and
# the backing mbox is rewritten without it. Negative control: `d' + `x' (exit
# without flushing) must leave the message in place - so a pass proves the
# delete is the flush, not the mark.

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
PATH="$root/MacOSX/arm64/bin:$PATH"
export PATH
emu=${EMU:-"$root/MacOSX/arm64/bin/emu-g"}
test -x "$emu" || { echo "NEDMAIL: emu not built at $emu" >&2; exit 2; }
for d in upas/nedmail upas/fs; do
	test -f "$root/dis/$d.dis" || { echo "NEDMAIL: dis/$d.dis not built" >&2; exit 2; }
done

work="$root/.nedmailtmp"
cleanup() { rm -rf "$work" "$root/mail"; }
trap cleanup EXIT INT TERM
rm -rf "$work"; mkdir -p "$work"

makembox() {  # $1 = destination path (inside the tree, visible to emu)
	{
	printf 'From a@x Mon Jan  1 00:00:00 2026\nFrom: Alice <a@x>\nSubject: first\n\nbody one\n\n'
	printf 'From b@x Mon Jan  2 00:00:00 2026\nFrom: Bob <b@x>\nSubject: second\n\nbody two\n\n'
	printf 'From c@x Mon Jan  3 00:00:00 2026\nFrom: Carol <c@x>\nSubject: third\n\nbody three\n\n'
	} > "$1"
}

fail() { echo "NEDMAIL: FAIL - $1" >&2; exit 1; }

# --- positive: search, print, delete, flush on quit ---
makembox "$work/pos.mbox"
cat > "$work/pos.sh" <<'EOS'
#!/dis/sh
upas/nedmail -f /.nedmailtmp/pos.mbox
EOS
cp "$work/pos.sh" "$root/nedpos.sh"
pout=$(printf '/second/\np\nd\nq\n' | timeout 40 "$emu" -r"$root" sh /nedpos.sh 2>&1) || true
rm -f "$root/nedpos.sh"
echo "===== positive =====" ; echo "$pout"
echo "$pout" | grep -q '3 messages' || fail "mailbox not listed (3 messages)"
echo "$pout" | grep -q 'body two' || fail "print did not show the searched message body"
echo "$pout" | grep -q 'deleted 1 message' || fail "delete/flush did not report"
grep -q 'Subject: first' "$work/pos.mbox" || fail "survivor 'first' missing after flush"
grep -q 'Subject: third' "$work/pos.mbox" || fail "survivor 'third' missing after flush"
grep -q 'Subject: second' "$work/pos.mbox" && fail "deleted 'second' still in mbox after flush" || true
echo "NEDMAIL: search+print+delete+flush: PASS"

# --- negative control: delete then exit WITHOUT flush (x) keeps the message ---
makembox "$work/neg.mbox"
cat > "$work/neg.sh" <<'EOS'
#!/dis/sh
upas/nedmail -f /.nedmailtmp/neg.mbox
EOS
cp "$work/neg.sh" "$root/nedneg.sh"
nout=$(printf '/second/\nd\nx\n' | timeout 40 "$emu" -r"$root" sh /nedneg.sh 2>&1) || true
rm -f "$root/nedneg.sh"
if grep -q 'Subject: second' "$work/neg.mbox"; then
	echo "NEDMAIL: x (no-flush) preserves deleted message: PASS"
else
	fail "x exited but the message was removed anyway (flush happened without q)"
fi

echo "NEDMAIL: PASS - reader lists/searches/prints, and delete flushes through /mail/fs/ctl only on q"
