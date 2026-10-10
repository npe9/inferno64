#
# One board, one operator.  Sourced, not run:
#
#	. "$HERE/boardlock.sh"
#	boardlock kinstall || exit 1
#	trap 'boardunlock' EXIT INT TERM
#
# WHY THIS EXISTS, in one sentence: kinstall.sh has said
# "NOTHING ELSE MAY TOUCH THE CARD WHILE THIS RUNS" in capitals since it
# was written, and nothing enforced it, so two kinstall runs overlapped
# and left the card holding a kernel8.bak and a kernel8.new from
# different builds and a kernel8.img whose directory entry pointed at a
# FREE CLUSTER.  The board then loaded nothing -- 0x80000 held
# uninitialised DRAM -- and the card could only be repaired from a
# reader, by a human, with a privileged fsck.  The two runs were started
# deliberately, because the guard used to decide the board was free was
# `pgrep -c openocd`, and macOS pgrep HAS NO -c FLAG: it exits 2, prints
# nothing, and `|| echo 0` turns that into the reassuring answer.  A
# guard that cannot fail closed is worse than no guard, because it is
# believed.
#
# So this file has exactly two jobs and neither of them may be done with
# a pattern match against a command line.
#
# 1. openocd, by EXECUTABLE NAME.  Eight tools in this directory start
#    openocd and it claims the FTDI adapter exclusively; a second one
#    dies with LIBUSB_ERROR_ACCESS, which reads as a dead board rather
#    than a busy one.  `ps ax -o pid,comm` gives the executable and
#    nothing else, so a shell that merely MENTIONS openocd -- including
#    the shell waiting for this very check -- cannot be mistaken for it.
#    `ps ax | grep '[o]penocd'` reported 4 for 2 processes because ps
#    WRAPS long command lines, and `-o pid,command` reported 2 when the
#    answer was 0 because it matched the watchers.  Both of those were
#    written here first and both were confidently wrong.
#
# 2. Each other, by a LOCK HOLDING A PID.  Not by ps: a run cannot
#    reliably recognise its siblings in a process listing without also
#    recognising itself, and every attempt to exclude itself by pattern
#    is a new way to be wrong.  mkdir is atomic on every filesystem that
#    matters, the pid inside says who holds it, and kill -0 says whether
#    that holder is still alive, so a run killed without its trap
#    firing leaves a lock that the next run can prove is stale instead
#    of one a human has to clear.
#
# The lock lives OUTSIDE the repository and outside any per-session
# scratchpad on purpose.  Several agents work in several worktrees of
# this tree against ONE physical Pi on one desk; a lock under a session
# directory would be private to the session that cannot cause the
# collision.  $BOARDLOCK overrides it for a second board.
#
#
# ADOPTED VERBATIM FROM raspi3b-port, AND IT MUST STAY THAT WAY.  The
# adapter is ONE physical device shared by every worktree on this
# machine, so serialisation depends on both trees using the same lock
# PATH and the same staleness rule.  Two implementations that disagree
# about when a lock is stale do not serialise -- they take turns
# believing they may proceed, which is worse than no lock because it
# looks like one.  Any change here belongs in both trees or neither.
#
BOARDLOCK=${BOARDLOCK:-/tmp/inferno-raspi3b-board.lock}

#
# Print every running openocd as "pid comm", and return 0 if there were
# any.  Callers that only want the answer redirect stdout.
#
boardopenocd() {
	_bl_n=0
	for _bl_p in `ps ax -o pid,comm | awk '$2 ~ /openocd$/ { print $1 }'`; do
		echo "$_bl_p openocd"
		_bl_n=`expr $_bl_n + 1`
	done
	[ "$_bl_n" -gt 0 ]
}

#
# Take the lock for "$1" (a name for the message the next caller sees).
# Prints why it failed and returns 1 without taking anything.
#
boardlock() {
	_bl_who=${1:-board}

	#
	# A CHILD OF THE HOLDER ALREADY HAS IT.
	#
	# kinstall.sh boots the candidate kernel by running boot.sh, and
	# efsbatch runs boot.sh once per trial.  Without this, the first
	# thing a locked kinstall would do is be refused by its own
	# pre-flight boot, and the lock meant to stop the card being
	# corrupted would stop the card being written at all.  That is
	# the shape of fix that gets deleted in frustration a week later,
	# so it is handled here rather than by leaving boot.sh unlocked.
	#
	# The test is against the pid RECORDED IN THE LOCK, not merely
	# "is BOARDLOCK_HELD set": an exported variable outlives the run
	# that set it in anything that inherits the environment, so a
	# stale BOARDLOCK_HELD must not be able to wave a later,
	# unrelated run past a lock somebody else is holding.
	#
	if [ -n "${BOARDLOCK_HELD:-}" ]; then
		_bl_pid=`awk '{print $1}' "$BOARDLOCK/held" 2>/dev/null`
		if [ "$_bl_pid" = "$BOARDLOCK_HELD" ]; then
			return 0
		fi
	fi

	if mkdir "$BOARDLOCK" 2>/dev/null; then
		echo "$$ $_bl_who `date '+%Y-%m-%d %H:%M:%S'`" > "$BOARDLOCK/held"
		BOARDLOCK_HELD=$$
		export BOARDLOCK_HELD
		return 0
	fi

	#
	# Held, or stale.  A holder whose pid is gone cannot be waited
	# for, so say so and take over; a live one is a real conflict and
	# the caller must not proceed.
	#
	_bl_held=`cat "$BOARDLOCK/held" 2>/dev/null`
	_bl_pid=`echo "$_bl_held" | awk '{print $1}'`

	if [ -n "$_bl_pid" ] && kill -0 "$_bl_pid" 2>/dev/null; then
		echo "boardlock: the board is held by: $_bl_held" >&2
		echo "boardlock: that process is ALIVE.  Wait for it or kill it;" >&2
		echo "boardlock: do not run two board operations at once." >&2
		return 1
	fi

	echo "boardlock: stale lock from ${_bl_held:-an unknown run}; taking it" >&2
	echo "$$ $_bl_who `date '+%Y-%m-%d %H:%M:%S'`" > "$BOARDLOCK/held"
	BOARDLOCK_HELD=$$
	export BOARDLOCK_HELD
	return 0
}

#
# Release, but ONLY if this process is the holder.  Without that test a
# run that failed to take the lock would delete the lock belonging to
# the run it just refused to race, which is the original bug with extra
# steps.
#
boardunlock() {
	_bl_pid=`awk '{print $1}' "$BOARDLOCK/held" 2>/dev/null`
	if [ "$_bl_pid" = "$$" ]; then
		rm -f "$BOARDLOCK/held"
		rmdir "$BOARDLOCK" 2>/dev/null
	fi
}

#
# Refuse to start if anything else is driving the adapter.  Separate
# from boardlock() because a stray openocd is not something a lock can
# fix -- it has to be reaped by hand -- and because the tools that do
# NOT write the card still want to know.
#
boardfree() {
	if boardopenocd > /dev/null; then
		echo "boardfree: openocd is already running:" >&2
		boardopenocd | sed 's/^/boardfree:   /' >&2
		echo "boardfree: it holds the FTDI adapter exclusively, so this run" >&2
		echo "boardfree: would fail with LIBUSB_ERROR_ACCESS.  Kill it by pid." >&2
		return 1
	fi
	return 0
}
