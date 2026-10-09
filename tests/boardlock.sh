#!/bin/sh
#
# boardlock - does tools/jtag/boardlock.sh actually refuse a second operator?
#
#	sh tests/boardlock.sh
#
# HOST ONLY, no board, no JTAG, no adapter.  Not part of tests/toolchain:
# that suite is chartered as "every regression test for a kencc defect",
# and this is not one.
#
# WHAT IT GUARDS.  The card in the Pi was corrupted by two kinstall runs
# overlapping -- kernel8.bak and kernel8.new from different builds and a
# kernel8.img whose directory entry started at a FREE CLUSTER, so the
# firmware loaded nothing and 0x80000 held uninitialised DRAM.  They
# overlapped because the guard in use was `pgrep -c openocd`, and macOS
# pgrep HAS NO -c FLAG: exit 2, no output, and `|| echo 0` made that the
# reassuring answer.  Three replacement guards were then written and all
# three were wrong (`ps ax` wraps long command lines and counted 4 for 2
# processes; `-o pid,command` matched the shells watching FOR openocd and
# counted 2 when the answer was 0).
#
# So the thing under test is a guard, and the only way a guard earns
# trust is by being SHOWN A CASE IT MUST CATCH.  Four of the checks here
# are positive controls: a lock held by a live process, a lock held by a
# dead one, a release attempted by a non-holder, and -- the one that
# matters -- a real running process whose executable name is openocd.
#
# TWO TRAPS THIS TEST FELL INTO FIRST, both of which made it pass while
# testing nothing:
#
#   A COPIED BINARY IS KILLED.  The control was `cp /bin/sleep openocd`.
#   On macOS a copy of a system binary loses its code signature and is
#   SIGKILLed on exec ("Killed: 9"), so the control process was never
#   alive, boardopenocd correctly found nothing, and the check reported
#   the guard broken when the guard was fine.  The control has to be a
#   binary compiled here, which gets an ad-hoc signature.
#
#   `$$` IN A SUBSHELL IS THE PARENT'S PID.  The non-holder check was
#   `( . boardlock.sh; boardunlock )`, which is the SAME $$ and so was
#   the holder; it released the lock and the check called that a bug.  A
#   second operator has to be a second process -- `sh -c` -- or the test
#   is asking one process whether it is two.
#
# Exit: 0 clean, 2 the guard does not guard, 1 could not look.
#
set -u
HERE=`dirname "$0"`
ROOT=`cd "$HERE/.." && pwd`
cd "$ROOT" || exit 1

[ -f tools/jtag/boardlock.sh ] || {
	echo "boardlock: no tools/jtag/boardlock.sh -- nothing to test"
	exit 1
}

WORK=`mktemp -d /tmp/boardlock-test.XXXXXX` || exit 1
trap 'rm -rf "$WORK"' EXIT INT TERM

BOARDLOCK=$WORK/lock
export BOARDLOCK

. ./tools/jtag/boardlock.sh

bad=0
ck() {
	if [ "$2" = "$3" ]; then
		echo "  ok      $1"
	else
		echo "  DEFECT  $1: got '$2', want '$3'"
		bad=1
	fi
}

# ------------------------------------------------------------ the lock

boardlock kinstall >/dev/null 2>&1
ck "a free lock is taken" "$?" 0
ck "the holder recorded is us" "`awk '{print $1}' \"$BOARDLOCK/held\" 2>/dev/null`" "$$"

#
# A LIVE holder must refuse an UNRELATED second operator.  Three things
# about how this is written, each of which was wrong first:
#
#   sh -c, not ( ): `$$` inside a subshell is the PARENT's pid, so the
#   subshell is the holder and releases the lock quite correctly, and
#   the check then calls that a bug.
#
#   env -u BOARDLOCK_HELD, because a plain child INHERITS the holder's
#   exported pid and is let through on purpose -- kinstall runs boot.sh.
#   Without the -u this check tested the inheritance rule and reported
#   it as a failure to guard, which is how it read the first time.
#
#   and the inheritance it would have hidden is checked on its own
#   below, in both directions.
#
rc=`env -u BOARDLOCK_HELD sh -c '. ./tools/jtag/boardlock.sh; boardlock other >/dev/null 2>&1; echo $?'`
ck "an unrelated second operator is REFUSED while the holder lives" "$rc" 1
ck "the refused operator did not steal the lock" "`awk '{print $1}' \"$BOARDLOCK/held\" 2>/dev/null`" "$$"

#
# A CHILD of the holder must be let through, or kinstall's own
# pre-flight boot is the first thing its lock refuses.
#
rc=`sh -c '. ./tools/jtag/boardlock.sh; boardlock child >/dev/null 2>&1; echo $?'`
ck "a child of the holder inherits the lock" "$rc" 0
ck "the child did not take the lock for itself" "`awk '{print $1}' \"$BOARDLOCK/held\" 2>/dev/null`" "$$"

#
# ...but a STALE inherited pid must not open the door.  An exported
# variable outlives the run that set it, so a later unrelated run can
# carry a BOARDLOCK_HELD that matches nothing; if "is it set" were the
# test, that run would walk past a lock somebody else holds.
#
rc=`BOARDLOCK_HELD=99999 sh -c '. ./tools/jtag/boardlock.sh; boardlock stale >/dev/null 2>&1; echo $?'`
ck "a BOARDLOCK_HELD that does not match the lock is REFUSED" "$rc" 1

#
# ...and must not release it either.  Without the holder test in
# boardunlock, the run that was just refused deletes the lock of the run
# it refused to race, which is the original bug with extra steps.
#
sh -c '. ./tools/jtag/boardlock.sh; boardunlock' >/dev/null 2>&1
ck "a non-holder cannot release the lock" "`awk '{print $1}' \"$BOARDLOCK/held\" 2>/dev/null`" "$$"

boardunlock
ck "the holder can release it" "`[ -e \"$BOARDLOCK/held\" ] && echo present || echo gone`" gone

#
# A lock whose holder is GONE has to be takeable, or one killed run
# needs a human before the board can be used again.  99999 is checked
# to be dead rather than assumed: a live pid there would invert this.
#
if kill -0 99999 2>/dev/null; then
	echo "  (pid 99999 exists; skipping the stale-lock check)"
else
	mkdir -p "$BOARDLOCK"
	echo "99999 ghost 2026-01-01 00:00:00" > "$BOARDLOCK/held"
	boardlock kinstall >/dev/null 2>&1
	ck "a stale lock is taken over" "$?" 0
	ck "and we hold it afterwards" "`awk '{print $1}' \"$BOARDLOCK/held\" 2>/dev/null`" "$$"
	boardunlock
fi

# ------------------------------------------- openocd, by executable name

#
# The positive control.  A compiled binary, because a copy of a system
# binary is SIGKILLed; and its liveness is CHECKED, because a control
# that died makes a working guard look broken.
#
mkdir -p "$WORK/bin"
printf '#include <unistd.h>\nint main(void){ for(;;) sleep(1); return 0; }\n' > "$WORK/f.c"
if cc -w -o "$WORK/bin/openocd" "$WORK/f.c" 2>/dev/null; then
	ck "no openocd is reported when none runs" "`boardopenocd >/dev/null 2>&1; echo $?`" 1
	ck "boardfree allows a run when none is up" "`boardfree >/dev/null 2>&1; echo $?`" 0

	"$WORK/bin/openocd" &
	pid=$!
	sleep 1
	if kill -0 "$pid" 2>/dev/null; then
		ck "a running openocd IS seen" "`boardopenocd >/dev/null 2>&1; echo $?`" 0
		ck "boardfree refuses a run while it is up" "`boardfree >/dev/null 2>&1; echo $?`" 1
		ck "it is reported by pid" "`boardopenocd | awk '$1 == '\"$pid\"' { print \"found\" }'`" found
	else
		echo "  (the control process did not stay alive; openocd checks skipped)"
	fi
	kill "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
else
	echo "  (no working cc; the openocd control was not built, checks skipped)"
fi

if [ "$bad" = 0 ]; then
	echo "boardlock: the guard refuses a second operator and sees a live openocd"
	exit 0
fi
echo "boardlock: THE GUARD DOES NOT GUARD -- see the DEFECT lines above"
exit 2
