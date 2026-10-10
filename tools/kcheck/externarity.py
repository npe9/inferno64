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
with NO FRAMEBUFFER AT ALL.  Neither tool could catch it, because the
prototype and the definition were in different files.

	python3 tools/kcheck/externarity.py DIR [DIR ...]
	python3 tools/kcheck/externarity.py --selftest

ONE LINK AT A TIME.  The directories given must be the ones that make a
single executable:

	kernel   os/inferno/raspi3b os/inferno/port
	emu      emu/port emu/MacOSX

NOT both together.  emu/port/chan.c defines addelem(Cname*, char*) and
os/inferno/port/chan.c defines addelem(Path*, char*, Chan*); both are
correct, they are different programs, and comparing across them invents
mismatches.  An earlier version of this scanned them as one "link" and
was wrong to.

WHAT A DECLARATION IS JUDGED AGAINST.  Every definition of that name
that the linker could actually resolve it to: the non-static ones
anywhere in the link, plus static ones IN THE SAME FILE.  A static
definition is file-local, so an extern in another file cannot refer to
it, and judging against one turns a correct declaration into a reported
defect.

This matters more than it sounds.  In this tree 919 names have more
than one definition in scope and 36 of those disagree about arity, so
a scanner that keeps one definition per name -- whichever it happened
to scan first or last -- settles those comparisons by directory order.
It will report some and pass others, and nothing in its output
distinguishes that from having checked.  A previous version of this
file did exactly that, with `defs.setdefault(name, ...)'.

LIMITS, because a regex is not a C parser.  Declarations and
definitions are found by pattern, `static' by looking back from the
definition, and arity by counting top-level commas.  Every report needs
reading.  A clean run means `no mismatch this parser can see', which is
weaker than `no mismatch'.
"""
import os
import re
import sys
import tempfile

DECL = re.compile(
    r'\bextern\s+[A-Za-z_][\w\s\*]*?\b(\w+)\s*\(([^;{]*?)\)\s*;', re.S)
DEFN = re.compile(r'^([A-Za-z_]\w*)\s*\(([^;{]*?)\)\s*\{', re.M | re.S)
KEYWORDS = ('if', 'for', 'while', 'switch', 'return', 'else', 'do')


def arity(params):
    """Parameter count, tracking parenthesis depth so a function
    pointer's own commas are not counted.  Negative means variadic."""
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
    return -n if p.endswith('...') else n


def isstatic(src, at):
    """Was this definition declared static?  Look back from the name to
    the end of the previous statement or block and check that span."""
    start = max(0, at - 240)
    span = src[start:at]
    for sep in (';', '}', '\n\n'):
        i = span.rfind(sep)
        if i >= 0:
            span = span[i + len(sep):]
    return re.search(r'\bstatic\b', span) is not None


def collect(files):
    defs = {}
    for f in files:
        try:
            src = open(f, errors='replace').read()
        except OSError:
            continue
        for m in DEFN.finditer(src):
            name, params = m.group(1), m.group(2)
            if name in KEYWORDS:
                continue
            defs.setdefault(name, []).append(
                (arity(params), f, isstatic(src, m.start())))
    return defs


def loadknown():
    known = {}
    kf = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      'externarity.known')
    try:
        for ln in open(kf):
            ln = ln.strip()
            if not ln or ln.startswith('#'):
                continue
            if '\t' in ln:
                k, why = ln.split('\t', 1)
                known[k.strip()] = why.strip()
            else:
                known[ln] = ''
    except OSError:
        pass
    return known


def check(dirs, known, quiet=False):
    files = []
    for d in dirs:
        for root, nil, names in os.walk(d):
            for nm in names:
                if nm.endswith(('.c', '.h')):
                    files.append(os.path.join(root, nm))
    files.sort()
    defs = collect(files)

    bad = nodef = checked = excused = 0
    reported = set()
    for f in files:
        src = open(f, errors='replace').read()
        for m in DECL.finditer(src):
            name, params = m.group(1), m.group(2)
            cands = [(a, df, st) for (a, df, st) in defs.get(name, [])
                     if not st or df == f]
            if not cands:
                nodef += 1
                continue
            checked += 1
            got = arity(params)
            wrong = [c for c in cands if c[0] != got]
            if not wrong:
                continue
            line = src[:m.start()].count('\n') + 1
            msg = ('%s:%d: %s declared with %d parameter(s); defined with %s'
                   % (f, line, name, abs(got),
                      ', '.join('%d in %s' % (abs(a), df)
                                for a, df, st in cands)))
            key = '%s:%s' % (f, name)
            if key in known:
                excused += 1
                if not quiet:
                    print('externarity: known: ' + msg)
                    print('    ' + known[key])
            else:
                bad += 1
                reported.add('%s:%s' % (os.path.basename(f), name))
                print(msg, file=sys.stderr)
    if not quiet:
        print('externarity: %d declarations checked, %d NEW mismatch(es),'
              ' %d known, %d with no definition in this link'
              % (checked, bad, excused, nodef))
    if bad and not quiet:
        print('externarity: a declaration disagrees with a definition the'
              ' linker could resolve it to, and NO TOOL IN THIS BUILD'
              ' COMPARES THEM; fix it, or if it is understood say why in'
              ' tools/kcheck/externarity.known', file=sys.stderr)
    return reported, len(files)


def inconsistent(dirs):
    """Names with two NON-static definitions whose arities disagree.
    Those are the ones the static rule cannot excuse, and finding none
    is what shows the alternative-implementation pattern (cache.c /
    nocache.c, dynld.c / nodynld.c) is internally consistent."""
    files = []
    for d in dirs:
        for root, nil, names in os.walk(d):
            for nm in names:
                if nm.endswith(('.c', '.h')):
                    files.append(os.path.join(root, nm))
    out = []
    for name, v in collect(sorted(files)).items():
        ns = {a for a, df, st in v if not st}
        if len(ns) > 1:
            out.append((name, [(a, df) for a, df, st in v if not st]))
    return out


FIXTURES = {
    # a.c declares 3 and the non-static definition in b.c is 3: clean.
    'a.c': 'extern int ok(int, int, int);\nextern int bad(int, int, int);\n'
           'extern int shadowed(int, int, int);\n',
    'b.c': 'int\nok(int a, int b, int c)\n{\n\treturn a+b+c;\n}\n'
           'int\nbad(int a, int b)\n{\n\treturn a+b;\n}\n'
           'int\nshadowed(int a, int b, int c)\n{\n\treturn a+b+c;\n}\n',
    # z.c sorts LAST and holds a STATIC `shadowed' at a different arity.
    # A scanner that keeps one definition per name, last one wins, would
    # keep this and report a.c's correct declaration as a defect.  A
    # declaration in a.c cannot refer to it at all.
    'z.c': 'static int\nshadowed(int a)\n{\n\treturn a;\n}\n',
}


def selftest():
    """Three fixtures and four mutations, asserting the EXACT SET the
    scanner should report.

    Not a count.  A count is satisfied by one true positive plus one
    false positive as readily as by the right answer, so a scanner that
    has gone both blind and loud passes it; set equality demands a true
    positive AND no false positive in one statement.  That correction is
    the raspi3b session's.

    MEASURED, because I had this wrong twice.  An arity() that returns a
    CONSTANT does not make the scanner loud, and does not leave it
    unchanged: it makes it BLIND.  Every declaration and definition gets
    the same number, they all agree, and it reports the EMPTY SET -- so
    `arity-constant' expects set() and is caught.  To make it loud the
    mutation must make each call DIFFER, which is what the counter in
    `report-everything' does.  I first labelled the constant as
    report-everything, read its silence as the mutation testing nothing,
    and told a peer so; it tests blindness, and set equality catches
    both directions where a count reliably catches neither.

    Two of the three fixtures cannot tell the static rule from a
    last-one-wins scanner.  The third is what does: a STATIC definition
    of the same name at a different arity, in a file that sorts LAST so
    it is exactly what a last-wins scanner would keep.
    """
    d = tempfile.mkdtemp(prefix='externarity-')
    for nm, body in FIXTURES.items():
        open(os.path.join(d, nm), 'w').write(body)

    def run():
        #
        # THE NUMBER OF FILES SCANNED comes back as well as the set,
        # and every row requires it to be non-zero.  Two of these mutations expect
        # the empty set, so a harness that ran nothing at all -- a
        # scan root that does not exist, fixtures never written --
        # satisfies them and reads CAUGHT.  Measured, by pointing the
        # scan at a nonexistent directory: never-report and
        # arity-constant both reported CAUGHT while nothing had
        # executed.  The control read BROKEN, so the table was not
        # unanimous and a reader could tell; this makes every row tell.
        #
        # It is FILES SCANNED and not declarations compared, which was
        # the first attempt and was wrong: `never-report' disables the
        # declaration regex, so comparing nothing is precisely what it
        # mutates, and it read HARNESS DEAD.  A liveness signal has to
        # be independent of the mutation under test.
        #
        return check([d], {}, quiet=True)

    rows = [('unmutated', run(), {'a.c:bad'})]

    global DECL
    keep = DECL
    DECL = re.compile(r'(?!x)x')                      # matches nothing
    rows.append(('never-report', run(), set()))
    DECL = keep

    keepa = globals()['arity']
    everything = {'a.c:ok', 'a.c:bad', 'a.c:shadowed'}

    ctr = [0]

    def never_agrees(params):
        ctr[0] += 1
        return ctr[0]
    globals()['arity'] = never_agrees
    rows.append(('report-everything', run(), everything))
    globals()['arity'] = keepa

    globals()['arity'] = lambda params: 999           # a CONSTANT
    rows.append(('arity-constant', run(), set()))
    globals()['arity'] = keepa

    keeps = globals()['isstatic']
    globals()['isstatic'] = lambda src, at: False
    rows.append(('judge-against-static', run(),
                 {'a.c:bad', 'a.c:shadowed'}))
    globals()['isstatic'] = keeps

    print('externarity selftest:')
    ok = True
    for nm, (got, ncmp), want in rows:
        if ncmp == 0:
            verdict = 'HARNESS DEAD (scanned no files)'
        elif nm == 'unmutated':
            verdict = 'OK' if got == want else 'BROKEN'
        else:
            verdict = 'CAUGHT' if got == want else 'MISSED'
        if verdict != 'OK' and verdict != 'CAUGHT':
            ok = False
        print('    %-22s %s' % (nm, verdict))
        if ncmp and got != want and nm != 'unmutated':
            print('        reported %s' % (sorted(got) or '{}',))
            print('        wanted   %s' % (sorted(want) or '{}',))
    for nm in FIXTURES:
        os.unlink(os.path.join(d, nm))
    os.rmdir(d)
    return 0 if ok else 1


def main():
    args = sys.argv[1:]
    if args and args[0] == '--selftest':
        return selftest()
    if not args:
        print('usage: externarity.py DIR [DIR ...]   (one link at a time)',
              file=sys.stderr)
        print('       externarity.py --selftest', file=sys.stderr)
        return 2
    bad = len(check(args, loadknown())[0])
    inc = inconsistent(args)
    if inc:
        print('externarity: names with two NON-static definitions that'
              ' disagree -- the static rule cannot excuse these:',
              file=sys.stderr)
        for name, where in inc:
            print('    %s: %s' % (name, ', '.join('%d in %s' % (a, f)
                                                  for a, f in where)),
                  file=sys.stderr)
    else:
        print('externarity: no name has two non-static definitions that'
              ' disagree, so the alternative-implementation pattern is'
              ' internally consistent')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
