#!/bin/sh
#
# Put the host's kernel8.img on the board's card, but only after that
# kernel has proved it boots AND that the board can still be driven.
#
#	sh tools/jtag/kinstall.sh
#
# THE CARD IS THE LAST THING THIS TOUCHES, NOT THE FIRST.
#
# The earlier version copied first and asked questions afterwards, and
# that is how a kernel that booted perfectly -- card found, FAT mounted,
# ethernet up, DHCP, DNS, an interactive shell -- but whose remote
# command poller never started got written over the only kernel that
# worked.  The board was then reachable by nothing: the console has been
# deaf on this desk for months, which is the whole reason the poller
# exists, and the poller was the thing that had died.  Recovery took
# JTAG.  Nothing about that kernel was detectable from the card write,
# because the card write succeeded.
#
# So the order here is:
#
#	1. check the image is an image at all
#	2. boot the CANDIDATE over JTAG, into RAM, touching nothing
#	3. require the board to answer a command through the poller
#	4. only now stage, back up and write the card
#	5. reboot and require the banner to appear AFTER a marker we
#	   typed, then require the poller to answer again
#
# Step 2 and 3 are the point.  A kernel that fails them leaves the card
# exactly as it was, and the board is still running whatever it was
# running, because a JTAG boot loads into RAM and the card is untouched.
#
# What this still cannot catch: the staging copy is verified with cmp
# through the candidate kernel's own SD driver, so a kernel whose reads
# and writes are broken in the same direction would verify itself.  That
# is a real hole and it is not closed here; kernel8.bak is what covers
# it.
#
# NOTHING ELSE MAY TOUCH THE CARD WHILE THIS RUNS.
#
# The write in step 4 is not atomic and cannot be: rename on FAT through
# dossrv silently degraded to a copy until recently, and the fix for
# that is itself in a kernel that has to be installed by this script.
# So a verified copy is staged first, the old kernel is kept as
# kernel8.bak, and only then is kernel8.img written.  Interrupted there,
# the card has a good kernel8.bak and needs JTAG or a card reader.
#
set -u
HERE=`dirname "$0"`
ROOT=`cd "$HERE/../.." && pwd`
#
# S HAD A HARD-CODED PATH INSIDE ONE CLAUDE SESSION'S SCRATCHPAD, and
# nothing created it.  For any other session -- or for this one after it
# ends -- that directory does not exist, so every trim wrote nothing and
# every grep read an empty file, and runcmd() would report "did not
# appear" whatever the board did.  A peer found the mirror image of this
# in their tree, where the baked-in path belonged to a session of mine.
# So: a neutral default, and mkdir it rather than assuming.
#
S=${S:-${TMPDIR:-/tmp}/inferno-raspi3b}
mkdir -p "$S" 2>/dev/null
#
# Overridable so the clash check below can be tested without a board,
# an adapter, or the real channel.  A test that can only run against the
# live board.cmd is a test nobody runs.
#
CMD=${CMD:-$ROOT/os/inferno/raspi3b/board.cmd}
OUT=${OUT:-$ROOT/os/inferno/raspi3b/board.out}
IMG=${IMG:-$ROOT/os/inferno/raspi3b/kernel8.img}
ELF=${ELF:-$ROOT/os/inferno/raspi3b/iraspi3b}
REMOTE=/n/remote/os/inferno/raspi3b/kernel8.img

#
# Leave board.cmd harmless on every exit, including the failures.
#
# board.cmd used to be left holding "echo reboot > /dev/sysctl", and
# remotecmd's "last command" memory does not survive the reboot it just
# performed: the board comes up, polls, sees a command it has no record
# of running, and reboots again.  Fifteen seconds later it does it
# again.  That loop ran for real and looked like a board rebooting by
# itself; it was only ever broken by the next thing that happened to
# write board.cmd.
#
#
# ONLY RESET THE CHANNEL IF IT STILL HOLDS WHAT WE PUT THERE.
#
# This wrote board.cmd unconditionally, and that turned the lock added
# above into a way of CAUSING the collision it exists to prevent: the
# EXIT trap was armed before the lock was taken, so a kinstall refused
# because another operation held the board ran idle() on the way out and
# overwrote the holder's command.  The guard against the clash committed
# the clash.  A peer hit the identical shape in their own tree, in the
# self-test of their clash detector, which is how I came to look.
#
# Two changes, because either alone is not enough.  The trap is now
# armed AFTER the lock is held, so a refusal has no handler and touches
# nothing -- before the lock there is nothing to clean up.  And this
# function checks the channel still holds a KI- marker of ours before
# resetting it, the way boardrun's idle() already did, so if another
# writer takes the channel mid-run the damage is not moved onto them.
#
idle() {
	if [ ! -f "$CMD" ]; then
		return
	fi
	if ! grep -q 'KI-' "$CMD" 2>/dev/null; then
		return
	fi
	printf 'load std; echo IDLE-%s\n' "`date +%s`" > "$CMD"
}
. "$HERE/boardlock.sh"

cleanup() {
	idle
	boardunlock
}

fail() {
	echo "kinstall: $*" >&2
	echo "kinstall: THE CARD WAS NOT CHANGED." >&2
	exit 1
}

# ---------------------------------------------------------------- 0

#
# One operator.  The capitals above are now enforced, because they were
# not: two of these runs overlapped and left the card with a kernel8.bak
# and a kernel8.new from different builds and a kernel8.img whose
# directory entry started at a FREE CLUSTER.  The firmware loaded
# nothing, 0x80000 held uninitialised DRAM, and the repair needed a card
# reader, a human, and a privileged fsck -- the one failure mode this
# script's whole ordering exists to prevent, arrived at from outside the
# ordering.
#
# The trap above releases the lock, and boardunlock only releases a lock
# this process holds, so the run refused here does not delete the lock
# belonging to the run it was refused in favour of.
#
boardfree || fail "another openocd is driving the adapter"
boardlock kinstall || fail "another board operation is already running"

#
# ONLY NOW is the exit handler armed.  Everything above this line has
# written nothing and holds nothing, so there is nothing to undo; and
# arming it earlier is what let a refused run overwrite the channel of
# the run it was refused in favour of.
#
trap 'cleanup' EXIT INT TERM

# ---------------------------------------------------------------- 1

[ -f "$IMG" ] || fail "no image at $IMG"
[ -f "$ELF" ] || fail "no kernel at $ELF (mk kernel8.img first)"
size=`stat -f%z "$IMG"`
[ "$size" -gt 1000000 ] || fail "$IMG is only $size bytes; that is not a kernel"
#
# The image must not be OLDER than the ELF it came from, or it is a
# stale flat image of a previous build and the stamp read below belongs
# to a kernel that is not the one just compiled.  mk normally guarantees
# this; a hand-run link does not.
#
# Not "$IMG -nt $ELF": mkrawimg.py runs in the same second as the link,
# so a correct, freshly built pair has EQUAL mtimes and -nt is strictly
# newer.  Written that way round this check rejected every good build
# and would have been deleted rather than corrected.
#
[ "$ELF" -nt "$IMG" ] && fail "$IMG is older than $ELF -- run 'mk kernel8.img'"

#
# The build stamp, read out of the image, is what identifies a kernel.
# Two builds differing only in a comment can be the same number of
# bytes, so size is not an identity.
#
stamp=`python3 - "$ROOT" "$ELF" "$IMG" <<'PYEOF'
import subprocess, sys
root, elf, img = sys.argv[1], sys.argv[2], sys.argv[3]
out = subprocess.run(["python3", root + "/tools/jtag/ksyms", elf, "-g", "kerndate"],
                     capture_output=True, text=True).stdout
addr = None
for l in out.splitlines():
    f = l.split()
    if len(f) == 3 and f[2] == "kerndate":
        addr = int(f[0], 16)
if addr is None:
    sys.exit("no kerndate symbol")
d = open(img, "rb").read()
print(int.from_bytes(d[addr-0x80000:addr-0x80000+4], "little"))
PYEOF`
[ -n "$stamp" ] || fail "cannot read the build stamp out of $IMG"

#
# A console is no longer required, and refusing without one was left
# over from when it was.
#
# This check dates from the version that decided whether a kernel had
# booted by reading the screen session's scrollback.  Nothing here does
# that any more: the pre-flight boot confirms itself over JTAG when
# there is no console, and the verdict comes from asking the BOARD for
# /dev/osversion through the poller.  Meanwhile the console on this desk
# is deaf, and its screen session has now vanished mid-session more than
# once -- so refusing to install without it means refusing to work for a
# reason that stopped applying.
#
# Say it is missing, because a live console is still the fastest way to
# watch a boot, and carry on.
#
#
# "SESS=" set and EMPTY means NO CONSOLE, which ${SESS:-...} does not
# honour: the colon form substitutes the default for an empty value as
# well as an unset one, so every attempt to say "do not use a console"
# picked the first screen session on the machine instead.  There are
# usually three, none of them necessarily the board's, and the console
# branch then hardcopies a scrollback that has nothing to do with the Pi
# and greps it for a banner that will never be there.
#
# That is four rounds of "never came up in 4 attempts" for a kernel that
# was running, chased through the ring reader, the clear, the grep pattern
# and the read-back -- none of which had run at all, because the console
# branch was taken every time.  ${SESS-...} without the colon.
#
. "$HERE/boardsess.sh"
SESS=${SESS-`boardsess`}
if [ -z "$SESS" ] || ! screen -S "$SESS" -X select . >/dev/null 2>&1; then
	echo "kinstall: no console; the board will be asked directly instead" >&2
	SESS=
fi

# The server the board fetches through has to answer before any of this
# means anything.
sh "$ROOT/tools/jtag/styxd.sh" || fail "the styx server would not start"

echo "kinstall: candidate $IMG ($size bytes, build $stamp)"

#
# Run one board.cmd and wait for its end marker.
#	runcmd <marker> <seconds> <command...>
#
#
# The end marker is appended here, not by the caller, and board.out is
# never deleted.
#
# This used to "rm -f $OUT" first and grep the whole file afterwards.
# Both halves are wrong.  The board polls on its own fifteen-second
# schedule, so the moment it creates board.out and the moment this
# script removes it are unrelated events -- that delete has already cost
# two measurements in this directory, and the post-reboot check runs
# precisely when the board is polling on its own.  And grepping the
# whole file cannot tell this run's output from the last one's, so a
# stale 'differ' or EXCEPTION would be read as this command's.
#
# Instead: a token no earlier run can have produced, and the output is
# cut down to the lines the board printed between echoing this command
# and echoing that token.
#
rcseq=0
runcmd() {
	marker=$1; limit=$2; shift 2
	rcseq=`expr $rcseq + 1`
	#
	# THE TOKEN IS SENT SPLIT, for the reason boardrun's is.  The
	# command is echoed back by the poller, so a token that appears
	# whole in both the command and the output forces every match below
	# to be anchored -- and this console interleaves prints from
	# interrupt context, so an anchor silently loses a marker that does
	# not start a line.  In THIS tool that costs more than a
	# measurement: the marker grep decides whether a step SUCCEEDED, so
	# a lost marker reports a completed copy-and-verify as a failure, in
	# the program that writes the card.
	#
	# So: 'KI'^'-DONE-...' in the command, KI-DONE-... in the output.
	# awk is given the SPLIT form, because that is what the echoed
	# command line actually contains.
	#
	tokbase=DONE-$$-$rcseq
	tok=KI-$tokbase
	cmdtok="KI'^'-$tokbase"
	printf "%s; echo 'KI'^'-%s'\n" "$*" "$tokbase" > "$CMD"
	#
	# REMEMBER WHAT WE WROTE, so that a second writer is reported as a
	# second writer.
	#
	# board.cmd is one file, one command deep, and nothing in it records
	# whose command it holds.  When another run replaces ours the poller
	# never prints our token and the loop below simply times out with
	# "did not appear", which reads as a board that has stopped
	# answering.  That happened and I believed it: a boardrun of my own
	# overwrote the marker this was waiting for and the install reported
	# "build NNN boots but its command poller never answered", which is
	# a sentence about the kernel describing a collision between two of
	# my own processes.
	#
	# The lock in step 0 stops an unrelated run from starting, and this
	# does not replace it.  Detection is not serialisation: a holder's
	# own children inherit the lock and can still write the channel, and
	# anything that writes board.cmd without going through these tools
	# is not bound by it at all.  So the check stays, and it earns its
	# place by making the REPORT accurate rather than by preventing
	# anything.
	#
	rcwrote=`cat "$CMD" 2>/dev/null`
	i=0
	while [ $i -lt "$limit" ]; do
		sleep 5
		i=`expr $i + 5`
		#
		# ...and check on every poll, not once at the end: the sooner
		# this is said the less of the timeout is spent being wrong
		# about why.
		#
		rcnow=`cat "$CMD" 2>/dev/null`
		if [ "$rcnow" != "$rcwrote" ]; then
			echo "kinstall: ANOTHER WRITER TOOK THE COMMAND CHANNEL." >&2
			echo "kinstall:   $CMD no longer holds what this step wrote." >&2
			echo "kinstall:   wanted: $rcwrote" >&2
			echo "kinstall:   found:  $rcnow" >&2
			echo "kinstall: so this step never ran, and that is a" >&2
			echo "kinstall: collision between two runs, NOT a board fault." >&2
			return 3
		fi
		[ -f "$OUT" ] || continue
		LC_ALL=C tr -cd '\11\12\40-\176' < "$OUT" > "$S/ki-out.txt" 2>/dev/null
		#
		# index(), not /^RCMD /: if the RCMD line itself does not
		# start a line this awk never sets run, ki-last.txt comes out
		# EMPTY and every check below fails -- which is fail-safe but
		# reports a working install as broken.
		#
		awk -v t="$cmdtok" '
			index($0, "RCMD ") && index($0, t) { run = 1; next }
			run { print }
		' "$S/ki-out.txt" > "$S/ki-last.txt" 2>/dev/null
		# unanchored: the command carries the SPLIT form, so the only
		# way the joined token appears here is the board printing it.
		if grep -q "$tok" "$S/ki-last.txt" 2>/dev/null; then
			#
			# The command RAN.  Whether the step SUCCEEDED is a
			# separate question, and the board answers it by
			# printing $marker as the last link of an "and"
			# chain: if any step of that chain was false the
			# marker was never reached.  The token is echoed
			# outside the chain, so it prints either way and a
			# failure costs five seconds instead of the full
			# timeout.
			#
			#
			# Unanchored, and no trailing $ either.  The old
			# pattern required the marker to be the WHOLE line,
			# so any console output sharing its line hid it.
			# The command's own copy of the marker is not in this
			# file, because awk dropped the RCMD line.
			#
			if grep -q "$marker" "$S/ki-last.txt" 2>/dev/null; then
				return 0
			fi
			echo "kinstall: the board ran the command but never reached $marker:" >&2
			cat "$S/ki-last.txt" >&2
			return 1
		fi
		if grep -q 'EXCEPTION' "$S/ki-last.txt" 2>/dev/null; then
			echo "kinstall: the board raised an exception:" >&2
			cat "$S/ki-last.txt" >&2
			return 1
		fi
	done
	echo "kinstall: $marker did not appear within ${limit}s" >&2
	cat "$S/ki-last.txt" 2>/dev/null >&2
	return 1
}

#
# SELF-TEST FOR THE CLASH CHECK, with no board, no adapter and no card.
#
#	KINSTALL_SELFTEST=1 CMD=/tmp/t/cmd OUT=/tmp/t/out S=/tmp/t sh tools/jtag/kinstall.sh
#	KINSTALL_SELFTEST=2 ...   same, without a second writer
#
# Mode 1 injects a second writer and requires runcmd to return 3 with the
# channel still holding the other writer's text.  Mode 2 is the CONTROL and
# it is not decoration: a comparison that was always unequal -- one stray
# newline between the write and the read would do it -- would report a clash
# on every step and pass mode 1 for the wrong reason.  So mode 2 requires an
# ordinary timeout with ZERO clash messages.
#
# It REFUSES to run against the real channel, and clears the exit handler
# before doing so.  A peer's version of this refusal merely exited, and the
# trap that resets board.cmd then fired on the way out -- so the guard against
# the collision committed the collision.  Every path that declines has to
# disarm the handler, not just the paths that succeed.
#
selftest() {
	if [ "$CMD" = "$ROOT/os/inferno/raspi3b/board.cmd" ]; then
		trap - EXIT INT TERM
		echo "kinstall: selftest refuses to use the real $CMD; set CMD" >&2
		return 1
	fi
	: > "$OUT"
	rc=0
	case $KINSTALL_SELFTEST in
	1)
		( sleep 6; printf 'load std; echo A-SECOND-WRITER\n' > "$CMD" ) &
		runcmd KI-NEVER 30 "load std; echo KI-NEVER"
		rc=$?
		wait
		if [ "$rc" != 3 ]; then
			echo "selftest: mode 1 wanted return 3, got $rc" >&2
			return 2
		fi
		if ! grep -q 'A-SECOND-WRITER' "$CMD" 2>/dev/null; then
			echo "selftest: mode 1 overwrote the other writer's command" >&2
			return 2
		fi
		echo "selftest: mode 1 ok -- clash detected, channel left as the other writer set it"
		return 0
		;;
	2)
		runcmd KI-NEVER 15 "load std; echo KI-NEVER"
		rc=$?
		if [ "$rc" = 3 ]; then
			echo "selftest: mode 2 reported a clash with no second writer" >&2
			return 2
		fi
		echo "selftest: mode 2 ok -- timed out with no clash reported (rc $rc)"
		return 0
		;;
	3)
		#
		# THE SUCCESS PATH, which modes 1 and 2 do not reach and which
		# matters most: if the clash comparison fired spuriously during
		# a real run, EVERY step would fail and the card would never be
		# written.  Mode 2 shows it stays quiet while polling, but only
		# a step that SUCCEEDS shows the check does not block one.
		#
		# The responder reads the token out of the channel rather than
		# being told it, because the token carries $$ and a sequence
		# number the caller cannot know in advance -- and reading it
		# back is also what proves the channel still holds our command.
		#
		( sleep 6
		  t=`sed -n "s/.*\(KI'^'-DONE-[0-9]*-[0-9]*\).*/\1/p" "$CMD"`
		  j=`echo "$t" | sed "s/KI'\^'-/KI-/"`
		  {
			printf 'RCMD 7 load std; echo KI-NEVER; echo %s\n' "$t"
			printf 'KI-NEVER\n'
			printf '%s\n' "$j"
		  } >> "$OUT"
		) &
		runcmd KI-NEVER 60 "load std; echo KI-NEVER"
		rc=$?
		wait
		if [ "$rc" != 0 ]; then
			echo "selftest: mode 3 wanted return 0, got $rc" >&2
			return 2
		fi
		echo "selftest: mode 3 ok -- a successful step is not blocked by the clash check"
		return 0
		;;
	*)
		echo "selftest: KINSTALL_SELFTEST must be 1 or 2" >&2
		return 1
		;;
	esac
}

if [ -n "${KINSTALL_SELFTEST:-}" ]; then
	selftest
	rc=$?
	trap - EXIT INT TERM
	exit $rc
fi


# ---------------------------------------------------------------- 2, 3

#
# Prove the candidate before the card sees it.
#
# KINSTALL_NOPREFLIGHT=1 skips this.  It exists for the case where JTAG
# itself is the thing being repaired, and it is the only way to install
# a kernel that has not been proved.  Using it means accepting that a
# bad kernel here costs a JTAG session or a card reader.
#
if [ "${KINSTALL_NOPREFLIGHT:-0}" = 1 ]; then
	echo "kinstall: PRE-FLIGHT SKIPPED -- this kernel is unproved"
else
	echo "kinstall: pre-flight -- booting the candidate over JTAG (card untouched)"
	IMG="$IMG" SESS="$SESS" sh "$ROOT/tools/jtag/boot.sh" >"$S/ki-pre.log" 2>&1 ||
		{ cat "$S/ki-pre.log" >&2
		  fail "the candidate did not boot over JTAG"; }
	grep -a "build $stamp is running" "$S/ki-pre.log" >/dev/null ||
		{ cat "$S/ki-pre.log" >&2
		  fail "JTAG booted something, but not build $stamp"; }
	echo "kinstall: pre-flight -- build $stamp boots"

	#
	# Booting is not enough.  The kernel that cost a JTAG recovery
	# booted.  What it could not do was answer, and answering is the
	# only way this script does anything at all, so it is the thing
	# to require.
	#
	echo "kinstall: pre-flight -- can the board still be driven?"
	runcmd KI-ALIVE 300 "load std; echo KI-ALIVE" ||
		fail "build $stamp boots but its command poller never answered"
	echo "kinstall: pre-flight -- the poller answers; the card may be written"
fi

# ---------------------------------------------------------------- 4

echo "kinstall: staging kernel8.new and verifying it"
runcmd KI-STAGED 1800 "load std; and {cp $REMOTE /n/dos/kernel8.new} {cmp $REMOTE /n/dos/kernel8.new} {echo KI-STAGED}" ||
	fail "staging failed"

echo "kinstall: keeping the current kernel as kernel8.bak"
runcmd KI-BACKED 1800 "load std; and {cp /n/dos/kernel8.img /n/dos/kernel8.bak} {cmp /n/dos/kernel8.img /n/dos/kernel8.bak} {echo KI-BACKED}" ||
	fail "could not back up the running kernel"

#
# Past this point the card no longer has a kernel this script put there
# on purpose, so "THE CARD WAS NOT CHANGED" would be a lie: fail() is
# not used below, and every message names kernel8.bak instead.
#
#
# THE OVERWRITE IS GUARDED ON THE BOARD, NOT FROM HERE.
#
# "cp a b; cmp a b" runs the cmp whether or not the cp worked, and every
# step here used to be that shape: the board ran both unconditionally
# and this script decided afterwards by reading text out of board.out.
# A missing marker and a failed step were the same observation, and the
# next destructive step went out anyway.
#
# sh-std(1) has "and", which evaluates each command until one returns
# false, and both of the commands involved report properly: cmp(1)
# raises fail:differ on a difference and fail:open if it cannot read a
# side, cp(1) counts every warning and raises fail:error at the end.  So
# the chain below is a real guard and not decoration.
#
# The order is the point.  Before kernel8.img is touched the board
# re-checks, itself, immediately beforehand, that
#
#	kernel8.bak still matches the kernel that is installed
#
# so the overwrite cannot begin unless a verified way back exists on the
# card at that moment.  That was checked in an earlier step, but by this
# script, from text, minutes ago; checking it on the board in the same
# chain as the copy is what makes it a precondition rather than a
# memory.
#
# Only that one check, and it is deliberately the LOCAL one.  Re-reading
# the host's 1.9MB kernel over the styx mount to confirm the staged copy
# is another several minutes -- measured, a single remote compare of
# this kernel took most of ten -- and KI-STAGED has already proved that
# file against the host.  The check worth repeating here is the one that
# says a way back exists, because that is what an interrupted or bad
# write costs.
#
echo "kinstall: writing kernel8.img (do not interrupt)"
if ! runcmd KI-WRITTEN 1800 "load std; and {cmp /n/dos/kernel8.img /n/dos/kernel8.bak} {cp /n/dos/kernel8.new /n/dos/kernel8.img} {cmp $REMOTE /n/dos/kernel8.img} {echo KI-WRITTEN}"; then
	echo "kinstall: the write did not finish." >&2
	echo "kinstall: kernel8.bak on the card is the kernel that was working." >&2
	exit 1
fi
echo "kinstall: kernel8.img on the card matches the host's"

# ---------------------------------------------------------------- 5

#
# Reboot THROUGH THE BOARD, not through the console.
#
# ^R is handled -- os/inferno/port/devcons.c takes 0x12 straight out of
# the console receive path and calls archreboot() -- and sending it with
# "screen -X stuff" did nothing at all, four attempts running.  The
# board prints and does not hear.  devcons also accepts
# "echo reboot >/dev/sysctl", and the poller is a shell.
#
# THE BANNER MUST APPEAR AFTER A MARKER THIS SCRIPT CAUSED.
#
# Grepping the scrollback for "conf raspi3b (<stamp>)" on its own cannot
# work now that a pre-flight JTAG boot of the SAME build has just
# printed that exact line into that exact buffer.  The check would match
# the pre-flight's banner and report a card boot that never happened --
# an instrument reading its own earlier output.  So: find the RCMD line
# for the reboot command, which only this run could have produced, and
# require the banner below it.
#
#
# ASK THE BOARD WHAT IT IS RUNNING.
#
# This used to read the console: find the RCMD line for the reboot, and
# require "conf raspi3b (<stamp>)" below it.  The reference point was
# needed because a pre-flight JTAG boot of the SAME build has already
# printed that exact line into that exact buffer, so a bare grep would
# match the pre-flight and report a card boot that never happened.
#
# But "screen -X hardcopy -h" returns about two hundred lines and a full
# boot on this board is most of that, so the reference point scrolls out
# of the buffer before the banner arrives.  Then nothing matches, and a
# board that booted perfectly is reported as "did not boot from the
# card" -- which happened, on the run that added this comment.  An
# instrument whose window is smaller than the thing it measures cannot
# be fixed by widening the timeout; waiting longer only guarantees the
# evidence is gone.
#
# devcons serves /dev/osversion as "2000 <kerndate>", so the board can
# state its own running build, over the poller, inside a command tagged
# with a token no earlier run can have produced.  That answer cannot
# come from scrollback, cannot come from the pre-flight, and does not
# depend on a buffer size at all.  It also proves drivability in the
# same breath, which is the other thing worth knowing.
#
echo "kinstall: rebooting (over the network, not the console)"
printf '%s\n' "load std; echo KI-REBOOTING; echo reboot > /dev/sysctl" > "$CMD"
#
# Put board.cmd back to harmless IMMEDIATELY, before the board is up.
# The rebooted kernel has no memory of what it last ran, so whatever is
# in board.cmd when it polls is what it does, and the reboot command
# must not be what it finds.
#
sleep 20
idle

#
# One question, asked once: is the build that was written running, and
# can the board be driven?  A single command answers both, and if the
# answer is no it is said plainly, because the next person to need this
# board will otherwise find out the hard way.
#
# 600, not 300.  The board has to finish booting, then kuthenfat has to
# finish with the card, then remotecmd's wait for an interface has to be
# satisfied -- and ETHERUSB enumeration on this board has been measured
# anywhere from 10 to 149 seconds.  300 left almost no margin against
# the slow end of that, and reporting a healthy board as JTAG-only is an
# expensive false alarm.
#
#
# The marker FIRST, and a newline after the version.
#
# /dev/osversion is served without a trailing newline, so
# "cat /dev/osversion; echo KI-UP" puts the two on one line --
# "2000 1790273432KI-UP" -- and an anchored grep for the marker finds
# nothing.  That reported a healthy board, running exactly the build
# just written, as JTAG-only.  The same merge would swallow runcmd's
# end token, which is appended after whatever this command prints.
#
if runcmd KI-UP 600 "load std; echo KI-UP; cat /dev/osversion; echo ''"; then
	if grep -q "2000 $stamp" "$S/ki-last.txt"; then
		echo "kinstall: running build $stamp from the card, poller answering"
		exit 0
	fi
	echo "kinstall: the board answers, but reports a different build:" >&2
	cat "$S/ki-last.txt" >&2
	echo "kinstall: kernel8.bak on the card is the kernel that was working." >&2
	exit 1
fi
echo "kinstall: build $stamp booted from the card but its poller does not answer." >&2
#
# Name the one cause that is known, instead of leaving it at "does not
# answer".
#
# remotecmd takes a private namespace with FORKNS and dials through it
# for the life of the boot.  Taken before ethercheck binds "#I" onto
# /net, that namespace has no /net and every poll fails with "file does
# not exist" until reboot.  It is a timing race, so a kernel can pass
# the pre-flight above -- a JTAG boot into RAM -- and still lose it
# booting from the card.  The order of these two lines says which
# happened.  By line number: this scrollback holds several boots and
# both strings are somewhere in it from previous ones.
#
screen -S "$SESS" -X hardcopy -h "$S/ki-b.txt" 2>/dev/null
LC_ALL=C tr -cd '\11\12\40-\176' < "$S/ki-b.txt" > "$S/ki-b.clean" 2>/dev/null
awk '
	/RCMD-ON/	{ on = NR }
	/ETHERBIND-OK/	{ bind = NR }
	END {
		if (on && bind && on < bind) {
			print "kinstall: RCMD-ON (line " on ") came BEFORE ETHERBIND-OK (line " bind ")."
			print "kinstall: that is the FORKNS race: the poller has no /net and never will."
			print "kinstall: expect \"RCMD-DOWN 1: dial ...: file does not exist\" on the console."
		}
	}' "$S/ki-b.clean" >&2
LC_ALL=C grep -aE 'RCMD-DOWN|RCMD-NOADDR|RCMD-OFF|RCMD-NONET' "$S/ki-b.clean" 2>/dev/null | tail -3 >&2
echo "kinstall: the board is now JTAG-only.  kernel8.bak is the previous kernel;" >&2
echo "kinstall: 'sh tools/jtag/boot.sh' with a good kernel8.img gets back in." >&2
exit 1
