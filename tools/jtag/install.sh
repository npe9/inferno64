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
S=${S:-/private/tmp/claude-501/-Users-npe-src-inferno64-branches-raspi3b-port/2675f84d-d333-4a0e-ba1f-4ef786fc52b7/scratchpad}
SESS=${SESS:-37971.ttys006}
IMG=${IMG:-$ROOT/os/inferno/raspi3b/kernel8.img}
REMOTE=${REMOTE:-/n/remote/os/inferno/raspi3b/kernel8.img}

size=`stat -f%z "$IMG"`
echo "installing $IMG ($size bytes)"

snap() { screen -S "$SESS" -X hardcopy -h "$1" 2>/dev/null; sleep 1; }

# Note the ".*" in the size checks below.  ls -l puts the date between
# the size and the name --
#
#	--rw-r--r-- M 8 npe staff 1923416 Sep 21 10:36 /n/remote/...
#
# -- so "$size /n/remote" matches nothing, ever.  The first run of
# this script reported "the mount does not show 1923416 bytes" and
# printed, directly underneath, the line showing exactly that.

#
# kupdate does the copy.  Nothing here types anything while it runs.
#
# Two earlier attempts did the copy by hand, and both collided with
# kupdate doing the same copy at the same time -- two writers to one
# FAT file through one dossrv, which hung the shell until the next
# reboot.  kupdate is a board-side process on its own schedule; it
# cannot be told to stand aside, so the only safe move is to let it be
# the one writer.
#
# It is also safe to run against an unchanged build: it fetches and
# installs unconditionally, with no size or content comparison, so a
# kernel that differs only in content still lands.  It makes its own
# mount to the host and takes it down afterwards, so it does not
# depend on /n/remote being healthy either -- which matters, because
# after a dossrv panic that mount hangs and every command touching it
# blocks for ever.
#
# It runs some minutes after boot rather than at boot, which is why
# the timeout here is long.  An earlier version gave up after six
# minutes and reported "the card may already hold this build", when in
# fact kupdate simply had not started yet.
#
snap "$S/in-pre.txt"
before=`LC_ALL=C grep -ac "KUPDATE-OK $size" "$S/in-pre.txt" || true`
echo "  ^R, then waiting for kupdate (several minutes; nothing typed)"
screen -S "$SESS" -X stuff "$(printf '\022')" 2>/dev/null
i=0
while [ $i -lt 150 ]; do
	snap "$S/in-ku.txt"
	now=`LC_ALL=C grep -ac "KUPDATE-OK $size" "$S/in-ku.txt" || true`
	[ "$now" -gt "$before" ] && break
	if LC_ALL=C grep -aq 'KUPDATE-FAIL' "$S/in-ku.txt"; then
		echo "  kupdate failed:"
		LC_ALL=C grep -a 'KUPDATE-FAIL' "$S/in-ku.txt" | tail -2
		exit 1
	fi
	sleep 6
	i=`expr $i + 1`
done
if [ $i -ge 150 ]; then
	echo "  kupdate never reported KUPDATE-OK $size in 15 minutes"
	LC_ALL=C grep -a 'KUPDATE' "$S/in-ku.txt" | tail -3
	exit 1
fi
echo "  written to the card, $size bytes"

snap "$S/in-mid.txt"
before=`LC_ALL=C grep -ac 'raspi3b build' "$S/in-mid.txt" || true`
echo "  ^R: booting it"
screen -S "$SESS" -X stuff "$(printf '\022')" 2>/dev/null
i=0
while [ $i -lt 40 ]; do
	snap "$S/in-boot.txt"
	now=`LC_ALL=C grep -ac 'raspi3b build' "$S/in-boot.txt" || true`
	if [ "$now" -gt "$before" ]; then
		LC_ALL=C grep -a 'raspi3b build' "$S/in-boot.txt" | tail -1
		exit 0
	fi
	sleep 5
	i=`expr $i + 1`
done
echo "  board did not come back"
exit 1
