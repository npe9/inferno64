#!/usr/bin/env python3
"""Compare every `extern' function declaration against its definition.

WHY.  kencc does not compare a declaration in one translation unit with
a definition in another, and neither does 7l: the call is assembled from
whatever prototype was in scope.  So a .c file that declares its own
extern instead of using fns.h can pass the wrong number of arguments
and the kernel links, boots, and misbehaves.

That is not hypothetical.  A merge took a five-parameter mboxfballoc
while screenbcm.c went on declaring and calling a six-parameter one --
the sixth being a framebuffer's virtual height -- and the kernel booted
with NO FRAMEBUFFER AT ALL.  Nothing in the toolchain could catch it,
because the prototype and the definition were in different files and
neither tool looks across them.

	python3 tools/kcheck/externarity.py [dir ...]

POSITIVE CONTROL, which is the only reason to believe any of this.
Reproduce the framebuffer bug and the tool must name it:

	# in os/inferno/raspi3b/screenbcm.c, line 31, add a parameter:
	#   extern int mboxfballoc(int, int, int, uintptr*, u32*, u32*);
	screenbcm.c:31: mboxfballoc declared with 6 parameter(s);
	    defined with 5 in os/inferno/raspi3b/mailbox.c

Run and restored; the tree is unchanged by it.

Exit 0 if every declaration agrees with its definition, 1 if any does
not, 2 if asked to check nothing.  A declaration with no definition
found is reported separately and does not fail the run: plenty live in
libraries this does not read.
"""
import os
import re
import sys

# `extern TYPE name(params);' possibly over several lines, and
# `TYPE\nname(params)\n{' for Plan 9 style definitions.
DECL = re.compile(
    r'\bextern\s+[A-Za-z_][\w\s\*]*?\b(\w+)\s*\(([^;{]*?)\)\s*;', re.S)
DEFN = re.compile(r'^([A-Za-z_]\w*)\s*\(([^;{]*?)\)\s*\{', re.M | re.S)


def arity(params):
    """Parameter count, tracking parenthesis depth so a function
    pointer's own commas are not counted, and -1 for variadic."""
    p = params.strip()
    if p == '' or p == 'void':
        return 0
    n = 1
    depth = 0
    for ch in p:
        if ch in '([':
            depth += 1
        elif ch in ')]':
            depth -= 1
        elif ch == ',' and depth == 0:
            n += 1
    if p.endswith('...'):
        return -n
    return n


def main():
    dirs = sys.argv[1:]
    if not dirs:
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        print('usage: externarity.py dir [dir ...]', file=sys.stderr)
        return 2

    files = []
    for d in dirs:
        for root, nil, names in os.walk(d):
            for nm in names:
                if nm.endswith(('.c', '.h')):
                    files.append(os.path.join(root, nm))

    defs = {}
    for f in files:
        try:
            src = open(f, errors='replace').read()
        except OSError:
            continue
        for m in DEFN.finditer(src):
            name, params = m.group(1), m.group(2)
            if name in ('if', 'for', 'while', 'switch', 'return', 'else'):
                continue
            defs.setdefault(name, (arity(params), f))

    known = {}
    kf = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      'externarity.known')
    try:
        for ln in open(kf):
            ln = ln.strip()
            if not ln or ln.startswith('#'):
                continue
            nm = ln.split('\t', 1)[0].strip()
            known[nm] = ln.split('\t', 1)[1].strip() if '\t' in ln else ''
    except OSError:
        pass

    bad = nodef = checked = excused = 0
    for f in files:
        src = open(f, errors='replace').read()
        for m in DECL.finditer(src):
            name, params = m.group(1), m.group(2)
            if name not in defs:
                nodef += 1
                continue
            checked += 1
            want, where = defs[name]
            got = arity(params)
            if got != want:
                line = src[:m.start()].count('\n') + 1
                msg = ('%s:%d: %s declared with %s parameter(s);'
                       ' defined with %s in %s'
                       % (f, line, name, abs(got), abs(want), where))
                if name in known:
                    excused += 1
                    print('externarity: known: ' + msg)
                    print('    ' + known[name])
                else:
                    bad += 1
                    print(msg, file=sys.stderr)
    print('externarity: %d declarations checked, %d NEW mismatch(es),'
          ' %d known, %d with no definition here'
          % (checked, bad, excused, nodef))
    if bad:
        print('externarity: a declaration disagrees with its definition and'
              ' NO TOOL IN THIS BUILD COMPARES THEM; fix it or, if it is'
              ' understood, say why in tools/kcheck/externarity.known',
              file=sys.stderr)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
