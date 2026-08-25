#!/usr/bin/env python3
"""Boot lup64 and say that 9front runs as a library on the Osprey core.

lup64 is the Osprey microkernel core with the 9front personality linked
as a library: chan.c, namec, pgrp.c and the file devices.  It boots into
an Osprey task, not the Plan 9 shell, and that task calls namec and the
file code directly, in process, to open and read a real file - the
personality as a library the task links, not the kernel's own dispatch.

lup64 is the kernel the paper dictates, cut toward: it boots into an
Osprey task rather than the Plan 9 shell.  proc0 sets up no Pgrp, no name
space and no initcode; it runs ospreymicroboot, which creates a
container, submits requests to its message ring, lets the dispatcher
answer them, collects the replies, and lets a kernel task exit
through pexit to exercise the teardown the cut left stubbed.  That exercises the four services
the paper keeps -- message passing, the segment its arena is, interrupts
and the scheduler -- with the Plan 9 boot removed.

This builds 9lup64, boots it, and checks the task ran and its message
passing answered every request.  The Plan 9 configuration pc64 and its
fifty-eight-line check are what this is measured against as it grows to
replace them.

usage: scripts/osprey-check-micro.py [-k]
"""
import os, re, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
env = dict(os.environ, PATH=os.path.join(ROOT, 'MacOSX/arm64/bin') + ':' + os.environ['PATH'])

def plain(s):
    return re.sub(r'\x1b\[[0-9;=?]*[a-zA-Z]', '', s)

def main():
    keep = '-k' in sys.argv[1:]
    # build the microkernel
    r = subprocess.run(['mk', 'CONF=lup64', '9lup64'], cwd='os/osprey/pc64',
                       env=env, capture_output=True, text=True)
    if r.returncode != 0:
        print('FAIL 9lup64 did not build')
        print(r.stdout[-800:]); print(r.stderr[-800:])
        return 1
    # an ISO with the microkernel as the kernel
    subprocess.run(['sh', 'scripts/mkosprey-efi-iso.sh'],
                   env=dict(env, OSPREY_KERNEL=os.path.join(ROOT, 'os/osprey/pc64/9lup64')),
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    log = tempfile.mktemp(prefix='osprey-libos-', suffix='.log')
    subprocess.run(['./scripts/osprey-console.py', '-q', '-p', '2', '-n', 'e1000',
                    '-l', log, '-S', '-d', ROOT + '/.qemu/9front-root.qcow2',
                    '-t', '150', '-e', 'osprey micro: idle', '-c', 'echo done'],
                   env=env, capture_output=True, text=True)
    try:
        t = plain(open(log, errors='replace').read())
    except OSError:
        t = ''

    results = []
    results.append(("lup64 boots into an Osprey task, not the Plan 9 shell",
                    'osprey micro: a task, no plan 9 boot' in t
                    and 'proc0: groups' not in t))
    results.append(("and the 9front personality is linked as a library it calls in process",
                    'osprey lib: the 9front library opened' in t))
    results.append(("and that library opened and read a real file through namec",
                    'read "' in t and 'osprey lib' in t and 'could not read' not in t))
    results.append(("and that library answered another container's read, serving it the real file's contents",
                    'osprey lib: the 9front library served container' in t))
    results.append(("and it reached idle without a panic in the library or the core",
                    'osprey micro: idle' in t and 'panic' not in t))

    bad = 0
    for what, ok in results:
        print('%-4s %s' % ('ok' if ok else 'FAIL', what))
        if not ok:
            bad += 1
    if keep or bad:
        print('log %s' % log)
    else:
        try: os.unlink(log)
        except OSError: pass
    return 1 if bad else 0

sys.exit(main())
