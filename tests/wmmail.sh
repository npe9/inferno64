#!/bin/sh
set -eu

# Test the wm/mail Tk client's data layer through its headless self-test
# (-t): it starts upas/fs on an mbox, reads /mail/fs, builds the message
# list, and shows a message - the same reads the GUI performs, minus the
# rendering. Verifies the list and a message body round-trip from the mbox.

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
PATH="$root/MacOSX/arm64/bin:$PATH"
export PATH
emu=${EMU:-"$root/MacOSX/arm64/bin/emu-g"}
test -x "$emu" || { echo "WMMAIL: emu not built at $emu" >&2; exit 2; }
for d in wm/mail upas/fs; do
	test -f "$root/dis/$d.dis" || { echo "WMMAIL: dis/$d.dis not built" >&2; exit 2; }
done

work="$root/.wmmailtmp"
cleanup() { rm -rf "$work" "$root/mail"; }
trap cleanup EXIT INT TERM
rm -rf "$work"; mkdir -p "$work"

MARK="wmmail-body-$$"
{
printf 'From a@x Mon Jan  1 00:00:00 2026\nFrom: Alice <a@x>\nTo: me@x\nSubject: first msg\n\n%s one\n\n' "$MARK"
printf 'From b@x Mon Jan  2 00:00:00 2026\nFrom: Bob <b@x>\nSubject: second msg\n\nbody two\n\n'
} > "$work/wm.mbox"

cat > "$root/wmtest.sh" <<'EOS'
#!/dis/sh
wm/mail -t -f /.wmmailtmp/wm.mbox
EOS
out=$(printf '\n' | timeout 40 "$emu" -r"$root" sh /wmtest.sh 2>&1) || true
rm -f "$root/wmtest.sh"
echo "===== wm/mail -t =====" ; echo "$out"

fail() { echo "WMMAIL: FAIL - $1" >&2; exit 1; }
echo "$out" | grep -q 'wm/mail: 2 message' || fail "did not list 2 messages"
echo "$out" | grep -q '1: Alice <a@x> | first msg' || fail "message 1 list line wrong"
echo "$out" | grep -q '2: Bob <b@x> | second msg' || fail "message 2 list line wrong"
echo "$out" | grep -q "body: $MARK one" || fail "message 1 body not shown from /mail/fs"

echo "WMMAIL: PASS - Tk client reads and lists the mailbox and shows a message body over /mail/fs"
