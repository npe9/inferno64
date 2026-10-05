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
#
# Which screen session, found rather than remembered.
#
# This was a hardcoded session name, and when the session was killed
# and restarted every script here silently typed into nothing: screen
# -X against a dead session fails quietly, so the board looked
# unresponsive when in fact nobody was speaking to it.  Take the first
# attached session on a tty instead, and let SESS override it.
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
SESS=${SESS-`screen -ls | awk '/ttys/{print $1; exit}'`}

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
#
# No console?  Ask the kernel's own log ring over JTAG instead.
#
# The console dies far more often than the board -- the adapter wedges,
# the session gets killed, another session takes it -- and refusing to
# boot because of it is refusing to work.  kmesg reads the ring out of
# RAM over the debugger.  A freshly loaded kernel zeroes its BSS, so the
# ring holds only THIS boot's output and the stamp appearing in it at all
# is proof, with no before-and-after count needed.  That is a better test
# than the console one it replaces, which had to count banners in a
# scrollback full of previous boots.
#
VIA=console
if [ -z "$SESS" ] || ! screen -S "$SESS" -X select . >/dev/null 2>&1; then
	VIA=kmesg
	echo "boot: no console; confirming the boot over JTAG instead" >&2
else
	echo "boot: confirming the boot on console $SESS" >&2
fi
IMG=${IMG:-$ROOT/os/inferno/raspi3b/kernel8.img}
#
# ELF travels WITH IMG, and defaults beside it.
#
# Every address here comes out of the ELF's symbol table and is then read
# out of the flat image or out of the running kernel, so an ELF from one
# build and an image from another agree about nothing.  This used to read
# the stamp from $ROOT/.../kernel8.img whatever IMG said, so booting any
# other image waited for a stamp that image does not contain and reported
# "did not come up" three times over a kernel that was running fine.  The
# same hazard is in alive and where, which name the tree's ELF outright:
# if IMG is some other build, pass them the matching ELF too.
#
ELF=${ELF:-$ROOT/os/inferno/raspi3b/iraspi3b}
IFACE=${IFACE:-interface/ftdi/olimex-arm-usb-tiny-h.cfg}

stamp=`python3 - "$ROOT" "$IMG" "$ELF" <<'PYEOF'
import subprocess, sys
root, img, elf = sys.argv[1], sys.argv[2], sys.argv[3]
out = subprocess.run(["python3", root + "/tools/jtag/ksyms",
                      elf, "-g", "kerndate"],
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
[ -n "$stamp" ] || { echo "boot: no build stamp" >&2; exit 1; }

#
# Where the log ring lives, so that this script can CLEAR it before
# resuming rather than trust a count.
#
# devcons.c has "struct { Lock lk; uint n; char buf[16384]; } kmesg" and
# on this arch the Lock is 48 bytes, so n is at +48 and the text at +52
# -- which a dump of the live ring confirms: the count word reads 9967
# and "JTAG-STUB 128 bytes at 0x70000" starts four bytes later.
#
KMESG=`python3 "$ROOT/tools/jtag/ksyms" "$ELF" 2>/dev/null |
	awk '$3=="kmesg"{print $1}'`

#
# The two instruments do NOT look for the same string, and reading the
# ring for the console's banner is a check that can never pass.
#
# main.c prints "Inferno/arm64 raspi3b build <stamp>" with serialputs(),
# which writes the UART directly because it runs before there is a print
# to use.  Nothing of it reaches the kmesg ring.  The ring's first line
# is "JTAG-STUB n bytes at 0x70000" and the stamp appears in it later,
# as "conf raspi3b (<stamp>) jit N" from main()'s print().
#
# So the kmesg branch greps for the conf line.  Written the other way it
# counted 0 for a board that had booted, four times, and reported a
# working kernel as four failed attempts -- which is the same false
# failure the console check above was fixed for, reintroduced one branch
# over.  The board was answering its poller with the new build's stamp
# at the time.
#
banners() {
	if [ "$VIA" = kmesg ]; then
		#
		# The ring is this boot's only; 0 before, 1 after.  kmesg's
		# OWN failure is reported rather than swallowed: it exits 1
		# when the debugger hands back nothing and 2 when what it
		# hands back reads as an empty ring, and both used to arrive
		# here as "the board printed no banner", which is the same
		# answer as a board that did not boot.  Four attempts were
		# reported that way for a kernel that was running.
		#
		sh "$ROOT/tools/jtag/kmesg" 400 >"$S/boot.txt" 2>>"$S/boot.err"
		if [ $? -ne 0 ]; then
			sed 's/^/boot: /' "$S/boot.err" >&2
			echo 0
			return
		fi
		LC_ALL=C grep -ac "conf raspi3b ($stamp)" "$S/boot.txt" 2>/dev/null | head -1
		return
	fi
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

#
# Clearing the ring, and why a before-and-after count is not enough.
#
# "0 before, 1 after" fails in the one case this script is most often
# used for: re-booting the SAME build, because the board is wedged or
# because the kernel in RAM is the one being installed.  The ring then
# already holds that build's conf line, was=1, now=1, and the loop waits
# out all four attempts on a board that came up on the first.  That
# happened twice in a row and both times the board was answering its
# poller with the new build's stamp while this said it never came up.
#
# So the ring's count word is zeroed while the core is halted, between
# the image load and the resume.  On a good boot the kernel zeroes its
# whole BSS anyway, which makes the clear redundant; on a load that does
# not start it is the difference between "the ring is empty" and "the
# ring still has the last boot's text", and that is exactly the case the
# count was there to catch.
#
# One openocd -c is one argument, and an unquoted shell variable holding
# "-c mww ... 0" splits into four, which openocd reads as a command and
# three stray arguments.  So the address is turned into a number here and
# the command stays a single quoted word below.
#
[ -n "$KMESG" ] || { echo "boot: no kmesg symbol in the kernel" >&2; exit 1; }
nat=`printf '%d' $((KMESG + 48))`

try=1
while [ $try -le 4 ]; do
	#
	# The console's scrollback keeps every previous boot, so there it
	# is still a count that has to RISE.  The ring is cleared just
	# below, so there any occurrence at all is this boot's.
	#
	if [ "$VIA" = kmesg ]; then
		was=0
	else
		was=`banners`
	fi
	timeout 180 openocd -f "$IFACE" -f "$ROOT/tools/jtag/raspi3b.cfg" \
		-c init -c "jtagrestart $IMG" -c "mww $nat 0" -c "mdw $nat" \
		-c resume -c shutdown \
		>"$S/openocd.txt" 2>&1
	LC_ALL=C grep -i 'stub at\|Error:' "$S/openocd.txt" | head -5
	#
	# Stop on a wedged debug interface rather than retrying into it.
	#
	# DSCR.ERR=1 is sticky state in the CORE's debug logic, not in
	# the TAP, and TRST does not touch it.  The claim that nothing
	# here could clear it was wrong, and tools/jtag/unwedge is the
	# counter-example: EDRCR is memory mapped on the debug APB, so
	# "-defer-examine" plus the mem-AP writes CSE without examining
	# the core at all, and EDSCR's ERR bit goes.  That is verified.
	#
	# What is ALSO verified is that clearing the bit is not always
	# enough.  If the core itself was left unable to execute a debug
	# instruction -- which is what openocd segfaulting during
	# jtagrestart does to it -- then examine re-sets ERR immediately
	# and the next session is as wedged as the last.  The bit was the
	# symptom; the core's state is the fault, and the only thing on
	# this desk that resets the core is the power -- WHICH IS NO LONGER
	# TRUE: tools/jtag/hardreset arms the PM watchdog over JTAG and gets a
	# real firmware restart, which is what recovered a board whose wifi had
	# come up with an all-zero MAC and whose poller therefore never answered.
	# A JTAG warm restart could not clear that, because it is not a reset.
	#
	# So: clear it once and retry once, and say what the second
	# failure means.  There is no JTAG path to the PM watchdog that
	# archreboot() uses -- AP0 reaches the debug APB only, and mem-APs
	# 1, 2 and 3 answer every peripheral address with 0x00000000,
	# including the free-running system timer, which is a read that is
	# not reading.
	#
	if LC_ALL=C grep -q 'DSCR.ERR=1' "$S/openocd.txt"; then
		if [ "${unwedged:-0}" = 0 ]; then
			echo "boot: DSCR.ERR=1; clearing it and retrying once" >&2
			unwedged=1
			sh "$ROOT/tools/jtag/unwedge" >&2
			continue
		fi
		echo "boot: the debug interface is wedged (DSCR.ERR=1) and" >&2
		echo "boot: stayed wedged after EDRCR.CSE cleared it, so the" >&2
		echo "boot: CORE is stuck, not just the sticky bit." >&2
		echo "boot: this needs the Pi POWER CYCLED; not retrying." >&2
		exit 2
	fi
	#
	# The clear has to be SEEN to have landed, or this check turns a
	# false failure into a false pass.
	#
	# Presence in the ring is only proof because the ring was zeroed
	# first.  If the mww silently does not stick -- and every attempt
	# at it so far died for unrelated reasons, so "it works" was an
	# assumption -- then a load that never starts leaves the PREVIOUS
	# boot's conf line in the ring, presence matches, and this reports
	# a kernel that is not running as running.  kinstall decides
	# whether it may write the card on this answer, so that is the
	# expensive direction to be wrong in.
	#
	# So the same openocd invocation reads the word back and the value
	# must be zero.  A read-back is not a strong instrument in general
	# -- it cannot tell a write that stuck from a cache that answered
	# -- but the failure being guarded against here is openocd not
	# writing at all, which it does catch.
	#
	if [ "$VIA" = kmesg ] &&
	   ! LC_ALL=C grep -q "`printf '0x%08x' $nat`: 00000000" "$S/openocd.txt"; then
		echo "boot: the log ring was not cleared; refusing to read it" >&2
		LC_ALL=C grep -i "`printf '0x%08x' $nat`\|mww" "$S/openocd.txt" | head -3 >&2
		exit 3
	fi
	#
	# Reading the ring HALTS the core, so it is read ONCE per attempt,
	# after a whole boot, not thirty times during one.
	#
	# The console branch polls because a hardcopy of a screen session
	# costs the board nothing.  kmesg does not: it halts the core,
	# dumps 16400 bytes and resumes.  Doing that every six seconds from
	# six seconds after the resume caught the kernel in device bring-up
	# and the board never finished booting -- all thirty reads came back
	# as 16400 zero bytes, which is the ring just after BSS is cleared
	# and nothing after it, and then the board came up by itself once
	# boot.sh had given up and stopped halting it.  Four attempts of
	# that reported "never came up" for a kernel that was running by the
	# time the message was printed.
	#
	# So: one halt, after long enough for this board to reach a shell
	# with its radios up, which is about forty seconds.  Seventy-five is
	# that with room, and four attempts still cost four halts rather
	# than a hundred and twenty.
	#
	if [ "$VIA" = kmesg ]; then
		#
		# A few reads, not thirty and not one.
		#
		# Thirty halts at six-second intervals caught the kernel in
		# device bring-up; one at seventy-five seconds read a ring of
		# zeros on a board that was running, which kmesg now refuses
		# to report as content.  Six reads over two minutes is enough
		# for this board to reach a shell with its radios up and few
		# enough not to sit on the core while it does.
		#
		i=0
		while [ $i -lt 6 ]; do
			sleep 20
			now=`banners`
			if [ "$now" -gt "$was" ]; then
				echo "boot: build $stamp is running (attempt $try)"
				exit 0
			fi
			i=`expr $i + 1`
		done
		echo "boot: attempt $try did not come up"
		sh "$ROOT/tools/jtag/kmesg" 3 >/dev/null 2>&1 ||
			echo "boot: and the ring could not be read at all" >&2
		try=`expr $try + 1`
		continue
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
	#
	# The console said no.  Ask the ring before believing it.
	#
	# The console branch is chosen whenever ANY screen session on this
	# machine answers, and that session need not be the board's -- there
	# are usually three, this picks the first with a tty in its name, and
	# the board's own console has been deaf on this desk for months.  So
	# the console can report "did not come up" for a kernel that booted,
	# joined wifi, took a DHCP lease and is answering its poller, and it
	# did: four attempts in a row, while kmesg read "conf raspi3b
	# ($stamp) jit 0" out of the ring on the first try afterwards.
	#
	# The comments above already say the ring is the better instrument
	# and that a freshly loaded kernel zeroes its BSS, so presence in the
	# ring is proof without a count.  This asks it rather than leaving
	# the better instrument unused on the branch that needs it most.  It
	# can only turn a false failure into a success: a board that really
	# did not boot has nothing in its ring to find.
	#
	if LC_ALL=C sh "$ROOT/tools/jtag/kmesg" 400 2>/dev/null |
	   LC_ALL=C grep -aq "conf raspi3b ($stamp)"; then
		#
		# The wording matters: kinstall.sh greps this log for the
		# exact phrase "build <stamp> is running", so a success
		# message that says the same thing in different words is
		# read as a failure.  It was -- an install refused to touch
		# the card, saying "JTAG booted something, but not build
		# 1790780353", about a kernel this very branch had just
		# confirmed by name.  Every path that means "it booted" says
		# it the same way.
		#
		echo "boot: the console saw nothing, but the ring says" \
		     "build $stamp is running (attempt $try)"
		exit 0
	fi
	echo "boot: attempt $try did not come up"
	try=`expr $try + 1`
done
echo "boot: build $stamp never came up in 4 attempts" >&2
exit 1
