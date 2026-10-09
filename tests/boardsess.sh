#!/bin/sh
#
# boardsess - does tools/jtag/boardsess.sh name the same board in every shell?
#
#	sh tests/boardsess.sh
#
# HOST ONLY, no board, no JTAG.  It reads /dev and process tables and
# never opens a serial device.
#
# WHAT IT GUARDS, and it is one specific bug that every other test here
# was structurally unable to see.  boardtty() used to find the adapter
# with
#
#	BOARDTTYPAT='/dev/cu.PL2303G-*'
#	for d in $BOARDTTYPAT; do [ -e "$d" ] || continue; ...
#
# which relies on an UNQUOTED VARIABLE BEING GLOB-EXPANDED.  sh, bash
# and dash do that.  ZSH DOES NOT: it yields the pattern itself, so the
# loop tested a literal "/dev/cu.PL2303G-*" for existence, found none,
# and said
#
#	boardsess: no device matching /dev/cu.PL2303G-* -- is the Pi's
#	adapter plugged in?
#
# with the adapter plugged in and held by screen.  The tools all have
# #!/bin/sh so production was fine; it was found because the user's
# shell is zsh and tools/jtag/README tells people to source this file
# interactively.  `case $d in ($PAT)` does not fix it either -- zsh does
# not treat an expanded parameter as a pattern there without GLOB_SUBST,
# and that form matched 0 as well.
#
# So the property under test is not "does it work" but "DO ALL THE
# SHELLS AGREE".  A one-shell test cannot see a one-shell bug, and that
# is the general shape: when a script is sourced by whatever shell the
# reader happens to be using, the test has to run it in each of them.
#
# Exit: 0 clean, 2 the shells disagree or it names nothing with an
# adapter present, 1 could not look (no adapter, or only one shell).
#
set -u
HERE=`dirname "$0"`
ROOT=`cd "$HERE/.." && pwd`
cd "$ROOT" || exit 1

[ -f tools/jtag/boardsess.sh ] || {
	echo "boardsess: no tools/jtag/boardsess.sh -- nothing to test"
	exit 1
}

SHELLS=
for s in sh dash bash zsh; do
	command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"
done
n=0
for s in $SHELLS; do n=`expr $n + 1`; done
if [ "$n" -lt 2 ]; then
	echo "boardsess: only$SHELLS available; cannot compare shells"
	exit 1
fi

#
# Ask each shell the same two questions.  Empty answers are legitimate
# (no adapter on this machine), so what is compared is AGREEMENT, and
# the non-empty case is then additionally required to be a real device
# and a listed session.
#
bad=0
first=
firsts=
for s in $SHELLS; do
	ans=`$s -c '. ./tools/jtag/boardsess.sh; printf "%s|%s" "$(boardtty 2>/dev/null)" "$(boardsess 2>/dev/null)"' 2>/dev/null`
	printf '  %-5s %s\n' "$s" "$ans"
	if [ -z "$first" ]; then
		first=$ans
		firsts=$s
	elif [ "$ans" != "$first" ]; then
		echo "  DEFECT  $s disagrees with $firsts: '$ans' vs '$first'"
		bad=1
	fi
done

tty=`echo "$first" | awk -F'|' '{print $1}'`
sess=`echo "$first" | awk -F'|' '{print $2}'`

if [ -z "$tty" ]; then
	#
	# No adapter is not a pass.  Agreement on "nothing" cannot
	# distinguish a correct refusal from the zsh bug, which ALSO
	# produced nothing -- in one shell.  The agreement check above is
	# still meaningful (the buggy version disagreed), but the
	# positive half has not run, so this is BROKE and not clean.
	#
	echo "boardsess: the shells agree, but no adapter is present, so the"
	echo "boardsess: positive half did not run -- no verdict."
	[ "$bad" = 0 ] && exit 1
	exit 2
fi

#
# The positive half: what it named has to be real, and the session it
# named has to be one screen still lists.
#
if [ -e "$tty" ]; then
	echo "  ok      the device it names exists: $tty"
else
	echo "  DEFECT  it named $tty, which does not exist"
	bad=1
fi

if [ -n "$sess" ]; then
	if screen -ls | grep -q "^	*$sess"; then
		echo "  ok      the session it names is listed by screen: $sess"
	else
		echo "  DEFECT  it named session $sess, which screen -ls does not list"
		bad=1
	fi
else
	echo "  (a device but no session holds it; the session half not checked)"
fi

#
# And the refusals, which are the whole design: it must print NOTHING
# rather than fall back to another board.
#
r=`sh -c 'BOARDTTY=/dev/cu.definitely-not-here; . ./tools/jtag/boardsess.sh; boardsess 2>/dev/null; echo "rc=$?"'`
case $r in
rc=0) echo "  DEFECT  a nonexistent BOARDTTY was accepted"; bad=1 ;;
*)    echo "  ok      a nonexistent BOARDTTY is refused, printing nothing" ;;
esac

if [ "$bad" = 0 ]; then
	echo "boardsess: every shell names the same board, and it is real"
	exit 0
fi
echo "boardsess: THE SHELLS DO NOT AGREE, or it named something wrong"
exit 2
