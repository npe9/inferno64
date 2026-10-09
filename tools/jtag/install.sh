#!/bin/sh
#
# Install the host's kernel onto the card and boot it.
#
#	sh tools/jtag/install.sh
#
# Two reboots.  The first runs the board's own kupdate, which fetches
# kernel8.img over the styx mount and writes it to the FAT partition;
# the second boots what it wrote.  Three to five minutes, and it never
# needs the debugger.
#
# NOTHING ELSE MAY TOUCH THE CARD WHILE kupdate RUNS.  Doing it by
# hand once went: send ^R, which starts kupdate, then type a cp of the
# same file to the same place because it was not obvious kupdate had
# already begun.  Two writers to one FAT file through one dossrv, and
# the shell hung until the next reboot.  The card survived and the
# board booted, but that is luck, not a result -- and the read-back
# that said the file was identical went through the same server that
# wrote it, which is no check at all.  So this waits, and types
# nothing in between.
#
# Why not jtagrestart, which is faster and skips the card entirely:
# because a warm restart has twice hung in schedinit() and taken the
# debugger with it, costing a power cycle each time.  jtagrestart is
# for getting a kernel into RAM when the card is not an option; this
# is for changing the kernel the board boots.
#
set -u
HERE=`dirname "$0"`
ROOT=`cd "$HERE/../.." && pwd`
# A neutral default, created rather than assumed: a path inside one
# Claude session's scratchpad does not exist for any other session, and
# every grep against a missing file reads empty.
S=${S:-${TMPDIR:-/tmp}/inferno-raspi3b}
mkdir -p "$S" 2>/dev/null
#
# Which screen session, found rather than remembered.
#
# This was a hardcoded session name, and when the session was killed
# and restarted every script here silently typed into nothing: screen
# -X against a dead session fails quietly, so the board looked
# unresponsive when in fact nobody was speaking to it.  Take the first
# attached session on a tty instead, and let SESS override it.
#
. "$HERE/boardsess.sh"
SESS=${SESS-`boardsess`}

#
# Refuse to run without a console, instead of reporting a false
# failure.
#
# This script decides whether a kernel came up by counting banners in
# the screen session's scrollback.  With no session, "screen -X
# hardcopy" fails quietly, the count stays 0, and every attempt is
# reported as "did not come up" -- a board that booted perfectly,
# recorded as four failures in a row.  That happened, and the results
# were believed for a while.  An instrument that cannot see must say
# so, not return a value.
#
if [ -z "$SESS" ] || ! screen -S "$SESS" -X select . >/dev/null 2>&1; then
	echo "boot: no screen session on the board's console." >&2
	echo "boot: cannot tell whether a kernel came up; refusing to guess." >&2
	exit 3
fi
IMG=${IMG:-$ROOT/os/inferno/raspi3b/kernel8.img}
REMOTE=${REMOTE:-/n/remote/os/inferno/raspi3b/kernel8.img}

#
# The build stamp, not the size, is what identifies a kernel.
#
# Two successive builds differing only in a comment came out the same
# number of bytes, and an install that matched "KUPDATE-OK <size>"
# found the PREVIOUS install's line and reported success without
# anything having happened.  The board then booted the old kernel and
# the test that followed measured the wrong thing.
#
# kerndate is a global in the image; ksyms finds its address and the
# value is read straight out of the file.  It is exactly what the
# boot banner prints, so the check is "did the kernel I built come
# up", which is the thing actually wanted.
#
#
# The board fetches over a styx mount to a server on this host, and
# that server wedges -- listening, accepting connections, answering no
# Styx at all.  When it does, kupdate blocks in its mount and prints
# nothing, which from the console is indistinguishable from a board
# that has hung.  Prove the server answers before believing anything
# this script reports about the board.
#
sh "$ROOT/tools/jtag/styxd.sh" || exit 1

size=`stat -f%z "$IMG"`
stamp=`python3 - "$ROOT" <<'PYEOF'
import subprocess, sys
root = sys.argv[1]
elf = root + "/os/inferno/raspi3b/iraspi3b"
img = root + "/os/inferno/raspi3b/kernel8.img"
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
if [ -z "$stamp" ]; then
	echo "install: cannot read the build stamp out of $IMG" >&2
	exit 1
fi
echo "installing $IMG ($size bytes, build $stamp)"

snap() { screen -S "$SESS" -X hardcopy -h "$1" 2>/dev/null; sleep 1; }

#
# kupdate does the copy and nothing here types while it runs; see the
# note at the top.  The loop is because kupdate starts some minutes
# after boot rather than at boot, so one reboot writes the card and
# the next one runs what was written.
#
#
# The banner stamp is the ONLY signal used.
#
# Waiting for "KUPDATE-OK" first looks sensible and is not: after a
# reboot the boot output is long, so an old KUPDATE-OK from the
# previous install is still inside any window small enough to be
# current, the wait returns immediately, and the reboot that follows
# runs the kernel that was already there.  That is the third place in
# this directory where matching a marker in a saturated console buffer
# has given a confident wrong answer.
#
# kupdate runs a few minutes after boot, so the loop is: let it run,
# reboot, look at the banner.  Nothing else is believed.
#
try=1
while [ $try -le 4 ]; do
	snap "$S/in-b.txt"
	if LC_ALL=C tail -400 "$S/in-b.txt" | \
	    LC_ALL=C grep -aq "raspi3b build $stamp"; then
		echo "  running build $stamp"
		exit 0
	fi
	echo "  attempt $try: letting kupdate run, then rebooting"
	i=0
	while [ $i -lt 50 ]; do	    # ~5 minutes for kupdate to fetch
		sleep 6
		i=`expr $i + 1`
	done
	screen -S "$SESS" -X stuff "$(printf '\022')" 2>/dev/null
	i=0
	while [ $i -lt 40 ]; do
		snap "$S/in-b.txt"
		if LC_ALL=C tail -400 "$S/in-b.txt" | \
		    LC_ALL=C grep -aq "raspi3b build $stamp"; then
			echo "  running build $stamp"
			exit 0
		fi
		sleep 5
		i=`expr $i + 1`
	done
	try=`expr $try + 1`
done
echo "  never came up as build $stamp"
LC_ALL=C grep -a 'raspi3b build' "$S/in-b.txt" | tail -1
exit 1
