#!/bin/sh
#
# No troff source should contain a C0 control character other than tab and
# newline.
#
# THIS IS THE GENERATED-TROFF FAILURE.  Writing `\f(CW' or `\fI' from a
# non-raw Python string makes Python interpret `\f' as a FORM FEED, so the
# file gets a 0x0C byte and the font escape is lost.  The text then renders
# as the literal font name:
#
#	\f(CWlibdraw/\fP	became	(CWlibdraw/P
#	\fISLOW\fP		became	ISLOWP
#
# and a page break is inserted where the form feed landed.  Found in three
# files in this tree, thirty occurrences, after a peer hit the same thing.
#
# WHY A LINT DOES NOT CATCH IT.  A stray control character is not a macro
# error.  groff emitted exactly ONE warning for twenty-four occurrences in
# doc/osprey-gap.ms -- "character with input code 12 not defined", once,
# because it dedupes per character -- sitting among unrelated warnings
# about fonts it has no business mounting.  Nothing said the document was
# damaged, and the damage is visible only in the rendered output.
#
# AND THE WARNING COUNT WENT UP WHEN THE FILES WERE FIXED, from 4 to 15,
# because the correct `\f(CW' makes groff say "cannot select font 'CW'"
# once per use under -Tascii while Plan 9 troff mounts CW happily.  So a
# warning count is the wrong dimension for this: it moves the wrong way.
# That is why this test counts BYTES in the source and not diagnostics
# from a renderer.
#
# Exit 0 clean, 1 control characters found, 2 the check could not verify
# itself.  TWO IS NOT A PASS.

cd "`dirname $0`/.." || exit 2

# Perl, not grep: this machine's grep is ugrep, which rejects the bracket
# expression below outright rather than matching it, so a grep-based
# version of this test fails to run while looking like it found nothing.
#
# `or next' WOULD SILENTLY SKIP AN UNREADABLE FILE, so this counts the
# files it actually opened and the caller checks that against the number
# it passed.  A file that cannot be read is a file that was not scanned,
# and a scan that did not happen must not read as a clean scan -- the
# same false pass that made man-cmdtab print "0 commands, all named".
# The totally-broken-perl case is already covered by the self-test below,
# which requires two hits from a fixture.
#
scan() {	# scan <file>...; prints "file:line: text" per hit, then "#scanned N"
	LC_ALL=C perl -e '
		$seen = 0;
		for $f (@ARGV) {
			open F, "<", $f or next;
			$seen++;
			$n = 0;
			while (<F>) {
				$n++;
				next unless /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/;
				s/([\x00-\x08\x0b\x0c\x0e-\x1f\x7f])/sprintf("<%02X>",ord($1))/ge;
				chomp;
				print "$f:$n: $_\n";
			}
			close F;
		}
		print "#scanned $seen\n";
	' "$@"
}

hitsonly() {	# strip the bookkeeping line
	grep -v '^#scanned '
}

scanned() {	# how many files scan() actually opened
	sed -n 's/^#scanned //p'
}

#
# SELF-TEST, because a scanner that silently matches nothing and a clean
# tree are indistinguishable from the outside.
#
# EVERY PROPERTY OF THESE FIXTURES IS LOAD-BEARING, and that is MEASURED
# by mutating the scanner rather than argued.  A fixture tidier than the
# real input tests a path the real input never takes.
#
#	scanner mutation                        self-test
#	stop after the first hit (`last')       exit 2, CAUGHT
#	count characters instead of lines       exit 2, CAUGHT
#	flag every byte above 0x7f too          exit 2, CAUGHT
#
#	bad.ms line 1	two control characters on ONE line, which must
#			count as one hit and not two
#	bad.ms line 3	a SECOND damaged line further down, so a scanner
#			that stops at the first hit is caught
#	bad.ms line 2	clean, so the two hits are not adjacent and a
#			line counter that drifts is caught
#	good.ms line 2	a legitimate UTF-8 character -- devlogfs's device
#			letter is U+029F, and man/3/logfs rightly contains
#			it.  An earlier version of this predicate counted
#			any byte outside 0x20-0x7e and so flagged that page.
#			This fixture locks the false positive out.
#
T=/tmp/troff-ctl-self.$$
mkdir -p $T || exit 2
printf 'A \014(CWlibdraw/\014P line\n' >  $T/bad.ms
printf 'an undamaged line\n'             >> $T/bad.ms
printf 'and \014ISLOW\014P here\n'       >> $T/bad.ms
printf 'A \\f(CWlibdraw/\\fP line\n'     >  $T/good.ms
printf "bind -b '#\302\237' /dev\n"      >> $T/good.ms
nbad=`scan $T/bad.ms | hitsonly | grep -c .`
ngood=`scan $T/good.ms | hitsonly | grep -c .`
badlines=`scan $T/bad.ms | hitsonly | cut -d: -f2 | tr '\n' ' '`
rm -rf $T
if [ "$nbad" -ne 2 ] || [ "$ngood" -ne 0 ] || [ "$badlines" != "1 3 " ]; then
	echo "troff-ctlchars: SELF-TEST FAILED -- known-bad gave $nbad hit(s)" >&2
	echo "  on line(s) [$badlines] (want 2 on [1 3 ]), known-good gave" >&2
	echo "  $ngood (want 0).  The scanner is broken, so a clean result" >&2
	echo "  below would mean nothing." >&2
	exit 2
fi
echo "troff-ctlchars: self-test ok (2 hits on lines 1 and 3; UTF-8 not flagged)"

#
# find, NOT `ls doc/*.ms man/*/*'.  man/lib/lookman, man/lib/man and
# man/lib/permind are DIRECTORIES, so ls recursed into them and emitted
# "man/lib/lookman:" headers plus bare filenames with no path -- six
# entries in the list that no open() could ever match.  The guard above
# caught it: 1016 passed, 1010 opened, and the earlier run that said
# "1016 sources, no control characters" had checked 1010.
#
files=`find doc man -type f \( -name '*.ms' -o -path 'man/*' \) 2>/dev/null | sort`
[ -n "$files" ] || { echo "troff-ctlchars: no troff sources found" >&2; exit 2; }
raw=`scan $files`
hits=`echo "$raw" | hitsonly`
nfiles=`echo "$files" | wc -w | tr -d ' '`
nscanned=`echo "$raw" | scanned`
if [ "$nscanned" != "$nfiles" ]; then
	echo "troff-ctlchars: passed $nfiles file(s) but only opened $nscanned." >&2
	echo "  A file that was not read was not checked; not reporting a pass." >&2
	exit 2
fi
n=`echo "$hits" | grep -c .`
if [ "$n" -eq 0 ]; then
	echo "troff-ctlchars: ok -- $nscanned sources scanned, no control characters"
	exit 0
fi
echo "troff-ctlchars: $n line(s) with a C0 control character:"
echo "$hits" | head -20
echo
echo "troff-ctlchars: <0C> before (CW, I, P, B or R is a LOST FONT ESCAPE --"
echo "  the source wanted \\f and a non-raw string ate it.  Replace each"
echo "  0x0C with the two characters backslash-f; check the RENDER, because"
echo "  the warning count moves the wrong way when this is fixed."
exit 1
