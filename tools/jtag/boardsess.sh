#
# Which screen session is the PI's console?  Sourced, not run:
#
#	. "$HERE/boardsess.sh"
#	SESS=${SESS-`boardsess`}
#
# ${SESS-...} WITHOUT THE COLON, in every caller.  "SESS=" set and empty
# means "no console, confirm the boot another way", and the colon form
# substitutes the default for an empty value as well as an unset one, so
# every attempt to say "do not use a console" picked a session instead.
#
# WHAT THIS REPLACES, and why it is not a style change:
#
#	SESS=${SESS-`screen -ls | awk '/ttys/{print $1; exit}'`}
#
# Six files had that line.  It means "the first screen session on a
# tty", which is not a description of the Pi -- it is a description of
# whatever screen happened to start first.  On this desk right now:
#
#	19277  cu.usbserial-2234301      a SiFive HiFive Unmatched, sitting
#	                                 at U-Boot "=>" prompts
#	32543  cu.PL2303G-USBtoUART223420  THE PI
#	80649  cu.PL2303-USBtoUART22430    an xip radio bench board
#	17858  cu.usbserial-AQ02DK34       the other end of that bench
#
# The awk returns 19277.  So a whole session's board work read the
# SiFive's scrollback: tools reported "the console saw nothing" while
# the kernel's own log ring said the build was running, and that
# contradiction was chased through the ring reader, the clear, the grep
# pattern and the read-back before anyone checked WHICH CONSOLE.  Four
# "never came up in 4 attempts" verdicts came from it, for a kernel that
# had booted.  The sessions were identified above by their CONTENT --
# "=>" for U-Boot, "usbdwc:" for the Pi's USB driver, "styx: ... off the
# air" for the radio bench -- not by their names or their order.
#
# TWO RULES THIS FILE EXISTS TO KEEP.
#
# NEVER OPEN THE DEVICE.  screen owns the Pi's serial port; a second
# opener wedges the PL2303 so the board prints but cannot hear, and only
# unplugging the USB fixes it, which needs a human at the desk.  lsof is
# used below to ask the KERNEL who holds a device; it stats the path and
# reads process tables, it does not open it.  Nothing here may be
# changed into something that does.
#
# RETURN NOTHING RATHER THAN SOMETHING ELSE.  If the Pi's adapter is not
# there, or no screen session holds it, this prints nothing and says why
# on stderr.  It does NOT fall back to another session: typing a reboot
# into a neighbouring board is worse than every failure it could avoid,
# and boot.sh's no-console path -- reading the kernel's log ring over
# JTAG -- is a better instrument than the console one anyway, because a
# freshly loaded kernel zeroes its BSS and the ring holds only this
# boot.
#
# $BOARDTTY names the device outright.  $BOARDTTYPAT is the glob used to
# find it, and defaults to this desk's Pi adapter: a Prolific PL2303G,
# which is a different model from the plain PL2303 on the radio bench,
# so the "G" is doing real work in that pattern.  Replug the adapter
# into another port and the serial-number suffix stays, because it comes
# from the adapter.
#
BOARDTTYPAT=${BOARDTTYPAT:-'/dev/cu.PL2303G-*'}

#
# Print the Pi's serial device, or nothing.
#
boardtty() {
	if [ -n "${BOARDTTY:-}" ]; then
		if [ -e "$BOARDTTY" ]; then
			echo "$BOARDTTY"
			return 0
		fi
		echo "boardsess: BOARDTTY=$BOARDTTY does not exist" >&2
		return 1
	fi

	_bs_n=0
	for _bs_d in $BOARDTTYPAT; do
		[ -e "$_bs_d" ] || continue
		_bs_found=$_bs_d
		_bs_n=`expr $_bs_n + 1`
	done

	if [ "$_bs_n" = 0 ]; then
		echo "boardsess: no device matching $BOARDTTYPAT -- is the Pi's adapter plugged in?" >&2
		return 1
	fi
	#
	# More than one match is ambiguous and must not be resolved by
	# picking one, which is the entire bug being fixed here.
	#
	if [ "$_bs_n" -gt 1 ]; then
		echo "boardsess: $_bs_n devices match $BOARDTTYPAT; set BOARDTTY to choose" >&2
		return 1
	fi
	echo "$_bs_found"
}

#
# Print the screen session holding the Pi's console, or nothing.
#
boardsess() {
	_bs_tty=`boardtty` || return 1

	#
	# Who holds it.  A device can be held by something that is not
	# screen -- a stray cat, another tool -- and that is worth saying
	# plainly, because it is also the thing that wedges the adapter.
	#
	_bs_pid=`lsof "$_bs_tty" 2>/dev/null | awk 'NR>1 && $1 == "screen" { print $2; exit }'`
	if [ -z "$_bs_pid" ]; then
		_bs_other=`lsof "$_bs_tty" 2>/dev/null | awk 'NR>1 { print $1"("$2")" }' | tr '\n' ' '`
		if [ -n "$_bs_other" ]; then
			echo "boardsess: $_bs_tty is held by $_bs_other, not screen" >&2
		else
			echo "boardsess: nothing holds $_bs_tty -- no console session for the Pi" >&2
		fi
		return 1
	fi

	#
	# ...and it has to be a session screen itself still lists, or
	# every -X against it fails quietly, which is how a dead session
	# made the board look unresponsive.  The FULL name is printed,
	# not the pid: screen -S takes a prefix, and a bare pid would
	# match a session whose name merely starts with those digits.
	#
	_bs_name=`screen -ls | awk -v p="$_bs_pid" '$1 ~ "^"p"\\\\." { print $1; exit }'`
	if [ -z "$_bs_name" ]; then
		echo "boardsess: screen pid $_bs_pid holds $_bs_tty but screen -ls does not list it" >&2
		return 1
	fi
	echo "$_bs_name"
}
