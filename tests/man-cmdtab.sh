#!/bin/sh
#
# Every ctl command a device accepts should be NAMED on the device's man
# page, and a page that names some of them reads as naming all of them.
#
# This exists because man/3/cons described four of twelve sysctl commands
# and gave no signal that the list was partial -- so panic, console, rdb,
# procdump, ilock, sched, signfault and bflag were invisible to a reader
# who had only the page.  An incomplete list that looks complete misleads
# the same way a stale status claim does: both assert something the reader
# cannot check from the page.
#
# IT IS NOT A STYLE CHECK.  It fires when a command exists in a Cmdtab and
# the page does not mention it, which is the case where a reader is
# actively misled rather than merely underserved.
#
# THE SELF-TEST IS THE POINT.  Four earlier versions of this survey each
# reported a CLEAN SWEEP over pages that had gaps, for four different
# reasons: a bare word-grep that matched "console" in ordinary prose; `$'
# inside an ERE alternation group, where it is a literal and not an
# anchor; `[ \t]' in a bracket, which in POSIX ERE means space, backslash
# or `t' and never a tab; and `for c in $cmds' under zsh, which does not
# word-split parameter expansions and so iterated ONCE over the whole
# newline-separated blob.  Every one of those failed silently in the
# direction of "nothing to report".
#
# So this runs itself against a page whose answer is known FIRST and
# refuses to report anything if it cannot reproduce it.
#
# WHAT THE SELF-TEST ACTUALLY CATCHES, measured by breaking it two ways
# rather than asserted:
#
#	named() -> bare `grep -qw'	finds 7 of 8, exit 2.      CAUGHT
#	(B|BR|BI|IB|I) -> (B)		exit 2 via fixture 2.      CAUGHT
#	[[:space:]] -> [ \t]		finds 8, exit 1.           NOT caught
#
# The middle one was NOT caught until a second fixture was added for it,
# and it had been reported as caught on the strength of the first fixture
# passing.  See the note beside that fixture.
#
# The second is honest to record: `[ \t]' matches a literal space as one
# of its three characters, and these pages happen to use a space after
# `.B' rather than a tab, so that bug is inert HERE and the self-test
# cannot see it.  It would bite a page that used a tab.  A self-test is a
# floor, not a proof -- it caught the failure mode that produced a clean
# sweep, and it does not catch everything.
#
# (It is written for sh and is safe under zsh too, because it splits only
# command substitutions, which zsh does split -- it is unquoted PARAMETER
# expansion that zsh leaves alone.  Checked, not assumed: zsh and sh give
# the same output here.)
#
# Exit 0 all documented, 1 gaps found, 2 the harness could not verify
# itself.  TWO IS NOT A PASS.

cd "`dirname $0`/.." || exit 2

#
# A command is "named" if it appears as the argument of a font macro,
# which is how these pages mark a ctl word.  A bare grep for the word is
# NOT enough -- "console" occurs throughout a page about the console
# device, and that false positive is what made the first survey report
# zero gaps on a page with eight.
#
named() {	# named <cmd> <page>
	grep -qE "^\.(B|BR|BI|IB|I)[[:space:]]+\"?${1}([[:space:]]|\"|,)" "$2" ||
	grep -qE "^\.(B|BR|BI|IB|I)[[:space:]]+\"?${1}\$" "$2"
}

#
# THE ENUM PREFIX IS NOT ALWAYS `CM'.  devds.c's table is
#
#	static Cmdtab configs[] = {
#		Fmirror,"mirror",	0,
#
# so a pattern requiring CM[A-Za-z]+ extracted ZERO of its four commands
# and this test printed "ok -- 0 commands, all named".  A false pass on a
# device with four commands, and the tell was in the output: a device with
# no commands at all is not a thing worth having a Cmdtab for.
#
cmdsof() {	# cmdsof <device .c>
	awk '/Cmdtab[A-Za-z_ ]*\[\][[:space:]]*=/{i=1} i && /^\};/{i=0} i' "$1" |
		grep -oE '[A-Za-z_][A-Za-z0-9_]*,[[:space:]]*"[a-z0-9_]+"' |
		grep -oE '"[a-z0-9_]+"' | tr -d '"' | sort -u
}

gaps() {	# gaps <device .c> <page>; prints the undocumented names
	for c in `cmdsof "$1"`; do
		named "$c" "$2" || printf '%s ' "$c"
	done
}

#
# SELF-TEST FIRST, against the commit that fixed man/3/cons.  The parent
# of b2dad56f5 is the page with eight known gaps; if this check cannot
# reproduce those eight, nothing below it can be believed.
#
SELF=/tmp/man-cmdtab-self.$$
if ! git show b2dad56f5~1:man/3/cons > $SELF 2>/dev/null; then
	echo "man-cmdtab: cannot read the known-bad page; not reporting a pass" >&2
	rm -f $SELF
	exit 2
fi
got=`gaps os/inferno/port/devcons.c $SELF | tr ' ' '\n' | grep -c .`
rm -f $SELF
if [ "$got" -ne 8 ]; then
	echo "man-cmdtab: SELF-TEST FAILED -- found $got gaps in the known-bad" >&2
	echo "  page, expected 8 (bflag console ilock panic procdump rdb sched" >&2
	echo "  signfault).  The checker is broken, so a clean result below" >&2
	echo "  would be meaningless.  Are you running this under zsh?" >&2
	exit 2
fi

#
# SECOND SELF-TEST, and it exists because the first one cannot do this
# job.  The historical page's eight gaps are TOTAL absences -- those words
# appear under no macro at all -- so narrowing named()'s macro set from
# (B|BR|BI|IB|I) to (B) alone does not change its answer, and that
# mutation sailed through while reporting false gaps on every page that
# names a command with .BR.  Measured: rc=1, self-test "ok".
#
# So this fixture names one command with .BR and one with .I and requires
# BOTH to count as present.  Remove either line and a narrowed macro set
# stops being caught.
#
F=/tmp/man-cmdtab-macro.$$
printf '.TH X 3\n.B reboot\n.BR halt ,\n.I panic\n' > $F
for c in reboot halt panic; do
	if ! named "$c" $F; then
		echo "man-cmdtab: SELF-TEST FAILED -- '$c' is named on the" >&2
		echo "  macro fixture and was not found, so the macro set is too" >&2
		echo "  narrow and gaps reported below may be false." >&2
		rm -f $F
		exit 2
	fi
done
rm -f $F

echo "man-cmdtab: self-test ok (8 known cons(3) gaps; .B/.BR/.I all recognised)"

rc=0
for pair in \
	"os/inferno/port/devcons.c:man/3/cons" \
	"os/inferno/port/devprog.c:man/3/prog" \
	"os/inferno/port/devusb.c:man/3/usb" \
	"os/inferno/port/devlogfs.c:man/3/logfs" \
	"os/inferno/port/devflash.c:man/3/flash" \
	"os/inferno/port/devds.c:man/3/ds"
do
	src=`echo "$pair" | cut -d: -f1`
	page=`echo "$pair" | cut -d: -f2`
	[ -f "$src" ] || continue
	if [ ! -f "$page" ]; then
		echo "man-cmdtab: $src has no man page at $page"
		rc=1
		continue
	fi
	n=`cmdsof "$src" | grep -c .`
	#
	# ZERO IS NOT CLEAN, IT IS SUSPICIOUS.  Every file in this list has a
	# Cmdtab, so extracting no commands from one means the extractor
	# failed, not that the device accepts nothing -- and "0 commands, all
	# named" is the most reassuring thing this test can print.  This is
	# the shape a peer named: in a defect scan where no match means clean,
	# a broken scanner is indistinguishable from a clean tree.
	#
	if [ "$n" -eq 0 ]; then
		echo "man-cmdtab: EXTRACTED NOTHING from $src, which has a" >&2
		echo "  Cmdtab -- the extractor failed.  Not reporting a pass." >&2
		exit 2
	fi
	g=`gaps "$src" "$page"`
	ng=`echo $g | wc -w | tr -d ' '`
	if [ "$ng" -eq 0 ]; then
		printf 'man-cmdtab: ok     %-14s %2d commands, all named\n' "$page" "$n"
	else
		printf 'man-cmdtab: GAP    %-14s %2d commands, %d not named: %s\n' \
			"$page" "$n" "$ng" "$g"
		rc=1
	fi
done

if [ $rc -ne 0 ]; then
	echo
	echo "man-cmdtab: a page that names SOME ctl commands reads as naming"
	echo "  all of them.  Either document the command or name it as"
	echo "  undocumented -- a reader who can SEE the list is partial is in"
	echo "  a different position from one who cannot."
fi
exit $rc
