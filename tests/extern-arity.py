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

ONE LINK AT A TIME, and the default is the kernel's: os/inferno/raspi3b
plus os/inferno/port.  Do NOT add emu/port to that run.  They are two
separate links and the same name legitimately differs between them --
emu/port/chan.c defines addelem(Cname*, char*) where
os/inferno/port/chan.c defines addelem(Path*, char*, Chan*), and both
are right.  Comparing across links invents mismatches.  Check emu
separately:

	python3 tests/extern-arity.py emu/port

A peer widened their equivalent check to both at once and called it
"the directories of one link", which it was not; that is where this
note comes from.  Nothing in this tree currently declares a local
extern for a cross-link ambiguous name, so mixing them reports clean
today -- which makes it a latent trap rather than a safe shortcut.

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
	2	DEFECT -- a declaration disagrees with its definition, OR
		two non-static definitions of one name disagree with
		each other (which needs no declaration to be wrong)
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
    """Return (mismatches, compared, inconsistent_defs, files_read)."""
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

    #
    # DEFINITIONS AGAINST EACH OTHER, not only declarations against
    # definitions.  Two NON-static definitions of one name in one link
    # disagreeing about arity is an inconsistency on its own, with no
    # declaration needed to expose it: whichever the loader resolves to,
    # some caller is wrong.
    #
    # This existed as a one-off check I ran by hand to justify the
    # static rule above, and reporting a property I had verified once
    # while not enforcing it is the gap this closes.  A peer found a
    # real instance in the emu link that neither of our checkers was
    # looking for -- attachscreen, 4 in emu/port/win-x11-old.c against 5
    # in win-x11a.c.
    #
    # Whether BOTH files are built is a config question this tool does
    # not answer, so the report says so rather than implying a live
    # fault.  The kernel link has none of these.
    #
    inconsistent = []
    for name, ds in sorted(defs.items()):
        glob_ds = [d for d in ds if not d[3]]
        if len({d[2] for d in glob_ds}) > 1:
            inconsistent.append((name, glob_ds))

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
    return found, compared, inconsistent, len(paths)


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
# MEASURED BY MUTATION rather than argued, which is what makes the
# fixtures more than decoration.
#
# HOW TO REPRODUCE IT, and the method is load-bearing because the first
# harness I used was wrong.  Copy this file, sed one line, and run the
# copy WITH EXPLICIT DIRECTORIES:
#
#	cp tests/extern-arity.py tests/.mut.py
#	sed -i '' 's|if got != want:|if False:|' tests/.mut.py
#	python3 tests/.mut.py os/inferno/raspi3b os/inferno/port
#
# then grep the output for `SELF-TEST FAILED'.
#
# TWO WAYS THAT GOES WRONG AND LOOKS RIGHT.  Put the mutant in a
# scratch directory and its HERE resolves there, so the default roots
# do not exist and it exits 1 with "is not a directory" -- which is
# indistinguishable from "the self-test caught it" IF YOU ONLY READ THE
# EXIT CODE.  Every entry below first appeared to pass that way, for
# mutations that had never been exercised at all.  And passing the two
# roots through an unquoted shell variable is worse, because zsh does
# not word-split: both paths arrive as ONE argument, the control itself
# exits 1, and the table reads unanimous.
#
# So the verdict is taken from the self-test's OWN message and the
# unmutated control is run FIRST and required to exit 0.  Discriminate
# by WHICH failure, never by failure.  The table below is the result of
# the corrected harness; the earlier numbers were right by coincidence.
#
# AND THE VERDICT IS THREE-WAY, not two, which is the same bug one level
# in.  Two rows expect the EMPTY SET -- never-report and arity-constant
# -- and a self-test whose own fixtures were not scanned also produces
# the empty set, fails, and prints SELF-TEST FAILED.  So a dead harness
# read as a CATCH on every row, satisfied by the absence of the thing
# being tested.  Demonstrated by stubbing the fixture scan.  The
# self-test now reports its liveness separately:
#
#	HARNESS DEAD ...   the self-test never ran; not a catch
#	SELF-TEST FAILED   the detector is broken, or a mutation was caught
#	exit 0             clean
#
# A peer found this in their harness first and named the trap in fixing
# it: their liveness signal was DECLARATIONS COMPARED, and their
# never-report mutation disables the declaration regex, so comparing
# nothing is exactly what that mutation does and a healthy run reported
# the harness dead.  A liveness signal must be independent of every
# mutation it guards.
#
#	scanner mutation                    self-test
#	never report a mismatch             exit 1, CAUGHT
#	report every pair as a mismatch     exit 1, CAUGHT
#	judge against static definitions    exit 1, CAUGHT
#	judge ONLY against static ones      exit 1, CAUGHT
#	arity() returns a constant          exit 1, CAUGHT
#	arity() always returns 1            exit 1, CAUGHT
#	unmutated                           exit 0
#
# THE LAST TWO MAKE THE SCANNER BLIND RATHER THAN LOUD, which is the
# direction a weak self-test misses.  A constant arity gives the
# declaration and the definition the same wrong number, so everything
# agrees, nothing is reported, and the scan returns the EMPTY SET.
#
# That is caught here because the assertion is SET EQUALITY against
# exactly ['fballoc']: it demands a true positive AND no false positives
# in one statement, so a scanner that has gone quiet fails it just as
# surely as one that has gone loud.  An assertion on the COUNT would not
# have caught it, and would also have accepted a false positive on one
# fixture plus a miss on another -- one plus one is also two.
#
# WHAT THIS COMMENT SAID AND GOT WRONG, because the mistake is the
# instructive part.  It read: "a mutation that leaves the comparison
# satisfiable tests nothing."  That is false, and it contradicted the
# next sentence of the same comment, which explained how the mutation is
# detected.  A constant arity does not leave the comparison untestable;
# it silences the tool, which is a real and detectable failure.  The
# claim came from a peer who had labelled that mutation
# `report-everything', expected three reports, got none, and read the
# silence as the mutation being inert rather than as the scanner going
# quiet -- then retracted it.  I had written it down as received.
#
# So the rule is: assert the exact set the scanner should produce, and
# keep loud and quiet mutations as SEPARATE cases, because a mutation
# must make each call differ to make a checker loud and a constant makes
# it quiet.
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
        found, _, _, nread = scan(sorted(glob.glob(os.path.join(d, '*.c'))))
        #
        # LIVENESS FIRST, AND INDEPENDENT OF THE MUTATION UNDER TEST.
        #
        # Two rows of the mutation table below expect the EMPTY SET --
        # never-report and arity-constant -- and a harness that scanned
        # nothing also returns the empty set.  So both would read CAUGHT
        # with nothing executed: satisfied by the absence of the thing
        # they test.  Proven in this file by stubbing the fixture scan,
        # which printed SELF-TEST FAILED and would have been recorded as
        # a catch for every row.
        #
        # FILES READ, not declarations compared.  A peer tried
        # declarations-compared first and it was wrong for a reason
        # worth keeping: their never-report mutation disables the
        # declaration regex, so comparing nothing is exactly what that
        # mutation DOES and a healthy run reported the harness dead.
        # The liveness signal has to be independent of every mutation it
        # guards -- the same error as a control sharing a code path with
        # its subject.  Three fixture files is immune to all six here.
        #
        if nread != 3:
            return ('HARNESS DEAD -- the self-test scanned'
                    f' {nread} file(s), not its 3 fixtures, so nothing'
                    ' below was exercised')
        names = sorted(n for n, *_ in found)
        if names != ['fballoc']:
            return (f'planted a 6-vs-5 mismatch, a matching pair, and a'
                    f' static same-name decoy; scanner reported'
                    f' {names or "nothing"} (want exactly fballoc)')
        return None
    finally:
        shutil.rmtree(d, ignore_errors=True)


why = selftest()
if why is not None and why.startswith('HARNESS DEAD'):
    #
    # A DISTINCT MESSAGE, because "the detector works and caught the
    # mutation" and "the detector never ran" must not print the same
    # line.  A mutation harness that greps for SELF-TEST FAILED would
    # otherwise record a dead run as a catch, on every row.
    #
    print(f'extern-arity: {why}', file=sys.stderr)
    sys.exit(1)
if why is not None:
    print(f'extern-arity: SELF-TEST FAILED -- {why}', file=sys.stderr)
    print('extern-arity: the detector does not work, so a clean result below'
          ' would mean nothing.', file=sys.stderr)
    sys.exit(1)
print('extern-arity: self-test ok -- 3 fixtures scanned; a 6-vs-5 mismatch'
      ' is caught, a matching pair and a static same-name decoy are not')

bad, checked, inconsistent, _nread = scan(sources)

for name, dfile, dline, want, sfile, sline, got in bad:
    print(f'extern-arity: {name}: {dfile}:{dline} declares {want} argument(s),'
          f' {sfile}:{sline} defines {got}')

for name, ds in inconsistent:
    print(f'extern-arity: {name}: NON-STATIC definitions disagree -- '
          + ', '.join(f'{f}:{l} takes {a}' for f, l, a, _ in ds))
    print('extern-arity:   whichever the loader resolves to, some caller is'
          ' wrong.  Whether both')
    print('extern-arity:   files are BUILT is a config question this tool does'
          ' not answer.')

#
# THE TWO FINDING CLASSES GET THEIR OWN SUMMARIES, because one block for
# both printed "0 declaration(s) disagree with their definition" above a
# nonzero exit and then advised moving a declaration that does not
# exist.  A verdict that contradicts the finding it is summarising is
# worse than no summary.
#
if bad:
    print(f'extern-arity: {len(bad)} declaration(s) disagree with their'
          f' definition, out of {checked} compared.')
    print('extern-arity: 7c cannot see this and 7l does not check it, so it'
          ' compiles, links and boots.')
    print('extern-arity: move the declaration into fns.h rather than fixing'
          ' the copy.')
if inconsistent:
    print(f'extern-arity: {len(inconsistent)} name(s) have non-static'
          f' definitions that disagree about arity.')
    print('extern-arity: no declaration is needed to make this wrong -- the'
          ' loader picks one and')
    print('extern-arity: a caller of the other is passing the wrong number of'
          ' arguments.')
if bad or inconsistent:
    sys.exit(2)

#
# THE LAST TWO PATH COMPONENTS, not the basename.  With basenames, a run
# over the kernel and emu together printed "raspi3b, port, port" -- two
# different directories under one name, in the line a reader uses to
# judge what was covered.  os/port and emu/port at least differ.
#
def label(r):
    p = os.path.normpath(r).split(os.sep)
    return os.sep.join(p[-2:]) if len(p) > 1 else p[-1]


where = ', '.join(label(r) for r in roots)
print(f'extern-arity: ok -- {checked} declaration(s) compared against'
      f' definitions in {where}, {len(sources)} source(s) read')
sys.exit(0)
