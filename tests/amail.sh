#!/bin/sh
set -eu

# Test the acme mail client's data layer through its headless self-test (-t):
# it starts upas/fs on an mbox, reads /mail/fs, and formats the message list
# and a message the same way the acme windows would - without needing a
# display. Verifies the list and a message body round-trip from the mbox.
# (The acme window/event path itself needs a running acme and is not exercised
# here.)

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
PATH="$root/MacOSX/arm64/bin:$PATH"
export PATH
emu=${EMU:-"$root/MacOSX/arm64/bin/emu-g"}
test -x "$emu" || { echo "AMAIL: emu not built at $emu" >&2; exit 2; }
test -f "$root/acme/dis/amail.dis" || { echo "AMAIL: acme/dis/amail.dis not built" >&2; exit 2; }
test -f "$root/dis/upas/fs.dis" || { echo "AMAIL: dis/upas/fs.dis not built" >&2; exit 2; }

work="$root/.amailtmp"
cleanup() { rm -rf "$work" "$root/mail"; }
trap cleanup EXIT INT TERM
rm -rf "$work"; mkdir -p "$work"

MARK="amail-body-$$"
{
printf 'From a@x Mon Jan  1 00:00:00 2026\nFrom: Alice <a@x>\nTo: me@x\nSubject: acme first\n\n%s one\n\n' "$MARK"
printf 'From b@x Mon Jan  2 00:00:00 2026\nFrom: Bob <b@x>\nSubject: acme second\n\nbody two\n\n'
} > "$work/am.mbox"

cat > "$root/amtest.sh" <<'EOS'
#!/dis/sh
/acme/dis/amail.dis -t -f /.amailtmp/am.mbox
EOS
out=$(printf '\n' | timeout 40 "$emu" -r"$root" sh /amtest.sh 2>&1) || true
rm -f "$root/amtest.sh"
echo "===== amail -t ====="; echo "$out"

fail() { echo "AMAIL: FAIL - $1" >&2; exit 1; }
echo "$out" | grep -q 'amail: 2 message' || fail "did not list 2 messages"
echo "$out" | grep -qE '^1	Alice <a@x>' || fail "message 1 list line wrong"
echo "$out" | grep -qE '^2	Bob <b@x>' || fail "message 2 list line wrong"
echo "$out" | grep -q "body: $MARK one" || fail "message 1 body not shown from /mail/fs"

echo "AMAIL: PASS - acme mail client reads and formats the mailbox and a message over /mail/fs"
