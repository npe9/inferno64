#!/bin/sh
# Drive the QEMU board's console and VERIFY what arrived.
#
#	qemufeed.sh [-d delay] [-w wait] logfile < commands
#
# Commands are read from stdin, one per line, fed to qemu.sh's console
# a character at a time, and then every one of them is checked against
# the console echo in the log.
#
# WHY THIS EXISTS.  The console corrupts input intermittently.  Seen:
# `cat /dev/v3dctl' arriving as `cat /dev/v3' -- the shell then reported
# a file nobody asked for -- and `cat /dev//v3dctl', a character
# delivered twice.  A doubled slash is harmless; a doubled digit is not.
# In
#
#	echo exec 1 1 0 1 1000 2000 >/dev/v3dctl
#
# a doubled `0' changes a timeout by a factor of ten and NOTHING SAYS
# SO.  Four QEMU boots went to console corruption before it was
# recognised as corruption at all.
#
# THE DELAY IS NOT THE FIX, and that was measured rather than assumed.
# Feeding one character at a time with -d 0.02 was the first theory; a
# control at -d 0, the rate where corruption had been seen, came back
# intact as well.  So the fault is INTERMITTENT, not rate-dependent, and
# a run that happens to be clean says nothing about the next one.  The
# delay is kept because it costs nothing and may reduce the rate, but no
# claim is made for it.
#
# What this tool is actually for is the CHECK: every command sent must
# appear VERBATIM in the log, which the console echo makes checkable.  A
# run with any mismatch is VOID -- its output is the board's answer to a
# question nobody asked -- and that is reported rather than left for a
# reader to notice.
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
trap 'rm -f "$cmds"' EXIT INT TERM
cat > "$cmds"
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

# Verify. Every non-empty command must appear verbatim in the log.
#
# QEMUFEED_SELFTEST=1 adds an expectation that was never sent, so the
# check MUST report VOID.  Without it a checker that could never fail
# would pass every run and be indistinguishable from no checker at all.
#
if [ "${QEMUFEED_SELFTEST:-0}" = 1 ]; then
	echo "this line was never sent to the board $$" >> "$cmds"
fi
bad=0
n=0
while IFS= read -r line; do
	[ -z "$line" ] && continue
	n=`expr $n + 1`
	if ! /usr/bin/grep -qF -- "$line" "$log"; then
		echo "qemufeed: CORRUPT: sent but never echoed verbatim:" >&2
		echo "    $line" >&2
		bad=`expr $bad + 1`
	fi
done < "$cmds"
if [ $bad -gt 0 ]; then
	echo "qemufeed: $bad of $n commands did not arrive intact; THIS RUN IS VOID" >&2
	exit 1
fi
echo "qemufeed: all $n commands arrived intact"
exit 0
