#!/bin/sh
#
# troff-p1 - a document that USES .P1 must DEFINE it, or its displays render
#	     as filled prose.
#
#	sh tests/troff-p1.sh
#
# .P1 and .P2 are Plan 9 troff additions.  groff's -ms does not define them, and
# it does not complain either: the block is simply FILLED, so an aligned table
# comes out as a paragraph of run-together numbers.
#
#	.P1                            renders as
#	  bflag=1   bflag=0              bflag=1 bflag=0 3350 3470
#	  3350 3470 3250 3320            3250 3320 pooled mean 3407
#	.P2
#
# THIS IS THE DEFECT CLASS THIS SUITE KEEPS FINDING: it is not an error, so
# troff says nothing, groff -ww says nothing, and the existing checks here --
# troff-argorder for reordered arguments, troff-ctlchars for lost font escapes
# -- both pass.  Every one of 471 .P1 blocks across fourteen of this tree's own
# documents was rendering wrong, including a table that had been read and quoted
# in a commit message.  The lint and the render catch different things.
#
# THE FIX IS SIX LINES PER DOCUMENT, not a conversion of 471 blocks:
#
#	.de P1
#	.DS L
#	..
#	.de P2
#	.DE
#	..
#
# .DS L / .DE is standard -ms, so it is correct under Plan 9 troff too.
#
# THE UPSTREAM INFERNO PAPERS ARE EXCLUDED and are not a finding: sh.ms, dis.ms,
# mk.ms, install.ms, acidtut.ms, asm.ms and the rest use .P1 correctly for the
# troff they were written for, and churning them is not ours to do -- the same
# boundary tests/troff-argorder.sh draws.
#
# Exit 0 clean, 2 DEFECT (a document uses .P1 without defining it), 1 could not
# look.  tests/toolchain maps 2 to DEFECT and every other nonzero to BROKE.

set -u
cd "`dirname $0`/.." || exit 1

#
# OUR documents, the same list troff-argorder.sh uses.  A glob that matches
# nothing is fine; a NAME that does not resolve means the list is stale and is
# said rather than skipped, which is how that test lost doc/session.ms for its
# whole life.
#
want=
for f in doc/*-plan.ms doc/open-issues-plan.ms doc/inferno-ports.ms \
    doc/osprey-progress.ms doc/osprey-gap.ms doc/osprey-plan.ms \
    doc/parallel-allocator-survey.ms doc/kernel-builds.ms; do
	case "$f" in *'*'*) continue;; esac
	if [ -f "$f" ]; then
		want="$want $f"
	else
		echo "troff-p1: $f is in the list and does not exist -- the list" >&2
		echo "  is stale and that document is not being checked." >&2
		exit 1
	fi
done
files=`for f in $want; do echo "$f"; done | sort -u`
[ -n "$files" ] || { echo "troff-p1: no documents to check" >&2; exit 1; }

#
# SELF-TEST, because a checker that matches nothing and a clean tree are
# indistinguishable: one fixture that uses .P1 without defining it, one that
# defines it.
#
T=${TMPDIR:-/tmp}/troffp1.$$
trap 'rm -rf "$T"' 0 1 2 15
mkdir -p "$T" || exit 1
printf '.LP\nx\n.P1\n a b\n.P2\n'            > "$T/bad.ms"
printf '.de P1\n.DS L\n..\n.LP\nx\n.P1\n a b\n.P2\n' > "$T/good.ms"
bad=`grep -c '^\.P1' "$T/bad.ms"`
baddef=`grep -c '^\.de P1' "$T/bad.ms"`
gooddef=`grep -c '^\.de P1' "$T/good.ms"`
if [ "$bad" -eq 0 ] || [ "$baddef" -ne 0 ] || [ "$gooddef" -eq 0 ]; then
	echo "troff-p1: SELF-TEST FAILED -- the fixtures do not have the" >&2
	echo "  properties this check reads ($bad uses, $baddef/$gooddef defs);" >&2
	echo "  not reporting a pass." >&2
	exit 1
fi

rc=0
n=0
for f in $files; do
	n=`expr $n + 1`
	uses=`grep -c '^\.P1' "$f"`
	[ "$uses" -eq 0 ] && continue
	defs=`grep -c '^\.de P1' "$f"`
	if [ "$defs" -eq 0 ]; then
		echo "troff-p1: DEFECT -- $f uses .P1 $uses time(s) and never"
		echo "  defines it, so every one of those displays renders as"
		echo "  FILLED PROSE under groff -ms.  Add the six-line definition"
		echo "  described at the top of this test."
		rc=2
	fi
done
echo "troff-p1: checked $n document(s) of ours"
[ "$rc" = 0 ] && echo "troff-p1: ok -- every .P1 user defines it"
exit $rc
