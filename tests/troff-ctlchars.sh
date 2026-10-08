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
scan() {	# scan <file>...; prints "file:line: text" per hit
	LC_ALL=C perl -e '
		for $f (@ARGV) {
			open F, "<", $f or next;
			$n = 0;
			while (<F>) {
				$n++;
				next unless /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/;
				s/([\x00-\x08\x0b\x0c\x0e-\x1f\x7f])/sprintf("<%02X>",ord($1))/ge;
				chomp;
				print "$f:$n: $_\n";
			}
		}
	' "$@"
}

#
# SELF-TEST, because a scanner that silently matches nothing and a clean
# tree are indistinguishable from the outside.  Two fixtures: one with the
# exact damage this test exists for, one clean.
#
T=/tmp/troff-ctl-self.$$
mkdir -p $T || exit 2
printf 'A \014(CWlibdraw/\014P line\n' > $T/bad.ms
printf 'A \\f(CWlibdraw/\\fP line\n' > $T/good.ms
nbad=`scan $T/bad.ms | grep -c .`
ngood=`scan $T/good.ms | grep -c .`
rm -rf $T
if [ "$nbad" -ne 1 ] || [ "$ngood" -ne 0 ]; then
	echo "troff-ctlchars: SELF-TEST FAILED -- known-bad gave $nbad (want 1)," >&2
	echo "  known-good gave $ngood (want 0).  The scanner is broken, so a" >&2
	echo "  clean result below would mean nothing." >&2
	exit 2
fi
echo "troff-ctlchars: self-test ok (flags the damaged line, passes the correct one)"

files=`ls doc/*.ms man/*/* 2>/dev/null`
[ -n "$files" ] || { echo "troff-ctlchars: no troff sources found" >&2; exit 2; }
hits=`scan $files`
n=`echo "$hits" | grep -c .`
if [ "$n" -eq 0 ]; then
	echo "troff-ctlchars: ok -- `echo "$files" | wc -w | tr -d ' '` sources, no control characters"
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
