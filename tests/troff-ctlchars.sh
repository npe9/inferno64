#!/bin/sh
# Find stray control characters in troff source.
#
# A lost font escape is the usual cause: "\fI" written inside a
# non-raw Python string (or any language where \f is an escape)
# becomes a single 0x0C byte, and the page then renders "IemuP"
# instead of italic "emu".
#
# THIS SCANS SOURCE BYTES AND NEVER A RENDERER'S DIAGNOSTICS, because
# the renderer is not a usable signal for this defect:
#
#   - groff -man -Tutf8 -k -ww over man/1/sh-plot with 19 form feeds
#     in it emitted ZERO warnings. Not few: none.
#   - where groff does warn ("character with input code 12 not
#     defined") it dedupes per character code, so 24 occurrences give
#     ONE line, at 1-for-24 strength, among unrelated font warnings.
#   - and the count can move the WRONG WAY when the bug is fixed: a
#     correct \f(CW makes groff say "cannot select font" once per use
#     under -Tascii, so "did my fix reduce warnings" says revert.
#
# Nor is a compiler warning a signal. Python's SyntaxWarning for an
# invalid escape fires on the HARMLESS cases -- \(em and \- survive a
# non-raw string intact, and are warned about -- while the damaging
# escapes \f \t \n \b \a \v \0 are consumed silently. The warning is
# loudest exactly where it does not matter.
#
# Uses perl, not grep: this machine's grep is ugrep, which REJECTS a
# [\x00-\x08] range outright rather than matching it, so a grep version
# fails to run while looking like it found nothing.

set -e
cd "$(dirname "$0")/.."

scan() {
	perl -e '
		my $bad = 0;
		for my $f (@ARGV) {
			open(my $h, "<", $f) or next;
			local $/; my $s = <$h>; close $h;
			my @hit;
			while ($s =~ /([\x00-\x08\x0b\x0c\x0e-\x1f])/g) {
				# Take ord() BEFORE counting lines: the newline
				# match below clobbers $1, and sprintf evaluates
				# its arguments left to right, so computing the
				# line number first reported every byte as 0x00.
				my $code = ord($1);
				my $off = pos($s) - 1;
				my $line = 1 + (() = substr($s, 0, $off) =~ /\n/g);
				push @hit, sprintf("%s:%d: 0x%02X", $f, $line, $code);
			}
			if (@hit) { $bad += @hit; print "$_\n" for @hit; }
		}
		exit($bad ? 1 : 0);
	' "$@"
}

# Self-test first: a file whose answer is known. If this cannot be
# reproduced the scanner is broken, and a clean sweep below would be
# meaningless -- exit 2 so "I am broken" is distinguishable from
# "I found something" (exit 1) and "clean" (exit 0).
t=$(mktemp)
trap 'rm -f "$t"' EXIT 0
# Two plants on known, DIFFERENT lines. Asserting their positions rather
# than a count makes the fixture verify its own plants as a side effect
# and say WHICH one went missing: a count of 2 is also what one working
# plant plus one double-counted hit looks like.
printf '.B plot \014Iid\014R\nplain line\n.B \014Bx\014P\n' > "$t"
got=$(scan "$t" 2>/dev/null | sed "s|^$t:||" | cut -d: -f1 | tr '\n' ' ')
if [ "$got" != "1 1 3 3 " ]; then
	echo "troff-ctlchars: SELF-TEST FAILED -- planted 0x0C on lines 1,1,3,3; scanner reported [$got]" >&2
	echo "troff-ctlchars: either the scanner is broken or the plant did not land; nothing below is trustworthy" >&2
	exit 2
fi

# Tabs (0x09) are excluded: troff source uses them legitimately.
# Only text is scanned; .pdf and .gif under doc/ are binary by nature.
# Run from outside the tree, `find man doc' fails and set -e killed the
# script at this assignment with status 1 and NO diagnostic -- 1 means
# "I found something", so the one code a caller must not misread was the
# one it returned. Being unable to look is exit 2.
for d in man doc; do
	if [ ! -d "$d" ]; then
		echo "troff-ctlchars: no $d/ directory in $(pwd) -- not a tree I can scan" >&2
		exit 2
	fi
done

files=$(find man doc -type f \
	! -name '*.pdf' ! -name '*.gif' ! -name '*.jpg' ! -name '*.png' \
	! -name '*.ps' ! -name '*.gz' 2>/dev/null)

if [ -z "$files" ]; then
	echo "troff-ctlchars: man/ and doc/ exist but matched no files -- refusing to report clean" >&2
	exit 2
fi

if scan $files; then
	echo "troff-ctlchars: clean"
	exit 0
else
	echo "troff-ctlchars: stray control characters above; a 0x0C followed by I, B, R, P or ( is a lost \\f" >&2
	exit 1
fi
