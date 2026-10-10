#!/usr/bin/env python3
"""extern-arity - do locally-declared externs match their definitions?

	python3 tests/extern-arity.py [directory]

HOST ONLY: no board, no adapter, no card.  It reads source.

WHAT IT GUARDS, and it is not hypothetical -- it is the bug that
motivated it, found 10 October 2026 after a merge.

kencc checks a prototype only against uses in the SAME translation
unit, and 7l does not compare signatures across objects at all.  So a
function DECLARED where it is used and DEFINED in another file can
disagree with its definition and still compile without a diagnostic,
link without a diagnostic, and boot.

	screenbcm.c:31    extern int mboxfballoc(int,int,int,uintptr*,u32*,u32*);
	mailbox.c         mboxfballoc(int w, int h, uintptr *fbpa, ...)

Six arguments passed to five parameters.  Everything after the second
shifted by one: the virtual height landed in the framebuffer-address
pointer.  The allocation failed, the kernel came up WITH NO FRAMEBUFFER
AT ALL, and the only symptom was two unrelated Dis tests reporting "no
frame buffer" on a board whose monitor had worked an hour before.  The
parameter had been dropped by rebuilding mailbox.c from another
branch's copy, which had five.

The general point is worth more than the instance: declaring an extern
beside its use, instead of in fns.h, defeats cross-file type checking
completely.  This cannot stop anyone doing that, so it checks the
declarations that exist.

HOW IT COUNTS.  Top-level commas between the parentheses, with `void'
and empty treated as zero.  A function-pointer or array parameter would
be miscounted; none in these directories has one, and the summary line
prints how many declarations it actually compared so that a reader can
tell a clean run from a run that looked at nothing -- the failure this
tree keeps finding in its own tools.

WHAT IT WILL AND WILL NOT JUDGE, which bounds what a clean run means:

  - Only functions DEFINED in the directories scanned.  An extern for
    libc, libmemdraw or anything else outside them is skipped rather
    than guessed at, so a zero does not mean every extern is right.
  - Only against a definition that is NON-STATIC, or in the SAME FILE
    as the declaration.  A static definition is file-local and an
    extern elsewhere cannot refer to it; judging against one turns a
    correct declaration into a reported defect.  91 names in scope have
    more than one definition and 16 of those disagree in arity, almost
    all through a static, so this rule is load-bearing rather than
    pedantic.
  - All matching definitions, not one.  A name with several
    implementations chosen by config (cache.c/nocache.c,
    dynld.c/nodynld.c, screenbcm.c/screennone.c/noscreen.c) is checked
    against each, and a disagreement names every file it disagrees
    with.

EXIT CODES FOLLOW tests/toolchain, WHICH IS NOT THE OBVIOUS ORDER:

	0	clean
	2	DEFECT -- a declaration disagrees with its definition
	1	BROKE  -- could not look, so no verdict

The suite maps 2 to DEFECT and every other nonzero to BROKE, so the
intuitive choice of 1 for "found something" is exactly inverted and a
real finding would print "BROKE ... could not reach its subject" while
the summary said "0 defect(s)".
"""
import glob
import os
import re
import shutil
import sys
import tempfile

#
# BOTH DIRECTORIES BY DEFAULT, because both are in the same link.
#
# This checked only os/inferno/raspi3b at first, which is the directory
# the bug that motivated it was in.  A peer wrote the equivalent check
# against their board directory AND os/inferno/port and found a 4-vs-3
# in port/devdynld.c; mine could not see it, because a declaration and
# its definition can sit in different directories of one kernel just as
# easily as in different files of one directory.  Scanning the board
# directory alone makes a clean result mean less than it reads.
#
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULTS = [os.path.join(HERE, '..', 'os', 'inferno', 'raspi3b'),
            os.path.join(HERE, '..', 'os', 'inferno', 'port')]
roots = sys.argv[1:] if len(sys.argv) > 1 else DEFAULTS

for r in roots:
    if not os.path.isdir(r):
        print(f'extern-arity: {r} is not a directory; nothing to check',
              file=sys.stderr)
        sys.exit(1)

sources = sorted(p for r in roots for p in glob.glob(os.path.join(r, '*.c')))
if not sources:
    print(f'extern-arity: no .c files under {", ".join(roots)}'
          f' -- refusing to report clean', file=sys.stderr)
    sys.exit(1)


def arity(params):
    params = params.strip()
    if params in ('', 'void'):
        return 0
    n, depth = 1, 0
    for ch in params:
        if ch in '([':
            depth += 1
        elif ch in ')]':
            depth -= 1
        elif ch == ',' and depth == 0:
            n += 1
    return n


DECL = re.compile(r'\bextern\s+[a-zA-Z_][a-zA-Z0-9_ *]*?\s*\*?\s*'
                  r'([a-zA-Z_][a-zA-Z0-9_]*)\s*\(([^;]*)\)\s*;')


def scan(paths):
    """Return (mismatches, how_many_compared) over these sources."""
    #
    # A definition is a line at column 0 of the form name(params) whose
    # NEXT line opens a brace -- the Plan 9 style this tree is written
    # in, where the return type sits on its own line above.  Matching
    # the brace too is what keeps a CALL inside a function from being
    # read as a definition.
    #
    # A LIST PER NAME, NOT ONE ENTRY, and `static' is recorded.  This
    # used to be `defs[name] = ...', so when two files defined the same
    # name the LAST ONE SCANNED silently won and every declaration of
    # that name was compared against whichever that happened to be.
    #
    # It is not a rare case: in os/inferno/raspi3b plus os/inferno/port
    # there are 91 such names and 16 of them have definitions whose
    # arities DISAGREE -- `reset' in nine driver files, `etherread' at 1
    # and 4, `pmreset' at 0 and 1.  Each of those comparisons was a coin
    # flip between a false pass and a false report, decided by sort
    # order.  The result happened to come out right, which is the worst
    # way for it to come out.
    #
    # Nearly all of them are STATIC, i.e. file-local, and an extern in
    # another file cannot possibly refer to one -- so the rule is that a
    # declaration may only be judged against a definition that is either
    # non-static, or in the same file as the declaration.  Checked: no
    # name in scope has two NON-static definitions whose arities
    # disagree, so the alternative-implementation pattern this tree uses
    # everywhere (cache.c/nocache.c, dynld.c/nodynld.c, screenbcm.c/
    # screennone.c/noscreen.c) is consistent and stays silent.
    #
    # A peer found the same defect in the baseline of their equivalent
    # check -- keyed by name, so one entry about one file excused the
    # same mismatch in another -- which is what sent me looking here.
    #
    defs = {}
    for path in paths:
        base = os.path.basename(path)
        with open(path, errors='surrogateescape') as f:
            lines = f.read().split('\n')
        for i, line in enumerate(lines):
            m = re.match(r'^([a-zA-Z_][a-zA-Z0-9_]*)\((.*)\)\s*$', line)
            if not (m and i + 1 < len(lines) and lines[i + 1].startswith('{')):
                continue
            #
            # The return type sits on the line immediately above, and
            # carries `static' when there is one.  Only that line is
            # looked at: reaching further back picks up comment text and
            # unrelated code, which would call a global function static
            # and then quietly stop checking it.
            #
            above = lines[i - 1] if i else ''
            isstatic = re.match(r'^\s*static\b', above) is not None
            defs.setdefault(m.group(1), []).append(
                (base, i + 1, arity(m.group(2)), isstatic))

    found, compared = [], 0
    for path in paths:
        base = os.path.basename(path)
        with open(path, errors='surrogateescape') as f:
            for i, line in enumerate(f, 1):
                m = DECL.search(line)
                if not m:
                    continue
                name, want = m.group(1), arity(m.group(2))
                cand = [d for d in defs.get(name, ())
                        if not d[3] or d[0] == base]
                if not cand:
                    continue        # only file-local elsewhere, or absent
                compared += 1
                for where, dline, got, _ in cand:
                    if got != want:
                        found.append((name, base, i, want, where, dline, got))
    return found, compared


#
# SELF-TEST FIRST, because a scanner that matches nothing and a clean
# tree print the same sentence.
#
# This replaces a positive control that ran against a copy of the real
# broken file in a scratch directory.  That proved the detector worked
# ON THE DAY and then the directory was deleted, so nothing in the tree
# re-ran it: a later suite run would get exit 0 with no evidence the
# detector still fires.  A fixture that lives here cannot rot that way.
#
# Both halves are load-bearing.  The MISMATCH fixture is the real bug's
# shape -- six declared against five defined.  The MATCHING one is the
# control: a checker that reported a mismatch for every pair would pass
# the first half and fail every real tree, which is the failure mode
# that matters most here because a false positive would send someone
# editing correct declarations.
#
# MEASURED BY MUTATION rather than argued, which is what makes the two
# fixtures more than decoration:
#
#	scanner mutation                    self-test
#	never report a mismatch             exit 1, CAUGHT
#	report every pair as a mismatch     exit 1, CAUGHT
#	judge against static definitions    exit 1, CAUGHT
#	unmutated                           exit 0
#
def selftest():
    d = tempfile.mkdtemp(prefix='extern-arity-self.')
    try:
        with open(os.path.join(d, 'caller.c'), 'w') as f:
            f.write('extern int fballoc(int, int, int, void*, void*, void*);\n'
                    'extern int agree(int, int);\n'
                    'extern int shadowed(int);\n')
        with open(os.path.join(d, 'callee.c'), 'w') as f:
            f.write('int\n'
                    'fballoc(int w, int h, void *a, void *b, void *c)\n'
                    '{\n\treturn 0;\n}\n'
                    '\n'
                    'int\n'
                    'agree(int a, int b)\n'
                    '{\n\treturn 0;\n}\n'
                    '\n'
                    'int\n'
                    'shadowed(int a)\n'
                    '{\n\treturn 0;\n}\n')
        #
        # A STATIC definition of the same name, in a third file, with a
        # DIFFERENT arity.  An extern in caller.c cannot refer to it, so
        # it must not be reported -- and because this file sorts after
        # callee.c it is also the one a last-one-wins scanner would have
        # kept, which is exactly how the old version would have turned a
        # correct declaration into a mismatch.
        #
        with open(os.path.join(d, 'zlocal.c'), 'w') as f:
            f.write('static int\n'
                    'shadowed(int a, int b, int c)\n'
                    '{\n\treturn 0;\n}\n')
        found = scan(sorted(glob.glob(os.path.join(d, '*.c'))))[0]
        names = sorted(n for n, *_ in found)
        if names != ['fballoc']:
            return (f'planted a 6-vs-5 mismatch, a matching pair, and a'
                    f' static same-name decoy; scanner reported'
                    f' {names or "nothing"} (want exactly fballoc)')
        return None
    finally:
        shutil.rmtree(d, ignore_errors=True)


why = selftest()
if why is not None:
    print(f'extern-arity: SELF-TEST FAILED -- {why}', file=sys.stderr)
    print('extern-arity: the detector does not work, so a clean result below'
          ' would mean nothing.', file=sys.stderr)
    sys.exit(1)
print('extern-arity: self-test ok (a 6-vs-5 mismatch is caught; a matching'
      ' pair and a static same-name decoy are not)')

bad, checked = scan(sources)

for name, dfile, dline, want, sfile, sline, got in bad:
    print(f'extern-arity: {name}: {dfile}:{dline} declares {want} argument(s),'
          f' {sfile}:{sline} defines {got}')

if bad:
    print(f'extern-arity: {len(bad)} declaration(s) disagree with their'
          f' definition, out of {checked} compared.')
    print('extern-arity: 7c cannot see this and 7l does not check it, so it'
          ' compiles, links and boots.')
    print('extern-arity: move the declaration into fns.h rather than fixing'
          ' the copy.')
    sys.exit(2)

where = ', '.join(os.path.basename(os.path.normpath(r)) for r in roots)
print(f'extern-arity: ok -- {checked} declaration(s) compared against'
      f' definitions in {where}, {len(sources)} source(s) read')
sys.exit(0)
