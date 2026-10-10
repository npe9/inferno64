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
be miscounted; none in this directory has one, and the summary line
prints how many declarations it actually compared so that a reader can
tell a clean run from a run that looked at nothing -- the failure this
tree keeps finding in its own tools.

Only functions DEFINED in the same directory are checked.  An extern for
something in port/ or libc is skipped rather than guessed at, so a zero
here does not mean every extern in the file is right.

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
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT = os.path.join(HERE, '..', 'os', 'inferno', 'raspi3b')
root = sys.argv[1] if len(sys.argv) > 1 else DEFAULT

if not os.path.isdir(root):
    print(f'extern-arity: {root} is not a directory; nothing to check',
          file=sys.stderr)
    sys.exit(1)

sources = sorted(glob.glob(os.path.join(root, '*.c')))
if not sources:
    print(f'extern-arity: no .c files under {root} -- refusing to report clean',
          file=sys.stderr)
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


#
# A definition is a line at column 0 of the form name(params) whose NEXT
# line opens a brace -- the Plan 9 style this tree is written in, where
# the return type sits on its own line above.  Matching the brace too is
# what keeps a call inside a function from being read as a definition.
#
defs = {}
for path in sources:
    with open(path, errors='surrogateescape') as f:
        lines = f.read().split('\n')
    for i, line in enumerate(lines):
        m = re.match(r'^([a-zA-Z_][a-zA-Z0-9_]*)\((.*)\)\s*$', line)
        if m and i + 1 < len(lines) and lines[i + 1].startswith('{'):
            defs[m.group(1)] = (arity(m.group(2)),
                                os.path.basename(path), i + 1)

bad = []
checked = 0
for path in sources:
    with open(path, errors='surrogateescape') as f:
        for i, line in enumerate(f, 1):
            m = re.search(r'\bextern\s+[a-zA-Z_][a-zA-Z0-9_ *]*?\s*\*?\s*'
                          r'([a-zA-Z_][a-zA-Z0-9_]*)\s*\(([^;]*)\)\s*;', line)
            if not m:
                continue
            name, want = m.group(1), arity(m.group(2))
            if name not in defs:
                continue            # defined elsewhere; not ours to judge
            got, where, dline = defs[name]
            checked += 1
            if got != want:
                bad.append((name, os.path.basename(path), i, want,
                            where, dline, got))

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

print(f'extern-arity: ok -- {checked} declaration(s) compared against'
      f' definitions in {os.path.basename(os.path.normpath(root))},'
      f' {len(sources)} source(s) read')
sys.exit(0)
