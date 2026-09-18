#!/usr/bin/env python3
"""No object in the tree is older than the format it is written in.

The compilers, the loaders and libmach all take the opcode numbers from
one header per object type - utils/8c/8.out.h and its fellows - and an
object written before that header changed is read wrong by the tools
after it.  mk cannot see this: it judges an object by its source's date
and an archive member by the member's own, and knows nothing of the
compiler that made either.

That is not a hypothetical.  When 8.out.h grew four opcodes in the
middle of its enum, ASIGNAME and everything after it moved; the .8
objects already in the tree kept the old numbers, and 8l read one as
"opcode out of range 3077, probably not a .8 file".  Removing the
archive was what rebuilt them.  The host libmach had the same problem
from the other side - iar could not find a symbol in a new .8, so it
wrote an archive with an empty symbol table and every function in it
came back undefined.

So this compares dates, and nothing else: every object of a type, and
every archive that holds them, against that type's header.  It is meant
to run before a sweep builds anything, because what it is looking for is
exactly what a build will not fix by itself.

usage: scripts/osprey-check-stale.py
"""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

# object suffix -> the header the tools share for it, and the name to say
TYPES = [
    ('.5', 'utils/5c/5.out.h', 'arm'),
    ('.6', 'utils/6c/6.out.h', 'amd64'),
    ('.7', 'utils/7c/7.out.h', 'arm64'),
    ('.8', 'utils/8c/8.out.h', '386'),
    ('.j', 'utils/jc/i.out.h', 'riscv64'),
    ('.k', 'utils/kc/k.out.h', 'sparc64'),
    ('.q', 'utils/qc/q.out.h', 'power'),
    ('.v', 'utils/vc/v.out.h', 'mips'),
]

# Directories with nothing built in them.  fonts/ is the one that matters:
# its .8 files are compressed font data, checked into the tree, and share
# the suffix with 386 objects by accident.
SKIPDIR = {'.git', 'fonts'}


def walk():
    for dirpath, dirnames, filenames in os.walk('.'):
        dirnames[:] = [d for d in dirnames if d not in SKIPDIR]
        for f in filenames:
            yield os.path.join(dirpath, f)


def main():
    files = list(walk())
    results = []
    for suffix, header, name in TYPES:
        if not os.path.exists(header):
            continue
        hdr = os.path.getmtime(header)
        objs = [f for f in files if f.endswith(suffix)]
        stale = [f for f in objs if os.path.getmtime(f) < hdr]
        if not objs:
            continue
        results.append(("no %s object predates %s (%d of them)" % (name, header, len(objs)),
                        stale, None))

    # The archives, which hold those objects and which mk will not rebuild
    # on its own: an archive older than the header cannot hold a member
    # newer than it.
    #
    # Which type an archive is, is read out of it rather than guessed
    # from its path: a Plan 9 archive names each member in plain text
    # ("des.7"), and MacOSX/arm64/lib holds host libraries whose path
    # says arm64 and whose members are ELF.
    byname = {suffix: (header, name) for suffix, header, name in TYPES}
    found = {}
    for f in files:
        if not f.endswith('.a'):
            continue
        top = f.replace(os.sep, '/').lstrip('./').split('/')[0]
        if top not in ('Inferno', 'Osprey'):
            continue
        try:
            with open(f, 'rb') as fp:
                head = fp.read(4096)
        except OSError:
            continue
        m = re.search(rb'[\w-]+(\.[0-9a-z])\s', head[8:])
        if m is None:
            continue
        suffix = m.group(1).decode()
        if suffix not in byname:
            continue
        found.setdefault(suffix, []).append(f)
    for suffix in sorted(found):
        header, name = byname[suffix]
        hdr = os.path.getmtime(header)
        libs = found[suffix]
        stale = [f for f in libs if os.path.getmtime(f) < hdr]
        results.append(("no %s archive predates it either (%d of them)" % (name, len(libs)),
                        stale, None))

    bad = 0
    for what, stale, _ in results:
        if stale:
            bad += 1
            print('FAIL %s' % what)
            for f in sorted(stale)[:8]:
                print('       %s' % f)
            if len(stale) > 8:
                print('       ... and %d more' % (len(stale) - 8))
        else:
            print('ok   %s' % what)
    return 1 if bad else 0


sys.exit(main())
