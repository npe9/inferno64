#!/bin/sh
#
# Load the host's kernel over JTAG and prove THAT kernel is running.
#
#	sh tools/jtag/boot.sh
#
# jtagrestart succeeds about half the time; the other half the console
# comes up garbled and the kernel panics in chandevreset with a devtab
# full of rubbish.  The cause is not known.  What is known is that a
# retry works, so this retries -- and, more important, it refuses to
# say a kernel is up on anything but that kernel's own build stamp
# appearing AFTER a marker this script typed.
#
# Reading the screen buffer without a reference point has given a
# confident wrong answer four times in this directory, twice in one
# session: the buffer holds thousands of lines and any string worth
# grepping for is somewhere in it from a previous boot.  A stamp is not
# enough on its own -- the same build can have booted an hour ago.
#
# The reference point is a COUNT, not a typed marker.  The first
# version of this typed "echo ==MARK==" to the board and waited for
# the stamp after it, which cannot work: the marker goes to the OLD
# kernel's shell, and the reason for restarting is usually that the
# old kernel has panicked and has no shell.  Two attempts were
# declared failures while the board may well have booted.  So: count
# how many times this build's banner is already in the buffer, and
# wait for one more.  That needs nothing of the board.
#
set -u
ROOT=`cd \`dirname "$0"\`/../.. && pwd`
S=${S:-/private/tmp/claude-501/-Users-npe-src-inferno64-branches-raspi3b-port/2675f84d-d333-4a0e-ba1f-4ef786fc52b7/scratchpad}
SESS=${SESS:-37971.ttys006}
IMG=${IMG:-$ROOT/os/inferno/raspi3b/kernel8.img}
IFACE=${IFACE:-interface/ftdi/olimex-arm-usb-tiny-h.cfg}

stamp=`python3 - "$ROOT" <<'PYEOF'
import subprocess, sys
root = sys.argv[1]
out = subprocess.run(["python3", root + "/tools/jtag/ksyms",
                      root + "/os/inferno/raspi3b/iraspi3b", "-g", "kerndate"],
                     capture_output=True, text=True).stdout
addr = None
for l in out.splitlines():
    f = l.split()
    if len(f) == 3 and f[2] == "kerndate":
        addr = int(f[0], 16)
if addr is None:
    sys.exit("no kerndate symbol")
d = open(root + "/os/inferno/raspi3b/kernel8.img", "rb").read()
print(int.from_bytes(d[addr-0x80000:addr-0x80000+4], "little"))
PYEOF`
[ -n "$stamp" ] || { echo "boot: no build stamp" >&2; exit 1; }

banners() {
	screen -S "$SESS" -X hardcopy -h "$S/boot.txt" 2>/dev/null
	sleep 1
	#
	# grep -c PRINTS 0 and EXITS 1 when nothing matches, so a
	# "|| echo 0" appends a second zero and the caller sees "0\n0",
	# which [ -gt ] rejects as not an integer.  Take the count and
	# ignore the status.
	#
	LC_ALL=C grep -ac "raspi3b build $stamp" "$S/boot.txt" 2>/dev/null | head -1
}

try=1
while [ $try -le 4 ]; do
	was=`banners`
	timeout 180 openocd -f "$IFACE" -f "$ROOT/tools/jtag/raspi3b.cfg" \
		-c init -c "jtagrestart $IMG" -c resume -c shutdown \
		>"$S/openocd.txt" 2>&1
	LC_ALL=C grep -i 'stub at\|Error:' "$S/openocd.txt" | head -5
	#
	# Stop on a wedged debug interface rather than retrying into it.
	#
	# DSCR.ERR=1 is sticky state in the CORE's debug logic, not in
	# the TAP, and it survives everything reachable from here: TRST
	# resets the TAP and does not touch it, and openocd's own init
	# fails during target examine, so no command that could write
	# EDRCR.CSE ever gets to run.  It wants the board power-cycled.
	#
	# Retrying into it is worse than useless -- hammering a
	# non-responding board is how this state gets created -- and it
	# buries the one line that says what is wrong under several
	# hundred identical errors.
	#
	if LC_ALL=C grep -q 'DSCR.ERR=1' "$S/openocd.txt"; then
		echo "boot: the debug interface is wedged (DSCR.ERR=1)." >&2
		echo "boot: this needs the Pi POWER CYCLED; not retrying." >&2
		exit 2
	fi
	i=0
	while [ $i -lt 30 ]; do
		sleep 6
		now=`banners`
		if [ "$now" -gt "$was" ]; then
			echo "boot: build $stamp is running (attempt $try)"
			exit 0
		fi
		i=`expr $i + 1`
	done
	echo "boot: attempt $try did not come up"
	try=`expr $try + 1`
done
echo "boot: build $stamp never came up in 4 attempts" >&2
exit 1
