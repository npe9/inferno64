#!/bin/sh
#
# troff-argorder - find .CW/.I/.B lines whose arguments troff will REORDER.
#
#	sh tests/troff-argorder.sh		# this tree's own doc/*.ms
#	sh tests/troff-argorder.sh doc/foo.ms	# one file
#
# WHY A SCANNER AND NOT THE WARNING COUNT.  In -ms these macros take up to
# three arguments and render them
#
#	third + FONT(first) + second
#
# so the third is a PREFIX and the second a SUFFIX.  Measured, not assumed:
#
#	.CW one			-> one
#	.CW one two		-> onetwo
#	.CW one two three	-> threeonetwo
#	.CW one two three four	-> threeonetwo       ("four" dropped, WARNS)
#
# Only the four-argument case warns.  THE THREE-ARGUMENT CASE IS SILENT AND
# SCRAMBLES THE LINE, and it is much the commoner mistake because
#
#	.CW ( osblock ),	-> ),(osblock
#	.CW AINC / ADEC		-> ADECAINC/
#	.I new block numbers	-> numbersnewblock
#
# all look like one phrase in the source.  The last of those is in
# doc/open-issues-plan.ms and renders exactly like that in the output; the
# second is in doc/parallel-allocator-survey.ms.
#
# I LEARNED THIS THE WRONG WAY ROUND.  d6b4095e0 fixed ten FOUR-argument sites
# in open-issues-plan.ms, got the warning count to zero, and its message says
# that makes the check "a simple is the count still zero".  That was wrong:
# zero warnings only means no four-argument lines, and the same document had
# forty-two silent three-argument ones.  A clean warning count read as a clean
# document.
#
# WHAT COUNTS AS A FALSE POSITIVE, because two shapes are legitimate:
#
#	.I cs (8)		2 args -> cs(8)        the man-reference idiom
#	.CW x , (		3 args -> (x,          a deliberate prefix
#
# So a third argument that is PURE PUNCTUATION is accepted; a third argument
# containing a letter or digit is reported.  And troff's own tokenising is
# respected -- a quoted "a b" is one argument, and so is an escaped `a\ b',
# which is why a naive whitespace split over-reports by hundreds.
#
# AND THE CLASS THIS CHECK WAS BLIND TO, which is the mirror image of that
# exemption and 144 sites across nine of this tree's documents.
#
# The note above is right that `.CW x , (' is deliberate: with the prefix LAST,
# third+first+second puts it in front and the line renders `(x,'.  Written the
# other way round it is a defect, and that is how most of these documents write
# it:
#
#	.CW ( 3810cbdc2 ):	3 args -> ):(3810cbdc2     BACKWARDS
#	.CW 3810cbdc2 ): (	3 args -> (3810cbdc2):     what was meant
#	.CW "(3810cbdc2):"	1 arg  -> (3810cbdc2):     also fine
#
# Both were measured by rendering, not by reading the rule.  The first shape
# puts the OPENING paren in the third slot, so it lands after the text, and the
# closing paren lands in front.
#
# The old rule exempted it twice over: the third argument of `.CW ( x ):' is
# `):', pure punctuation, so the "deliberate prefix" test accepted it -- and
# four-argument lines are the only ones troff warns about, so groff was silent
# too.  THREE TROFF TESTS PASSED ON 144 BACKWARDS LINES.  That is the same
# failure as a guard built for a case it was never shown, and this tree already
# has the rule: an instrument has to be given a case it must catch.
#
# So: a FIRST argument that is pure punctuation, on a line with three or more
# arguments, is now reported too.  Two arguments is still fine -- `.CW ( foo'
# renders `(foo', in the right order, with only the font of `foo' wrong, and
# there are 46 of those left alone deliberately.
#
# EXIT: 0 nothing found, 1 sites found (this is a report, not a verdict on
# whether each one is wrong -- a human decides, because "(x," really is
# sometimes what the author wanted).
#
set -u
ROOT=`cd \`dirname "$0"\`/.. && pwd`
cd "$ROOT" || exit 1

if [ $# -gt 0 ]; then
	FILES="$*"
else
	#
	# This tree's own documents only.  The upstream Inferno papers
	# (acid.ms, sh.ms, port.ms, the dated ones) have the same shapes and
	# are not ours to churn; their warnings here are font-availability
	# noise from this groff install, not text loss.
	#
	# DEDUPED: open-issues-plan.ms matches doc/*-plan.ms as well, and the
	# first version listed it twice, so it was reported twice and its
	# sites counted twice in the total.
	#
	# A NAMED FILE THAT IS MISSING IS SAID, NOT SKIPPED.  This list is
	# hardcoded, so renaming a document silently removes it from the
	# check -- the same `|| continue' shape that let a missing source
	# drop a whole device from man-cmdtab without changing its status.
	# A glob that matches nothing is fine; a name that does not resolve
	# is a stale list.
	#
	want=
	for f in doc/*-plan.ms doc/open-issues-plan.ms \
	    doc/inferno-ports.ms doc/osprey-progress.ms doc/osprey-gap.ms \
	    doc/osprey-plan.ms doc/parallel-allocator-survey.ms \
	    doc/kernel-builds.ms; do
	    #
	    # doc/session.ms WAS in this list and exists only on the
	    # inferno-rio branch (committed 40e16452d, never on
	    # raspi3b-port).  `[ -f "$f" ] && echo' dropped it in silence, so
	    # this check named eight documents and read seven for its whole
	    # life.  The guard below found it on its first run.
	    #
		case "$f" in *'*'*) continue;; esac	# unmatched glob
		if [ -f "$f" ]; then
			want="$want $f"
		else
			echo "troff-argorder: $f is in the list and does not" >&2
			echo "  exist -- the list is stale and that document is" >&2
			echo "  no longer being checked.  Not reporting a pass." >&2
			exit 1
		fi
	done
	FILES=`for f in $want; do echo "$f"; done | sort -u | tr '\n' ' '`
fi

if [ -z "$FILES" ]; then
	echo "troff-argorder: no documents to check; not reporting a pass" >&2
	exit 1
fi
printf 'troff-argorder: %s document(s) checked\n' "`echo $FILES | wc -w | tr -d ' '`"

python3 - $FILES <<'PYEOF'
import re, sys

# Tokenise the way troff does: "..." is one argument, and a backslash-escaped
# space does not separate.  A naive split reports hundreds of false hits on
# lines like `.CW 5l\ -a 's'.
def args(rest):
    out, cur, i, n = [], '', 0, len(rest)
    while i < n:
        c = rest[i]
        if c == '"':
            j = rest.find('"', i+1)
            if j < 0: j = n
            out.append(rest[i:j+1]); i = j+1
            while i < n and rest[i] == ' ': i += 1
            continue
        if c == '\\' and i+1 < n:
            cur += rest[i:i+2]; i += 2; continue
        if c == ' ':
            if cur: out.append(cur); cur = ''
            i += 1; continue
        cur += c; i += 1
    if cur: out.append(cur)
    return out

wordy = re.compile(r'[0-9A-Za-z]')
total = 0
for f in sys.argv[1:]:
    hits = []
    try: lines = open(f, errors='ignore').read().split('\n')
    except OSError: continue
    for i, l in enumerate(lines, 1):
        m = re.match(r'^\.(CW|I|B)\s+(\S.*)$', l)
        if not m: continue
        a = args(m.group(2))
        if len(a) < 3: continue
        #
        # Class 1: a punctuation-only FIRST argument.  third+first+second
        # moves everything after it in front, so `.CW ( x ):' renders
        # `):(x'.  Reported regardless of what the third argument is.
        #
        # Class 2: a third argument containing a letter or digit, which is
        # real text landing in front of the rest.  A punctuation-only third
        # argument is the deliberate prefix idiom and stays exempt.
        #
        if not wordy.search(a[0]) and '"' not in a[0] and '\\' not in a[0]:
            #
            # The quote and backslash exclusions are not cosmetic.  This
            # tokeniser is an approximation of troff's, and on two lines in
            # these documents it gets the split wrong in a way that produces
            # a punctuation-only first argument out of nothing:
            #
            #   .CW "\"bflag\", 1"   -> ['"\\"', 'bflag\\",', '"', '1']
            #   .CW exception\ e\ ... -> ['"*"', 'exception\\ e\\ ...', '}']
            #
            # Both are single troff arguments really.  A first argument that
            # is punctuation AND free of quotes and backslashes is the shape
            # this check is about, and excluding the other two costs nothing:
            # neither is reorderable, so there is nothing to report.
            #
            hits.append((i, l, 'leading punctuation moves the rest in front'))
        elif wordy.search(a[2]):
            hits.append((i, l, 'a word in the third argument comes out first'))
    if hits:
        print("=== %s (%d)" % (f, len(hits)))
        for i, l, why in hits:
            print("  %6d  %-62s  %s" % (i, l[:62], why))
        total += len(hits)

print()
if total == 0:
    print("troff-argorder: none -- no .CW/.I/.B line leads with punctuation or")
    print("troff-argorder: has a word in its third argument, so none is reordered.")
else:
    print("troff-argorder: %d site(s).  troff renders these as" % total)
    print("troff-argorder:   third + FONT(first) + second")
    print("troff-argorder: so each one comes out in the wrong order, SILENTLY --")
    print("troff-argorder: only the four-argument form warns.  Quote the whole")
    print("troff-argorder: phrase, or move the prose to the next line.")
#
# 2, NOT 1, because tests/toolchain maps 2 to DEFECT and every other
# nonzero to BROKE.  With exit 1 a real reordered .CW was reported as
# "BROKE ... could not reach its subject" and the summary said "0
# defect(s)" -- verified by planting one and running the suite.  A
# finding that reads as a harness failure is worse than no check.
#
sys.exit(2 if total else 0)
PYEOF
