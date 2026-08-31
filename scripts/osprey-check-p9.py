#!/usr/bin/env python3
"""Boot p964 and say Plan 9 runs on the Osprey microkernel.

p964 is the same cut microkernel core as xup64 - no in-kernel name
space, process groups or file cluster - but the user program it enters
is the Plan 9 personality: the name-space machinery (chan.c, dev.c,
pgrp.c, devroot.c) compiled as an ordinary user library and linked with
a small shim.  Where xup64's user task is a bare microkernel program
that only writes the console and exits, p964's task builds a Plan 9 name
space in user space, attaches the root device, and reads a directory
through namec/open/read - all in-process, the kernel serving only print
and exit.

This is the point the whole port aims at: Plan 9's file personality is a
library the program links, not the kernel it runs on.  xup64 keeps the
minimal-syscall stub (osprey-check-user.py) as the microkernel-primitive
witness; p964 is the same core carrying the personality.

This builds 9p964, boots it, and checks the name space came up and a
directory was read through it, with no panic.

usage: scripts/osprey-check-p9.py [-k]
"""
import os, re, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
env = dict(os.environ, PATH=os.path.join(ROOT, 'MacOSX/arm64/bin') + ':' + os.environ['PATH'])

def plain(s):
    return re.sub(r'\x1b\[[0-9;=?]*[a-zA-Z]', '', s)

def main():
    keep = '-k' in sys.argv[1:]
    r = subprocess.run(['mk', 'CONF=p964', '9p964'], cwd='os/osprey/pc64',
                       env=env, capture_output=True, text=True)
    if r.returncode != 0:
        print('FAIL 9p964 did not build')
        print(r.stdout[-800:]); print(r.stderr[-800:])
        return 1
    subprocess.run(['sh', 'scripts/mkosprey-efi-iso.sh'],
                   env=dict(env, OSPREY_KERNEL=os.path.join(ROOT, 'os/osprey/pc64/9p964')),
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    log = tempfile.mktemp(prefix='osprey-p9-', suffix='.log')
    subprocess.run(['./scripts/osprey-console.py', '-q', '-p', '2', '-n', 'e1000',
                    '-l', log, '-S', '-d', ROOT + '/.qemu/9front-root.qcow2',
                    '-t', '150', '-u', 'the microkernel idles'],
                   env=env, capture_output=True, text=True)
    try:
        t = plain(open(log, errors='replace').read())
    except OSError:
        t = ''

    results = []
    results.append(("p964 enters user mode on the microkernel",
                    'osprey: touser' in t))
    results.append(("and the program is the Plan 9 personality: it builds a name space in user space and attaches the root",
                    'name space up, root attached' in t))
    results.append(("and it reads a directory through the name space by namec/open/read, the kernel serving only print and exit",
                    'read 731 bytes of directory through the name space' in t))
    results.append(("and it exits through the microkernel's minimal syscall interface, no in-kernel personality",
                    'the program exited' in t and 'panic' not in t))

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
