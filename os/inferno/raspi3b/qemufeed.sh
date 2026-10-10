#!/bin/sh
# Drive the QEMU board's console and VERIFY what arrived.
#
#	qemufeed.sh [-d delay] [-w wait] logfile < commands
#
# Commands are read from stdin, one per line, fed to qemu.sh's console
# a character at a time, and then every one of them is checked against
# the console echo in the log.
#
# WHY THIS EXISTS, and what it does and does not check.
#
# IT CHECKS SEQUENCING.  A step marker is fed after every command and
# each one must appear in the log; the shell consumes input in order, so
# the first missing marker is where the run stopped.  That is the failure
# that matters here: a run that dies early produces a log full of
# plausible output and answers nothing.  A V3D question was once reported
# as "timed out on the V3D read" when it had died during attach, before
# its first control ever printed.
#
# IT DOES NOT CHECK TEXT INTEGRITY, and the history of this file is why
# that is stated rather than implied.  The first version compared each
# command against its console echo verbatim and called every run of a
# 17-line script VOID; on that evidence I wrote "the QEMU console
# corrupts input" into three files.  It does not: the console
# INTERLEAVES asynchronous kernel output into the echo, mid-line and
# without a newline --
#
#	; echo enable >/dev/v3USB-KBD-NONE no keystrokes (no keyboard...)
#
# -- and that command had arrived, the status afterwards reading
# `enabled 1'.  Re-judged, those same logs were 0 corrupt.  The second
# version allowed interleaving by testing for a SUBSEQUENCE, which is
# satisfied by almost any short string in a 6000-character log, so it
# could never fail.  Both are the same error in opposite directions: a
# harness whose verdict is fixed.
#
# So input loss is UNDEMONSTRATED.  One reading, a shell error naming
# /dev/v3cat, is unexplained and is not evidence for it.  When text
# integrity matters, put the commands in board.cmd as a file, where
# nothing retypes them.
#
# The delay is not a fix for anything; it is kept because it costs
# nothing and no claim is made for it.
set -u
delay=0.02
wait=70
while [ $# -gt 0 ]; do
	case $1 in
	-d)	delay=$2; shift 2;;
	-w)	wait=$2; shift 2;;
	*)	break;;
	esac
done
if [ $# -lt 1 ]; then
	echo "usage: qemufeed.sh [-d delay] [-w wait] logfile < commands" >&2
	exit 2
fi
case $1 in
/*)	log=$1;;
*)	log=`pwd`/$1;;
esac
#
# qemu.sh names kernel8.img RELATIVELY, so it only works from its own
# directory -- run from the tree root it starts QEMU with no kernel and
# every command then "fails to arrive", which looks exactly like
# console corruption.  cd there, and make the log path absolute first.
#
here=`cd \`dirname "$0"\` && pwd`
cd "$here" || exit 1
cmds=`mktemp`
trap 'rm -f "$cmds" "$cmds.in"' EXIT INT TERM
cat > "$cmds.in"
#
# One step marker after every command.  SPLIT (`QF'-'STEP-n') so the
# console echo of the command cannot satisfy the search for its own
# output.
#
nsteps=0
: > "$cmds"
while IFS= read -r l; do
	[ -z "$l" ] && continue
	nsteps=`expr $nsteps + 1`
	printf '%s\n' "$l" >> "$cmds"
	echo "echo QF'-'STEP-$nsteps" >> "$cmds"
done < "$cmds.in"
#
# The end marker is appended here, and SPLIT so the echo of the command
# that prints it cannot satisfy the wait: the console echoes what is
# typed, so a marker that appears in its own command line is matched
# the moment it is typed rather than when it runs.
#
echo "echo QEMUFEED'-'END" >> "$cmds"

# The boot has to reach a prompt before anything is typed; feeding at
# once puts the characters in before sh exists and they are consumed by
# the boot's own console checks.
(
	sleep 18
	python3 -c '
import sys, time
delay = float(sys.argv[1])
for line in open(sys.argv[2]):
    for ch in line:
        sys.stdout.write(ch); sys.stdout.flush(); time.sleep(delay)
' "$delay" "$cmds"
	sleep 10
) | "$here/qemu.sh" > "$log" 2>&1 &
qpid=$!
i=0
while [ $i -lt "$wait" ]; do
	sleep 2
	i=`expr $i + 2`
	if grep -q 'QEMUFEED-END' "$log" 2>/dev/null; then
		break
	fi
done
kill $qpid 2>/dev/null
pkill -f qemu-system-aarch64 2>/dev/null

# Verify, in THREE states, because a contiguous match is too strict.
#
# The console interleaves asynchronous kernel output into the echo of
# what is typed, mid-line and without a newline:
#
#	; echo enable >/dev/v3USB-KBD-NONE no keystrokes (no keyboard...)
#
# That command ARRIVED -- the status afterwards read `enabled 1' -- and a
# verbatim substring test called it corrupt.  The first version of this
# tool did exactly that and reported every run of a 17-line script VOID,
# which is a harness crying wolf and is worse than no check: a tool that
# always says VOID cannot report the one run that really is.
#
# So, per command:
#
#	CLEAN        the line appears contiguously
#	INTERLEAVED  its characters appear IN ORDER but split by other
#	             output -- consistent with arriving intact, since
#	             interleaving inserts and never reorders
#	CORRUPT      not even in order; characters were lost
#
# Only CORRUPT voids the run.  A doubled character is still a
# subsequence, so this bounds LOSS and not duplication -- said here
# rather than left to be assumed.
#
# QEMUFEED_SELFTEST=1 adds an expectation that was never sent, so the
# check MUST report CORRUPT and void the run.  A checker that cannot
# fail is indistinguishable from no checker -- and this injection was
# silently DELETED when the check was rewritten from a contiguous test
# to the three-state one, which the control caught on its next run.
#
#
# QEMUFEED_SELFTEST=1 claims one more step than was ever fed, so the
# check MUST report it unreached and void the run.  A checker that
# cannot fail is indistinguishable from no checker -- and this
# injection was silently dropped once already when the check was
# rewritten, which the control caught on its next run.
#
if [ "${QEMUFEED_SELFTEST:-0}" = 1 ]; then
	nsteps=`expr $nsteps + 1`
fi
python3 "$here/qemufeedcheck.py" "$cmds" "$log" "$nsteps"
rc=$?
if [ $rc -ne 0 ]; then
	echo "qemufeed: THIS RUN IS VOID -- it did not reach every step, so its output answers less than was asked" >&2
	exit 1
fi
exit 0
