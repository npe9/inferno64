#!/usr/bin/env python3
"""Boot the Osprey microkernel and say that it stands without Plan 9.

upc64 is the kernel the paper dictates, cut toward: it boots into an
Osprey task rather than the Plan 9 shell.  proc0 sets up no Pgrp, no name
space and no initcode; it runs ospreymicroboot, which creates a
container, submits requests to its message ring, lets the dispatcher
answer them, and collects the replies.  That exercises the four services
the paper keeps -- message passing, the segment its arena is, interrupts
and the scheduler -- with the Plan 9 boot removed.

This builds 9upc64, boots it, and checks the task ran and its message
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
    r = subprocess.run(['mk', 'CONF=upc64', '9upc64'], cwd='os/osprey/pc64',
                       env=env, capture_output=True, text=True)
    if r.returncode != 0:
        print('FAIL 9upc64 did not build')
        print(r.stdout[-800:]); print(r.stderr[-800:])
        return 1
    # an ISO with the microkernel as the kernel
    subprocess.run(['sh', 'scripts/mkosprey-efi-iso.sh'],
                   env=dict(env, OSPREY_KERNEL=os.path.join(ROOT, 'os/osprey/pc64/9upc64')),
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    log = tempfile.mktemp(prefix='osprey-micro-', suffix='.log')
    subprocess.run(['./scripts/osprey-console.py', '-q', '-p', '2', '-n', 'e1000',
                    '-l', log, '-S', '-d', ROOT + '/.qemu/9front-root.qcow2',
                    '-t', '150', '-e', 'osprey micro: idle', '-c', 'echo done'],
                   env=env, capture_output=True, text=True)
    try:
        t = plain(open(log, errors='replace').read())
    except OSError:
        t = ''

    results = []
    results.append(("the microkernel boots into a task, not the Plan 9 shell",
                    'osprey micro: a task, no plan 9 boot' in t
                    and 'proc0: groups' not in t))
    m = re.search(r'osprey micro: (\d+) of 4 requests answered', t)
    results.append(("and its message ring answers every request a task submits",
                    m is not None and m.group(1) == '4'))
    results.append(("and it reaches its idle loop rather than panicking",
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
