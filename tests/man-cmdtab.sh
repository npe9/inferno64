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
#	named() -> bare `grep -qw'	finds 7 of 8, refuses.     CAUGHT
#	(B|BR|BI|IB|I) -> (B)		refused by fixture 2.      CAUGHT
#	[[:space:]] -> [ \t]		finds 8, runs on.          NOT caught
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
# EXIT CODES FOLLOW tests/toolchain, WHICH IS NOT THE OBVIOUS ORDER:
#
#	0	all documented
#	2	DEFECT -- gaps found in the tree
#	1	BROKE  -- the harness could not look, so no verdict
#
# It is written this way because the suite maps 2 to DEFECT and every
# other nonzero to BROKE.  The first version of this test used 1 for
# "gaps found" and 2 for "could not look", which is the intuitive
# assignment and is exactly inverted: run through the suite, a real gap in
# man/3/flash was reported as "BROKE ... could not reach its subject" and
# the summary said "0 defect(s), 1 could not run".  The finding was
# invisible in the one line a reader reads.  Verified by planting a gap
# and running the suite, not by reading the suite.
#
# NEITHER NONZERO IS A PASS, and they must stay distinguishable: a harness
# that cannot look is not a tree with no gaps.

cd "`dirname $0`/.." || exit 1   # 1 = could not look

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
# BOTH HALVES OF THE PAIR COME FROM THAT COMMIT, and that is a fix.  This
# compared the HISTORICAL page against the CURRENT devcons.c, so the
# control's answer moved whenever the command table legitimately grew: the
# V3D work added `qpuenable' and `qpuident', the count went 8 -> 10, and
# the whole test refused to run -- correctly, by its own rules, but for a
# reason that was nothing to do with the checker.  A fixture has to be
# fixed at both ends or it is not a fixture; pinning the page and reading
# the live code tests the TREE, which is what the real check below is for.
#
SELF=/tmp/man-cmdtab-self.$$
SELFC=/tmp/man-cmdtab-selfc.$$
if ! git show b2dad56f5~1:man/3/cons > $SELF 2>/dev/null; then
	echo "man-cmdtab: cannot read the known-bad page; not reporting a pass" >&2
	rm -f $SELF
	exit 1
fi
if ! git show b2dad56f5~1:os/inferno/port/devcons.c > $SELFC 2>/dev/null; then
	echo "man-cmdtab: cannot read the known-bad devcons.c; not reporting a pass" >&2
	rm -f $SELF $SELFC
	exit 1
fi
got=`gaps $SELFC $SELF | tr ' ' '\n' | grep -c .`
rm -f $SELF $SELFC
if [ "$got" -ne 8 ]; then
	echo "man-cmdtab: SELF-TEST FAILED -- found $got gaps in the known-bad" >&2
	echo "  page, expected 8 (bflag console ilock panic procdump rdb sched" >&2
	echo "  signfault).  The checker is broken, so a clean result below" >&2
	echo "  would be meaningless.  Are you running this under zsh?" >&2
	exit 1
fi

#
# SECOND SELF-TEST, and it exists because the first one cannot do this
# job.  The historical page's eight gaps are TOTAL absences -- those words
# appear under no macro at all -- so narrowing named()'s macro set from
# (B|BR|BI|IB|I) to (B) alone does not change its answer, and that
# mutation sailed through while reporting false gaps on every page that
# names a command with .BR.  Measured: it reported gaps while its
# self-test said "ok".
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
		exit 1
	fi
done
rm -f $F

echo "man-cmdtab: self-test ok (8 known cons(3) gaps; .B/.BR/.I all recognised)"

#
# COUNT THE DEVICES CHECKED, not just the gaps found.  Every pair below is
# a kernel source that exists, so a missing one means this list is stale
# or the tree is wrong -- and `|| continue' made that a SILENT PASS: the
# row for that device simply vanished from the output and the exit status
# stayed 0.  Five rows where six belong is not something a reader counts.
# A peer hit the mirror of this, exiting 1 ("I found something") from a run
# that had looked at nothing.
#
# So: a missing source refuses outright, and the number of devices actually
# reported on is asserted against the number in the list at the end.
#
rc=0
ndev=0
nwant=0
for pair in \
	"os/inferno/port/devcons.c:man/3/cons" \
	"os/inferno/port/devprog.c:man/3/prog" \
	"os/inferno/port/devusb.c:man/3/usb" \
	"os/inferno/port/devlogfs.c:man/3/logfs" \
	"os/inferno/port/devflash.c:man/3/flash" \
	"os/inferno/port/devds.c:man/3/ds"
do
	# printf, not echo: these pairs are plain paths today, but echo
	# interpreting a backslash in data is the bug that corrupted the
	# sibling test's evidence, and a path is data.
	src=`printf '%s\n' "$pair" | cut -d: -f1`
	page=`printf '%s\n' "$pair" | cut -d: -f2`
	nwant=`expr $nwant + 1`
	if [ ! -f "$src" ]; then
		echo "man-cmdtab: $src is in the list and does not exist." >&2
		echo "  The list is stale or this is the wrong tree; a device" >&2
		echo "  that was not checked must not read as a device with no" >&2
		echo "  gaps.  Not reporting a pass." >&2
		exit 1
	fi
	if [ ! -f "$page" ]; then
		echo "man-cmdtab: $src has no man page at $page"
		rc=2
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
		exit 1
	fi
	g=`gaps "$src" "$page"`
	ng=`echo $g | wc -w | tr -d ' '`
	ndev=`expr $ndev + 1`
	if [ "$ng" -eq 0 ]; then
		printf 'man-cmdtab: ok     %-14s %2d commands, all named\n' "$page" "$n"
	else
		printf 'man-cmdtab: GAP    %-14s %2d commands, %d not named: %s\n' \
			"$page" "$n" "$ng" "$g"
		rc=2
	fi
done

if [ "$ndev" -ne "$nwant" ]; then
	echo "man-cmdtab: reported on $ndev device(s) of $nwant in the list." >&2
	echo "  A device that produced no row was not checked; not reporting" >&2
	echo "  a pass." >&2
	exit 1
fi
#
# BOTH NUMBERS, not just the one.  "6 device(s) checked" requires the
# reader to already know six is right; "6 of 6 in the list" does not.
# The equality is asserted above either way, but a count that explains
# itself in the output is worth the extra word -- a peer's "ran 7 checks,
# expected 8 -- NOT a pass" is the better form and this is the same idea.
#
echo "man-cmdtab: checked $ndev of $nwant device(s) in the list"

if [ $rc -ne 0 ]; then
	echo
	echo "man-cmdtab: a page that names SOME ctl commands reads as naming"
	echo "  all of them.  Either document the command or name it as"
	echo "  undocumented -- a reader who can SEE the list is partial is in"
	echo "  a different position from one who cannot."
fi
exit $rc
