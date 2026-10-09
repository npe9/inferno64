#!/bin/sh
#
# kinstall-clash - does kinstall.sh notice a second writer on board.cmd?
#
#	sh tests/kinstall-clash.sh
#
# HOST ONLY: no board, no adapter, no card, and it refuses to touch the
# real channel.  That is the point -- the check it exercises exists for a
# failure that only happens when two runs overlap, which is exactly the
# situation nobody can arrange on demand against real hardware.
#
# WHAT IT GUARDS.  os/inferno/raspi3b/board.cmd is one file, one command
# deep, with nothing in it recording whose command it holds.  When a
# second writer replaces a step's command the poller never prints that
# step's token, and kinstall used to simply time out:
#
#	kinstall: KI-ALIVE did not appear within 300s
#	kinstall: build 1791548940 boots but its command poller never answered
#
# which is a sentence about the kernel describing a collision between two
# of my own processes.  I believed it.  runcmd() now remembers what it
# wrote, checks it on every poll, and names both commands on a mismatch.
#
# THE THREE MODES, and the second is the one that makes the first mean
# anything:
#
#   1  a second writer is injected -> runcmd must return 3, and must
#      leave the channel holding the OTHER writer's text rather than
#      moving the damage onto them.
#   2  no second writer -> an ordinary timeout with ZERO clash reports.
#      A comparison that was always unequal (one stray newline between
#      the write and the read would do it) would report a clash on every
#      step and would pass mode 1 for the wrong reason.
#   3  a successful step -> return 0.  Modes 1 and 2 never reach the
#      success path, and that is the one that matters most: a clash
#      check firing spuriously would fail every step and the card would
#      never be written at all.
#
# AND THE REFUSAL PATH IS CHECKED TOO, because a guard that damages what
# it guards is worse than none.  A peer's version of this self-test
# refused to use the real board.cmd by exiting -- and the EXIT trap that
# resets board.cmd then fired on the way out, so the guard against the
# collision committed the collision.  This asserts the real channel is
# byte-identical after a refusal.
#
# Exit: 0 clean, 2 the check does not work, 1 could not look.
#
set -u
HERE=`dirname "$0"`
ROOT=`cd "$HERE/.." && pwd`
cd "$ROOT" || exit 1

[ -f tools/jtag/kinstall.sh ] || {
	echo "kinstall-clash: no tools/jtag/kinstall.sh"
	exit 1
}
grep -q 'KINSTALL_SELFTEST' tools/jtag/kinstall.sh || {
	echo "kinstall-clash: this kinstall.sh has no self-test; nothing to run"
	exit 1
}

W=`mktemp -d /tmp/kinstall-clash.XXXXXX` || exit 1
trap 'rm -rf "$W"' EXIT INT TERM

#
# A private lock, so a real board operation elsewhere is neither
# disturbed nor able to make this fail.
#
BOARDLOCK=$W/lock
export BOARDLOCK

REAL=$ROOT/os/inferno/raspi3b/board.cmd
bad=0

ck() {
	if [ "$2" = "$3" ]; then
		echo "  ok      $1"
	else
		echo "  DEFECT  $1: got '$2', want '$3'"
		bad=1
	fi
}

for m in 1 2 3; do
	rm -f "$W/cmd" "$W/out"
	KINSTALL_SELFTEST=$m CMD=$W/cmd OUT=$W/out S=$W \
		sh tools/jtag/kinstall.sh > "$W/m$m.log" 2>&1
	rc=$?
	ck "self-test mode $m exits 0" "$rc" 0
	if ! grep -q "selftest: mode $m ok" "$W/m$m.log"; then
		echo "  DEFECT  mode $m did not report ok; its output was:"
		sed 's/^/            /' "$W/m$m.log" | head -6
		bad=1
	fi
done

#
# Mode 2 must be SILENT about clashes, not merely non-fatal.
#
#
# NOT `grep -c ... || echo 0'.  BSD grep -c EXITS 1 on a correct count of
# zero, so the fallback runs as well and $n becomes the two lines "0" and
# "0" -- which is what this check first reported, against working code.
# This tree has that written down and I walked into it anyway.  grep -c
# into a file and read it, so nothing can append a second answer.
#
grep -c 'ANOTHER WRITER' "$W/m2.log" > "$W/n2" 2>/dev/null
n=`cat "$W/n2"`
ck "mode 2 reports no clash (the control)" "$n" 0

#
# ...and mode 1 must have said so, or mode 2's silence proves nothing.
#
grep -c 'ANOTHER WRITER' "$W/m1.log" > "$W/n1" 2>/dev/null
n=`cat "$W/n1"`
if [ "${n:-0}" -lt 1 ]; then
	echo "  DEFECT  mode 1 detected the clash without reporting it"
	bad=1
else
	echo "  ok      mode 1 names the clash"
fi
for want in 'wanted:' 'found:'; do
	if grep -q "$want" "$W/m1.log"; then
		echo "  ok      mode 1 prints '$want'"
	else
		echo "  DEFECT  mode 1 does not print '$want'"
		bad=1
	fi
done

# ------------------------------------------- the refusal must not write

if [ -f "$REAL" ]; then
	b=`cksum < "$REAL"`
	KINSTALL_SELFTEST=1 sh tools/jtag/kinstall.sh > "$W/refuse.log" 2>&1
	rc=$?
	a=`cksum < "$REAL"`
	ck "a self-test against the real channel is refused" "$rc" 1
	ck "and the real board.cmd is byte-identical after it" "$a" "$b"
else
	echo "  (no $REAL; the refusal check did not run)"
fi

if [ "$bad" = 0 ]; then
	echo "kinstall-clash: a second writer is detected, named, and not overwritten"
	exit 0
fi
echo "kinstall-clash: THE CLASH CHECK DOES NOT WORK -- see the DEFECT lines"
exit 2
