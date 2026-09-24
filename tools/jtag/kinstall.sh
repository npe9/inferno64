#!/bin/sh
#
# Put the host's kernel8.img on the board's card and boot it.
#
#	sh tools/jtag/kinstall.sh
#
# This replaces what tools/jtag/install.sh did, because install.sh
# cannot work any more and had two independent reasons for it:
#
#  1. It waits for the BOARD's own kupdate to fetch the kernel over the
#     styx mount.  kupdate was deleted from os/inferno/init/raspi3binit.b
#     -- kuthenfat() now calls fatwrite() and nothing else -- so nothing
#     ever fetches anything and the card keeps whatever it had.
#
#  2. Its success check greps the console for "raspi3b build <stamp>".
#     The kernel prints "conf raspi3b (<stamp>) jit 0".  That string
#     appears zero times in the scrollback, so the check could never
#     succeed even if the install had worked.  Four attempts, four
#     "never came up", against a board that was fine.
#
# So the copy is driven from here through the board.cmd poller, which
# is the one channel to the board that is known to work, and the check
# looks for what the kernel actually prints.
#
# NOTHING ELSE MAY TOUCH THE CARD WHILE THIS RUNS.
#
# The order never leaves the card without a bootable kernel EXCEPT for
# the single copy in step 3, which is unavoidable: rename is the atomic
# way to do this and renaming on FAT through dossrv silently degraded to
# a copy until very recently, and the fix for that is itself inside a
# kernel that has to be installed by this script.  So: a verified copy
# is staged first, the old kernel is kept as kernel8.bak, and only then
# is kernel8.img written.  If step 3 is interrupted the card has a good
# kernel8.bak and needs a card reader or JTAG to recover.
#
set -u
HERE=`dirname "$0"`
ROOT=`cd "$HERE/../.." && pwd`
S=${S:-/private/tmp/claude-501/-Users-npe-src-inferno64-branches-raspi3b-port/2675f84d-d333-4a0e-ba1f-4ef786fc52b7/scratchpad}
CMD=$ROOT/os/inferno/raspi3b/board.cmd
OUT=$ROOT/os/inferno/raspi3b/board.out
IMG=$ROOT/os/inferno/raspi3b/kernel8.img
REMOTE=/n/remote/os/inferno/raspi3b/kernel8.img

SESS=${SESS:-`screen -ls | awk '/ttys/{print $1; exit}'`}
if [ -z "$SESS" ] || ! screen -S "$SESS" -X select . >/dev/null 2>&1; then
	echo "kinstall: no screen session on the board's console." >&2
	echo "kinstall: cannot tell whether a kernel came up; refusing to guess." >&2
	exit 3
fi

# The server the board fetches through has to answer before any of this
# means anything.
sh "$ROOT/tools/jtag/styxd.sh" || exit 1

size=`stat -f%z "$IMG"`
#
# The build stamp, read out of the image, is what identifies a kernel.
# Two builds differing only in a comment can be the same number of
# bytes, so size is not an identity.
#
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
[ -n "$stamp" ] || { echo "kinstall: cannot read the build stamp out of $IMG" >&2; exit 1; }
echo "kinstall: installing $IMG ($size bytes, build $stamp)"

#
# Run one board.cmd and wait for its end marker.
#	runcmd <marker> <seconds> <command...>
#
runcmd() {
	marker=$1; limit=$2; shift 2
	rm -f "$OUT"
	printf '%s\n' "$*" > "$CMD"
	i=0
	while [ $i -lt "$limit" ]; do
		sleep 5
		i=`expr $i + 5`
		if LC_ALL=C grep -aq "^$marker" "$OUT" 2>/dev/null; then
			return 0
		fi
		if LC_ALL=C grep -aq 'EXCEPTION' "$OUT" 2>/dev/null; then
			echo "kinstall: the board raised an exception:" >&2
			LC_ALL=C grep -av '^RCMD' "$OUT" >&2
			return 1
		fi
	done
	echo "kinstall: $marker did not appear within ${limit}s" >&2
	LC_ALL=C grep -av '^RCMD' "$OUT" >&2
	return 1
}

echo "kinstall: staging kernel8.new and verifying it"
runcmd KI-STAGED 900 "load std; cp $REMOTE /n/dos/kernel8.new; cmp $REMOTE /n/dos/kernel8.new; echo KI-STAGED" || exit 1
if LC_ALL=C grep -aq 'differ' "$OUT"; then
	echo "kinstall: the staged copy does not match the source; stopping" >&2
	exit 1
fi

echo "kinstall: keeping the current kernel as kernel8.bak"
runcmd KI-BACKED 900 "load std; cp /n/dos/kernel8.img /n/dos/kernel8.bak; cmp /n/dos/kernel8.img /n/dos/kernel8.bak; echo KI-BACKED" || exit 1

echo "kinstall: writing kernel8.img (do not interrupt)"
runcmd KI-WRITTEN 900 "load std; cp /n/dos/kernel8.new /n/dos/kernel8.img; cmp $REMOTE /n/dos/kernel8.img; echo KI-WRITTEN" || exit 1
if LC_ALL=C grep -aq 'differ' "$OUT"; then
	echo "kinstall: kernel8.img does not match the source after writing." >&2
	echo "kinstall: kernel8.bak on the card is the kernel that was working." >&2
	exit 1
fi
echo "kinstall: kernel8.img on the card matches the host's"

#
# Reboot and look for what the kernel actually prints.
#
echo "kinstall: rebooting"
screen -S "$SESS" -X stuff "$(printf '\022')" 2>/dev/null
i=0
while [ $i -lt 240 ]; do
	sleep 5
	i=`expr $i + 5`
	screen -S "$SESS" -X hardcopy -h "$S/ki-b.txt" 2>/dev/null
	if LC_ALL=C grep -aq "conf raspi3b ($stamp)" "$S/ki-b.txt" 2>/dev/null; then
		echo "kinstall: running build $stamp"
		exit 0
	fi
done
echo "kinstall: did not come up as build $stamp within ${i}s" >&2
LC_ALL=C grep -a 'conf raspi3b' "$S/ki-b.txt" 2>/dev/null | tail -1 >&2
exit 1
