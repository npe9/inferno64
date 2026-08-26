#!/usr/bin/env python3
"""Boot xup64 and say a user program runs on the microkernel.

xup64 is the same cut core as upc64, but it enters user mode and runs a
user program (userprog) that reaches the kernel only through a minimal
syscall interface - write to the console and exit - not the Plan 9
personality.  This is the exokernel path a library OS runs on.

xup64 is the kernel the paper dictates, cut toward: it boots into an
Osprey task rather than the Plan 9 shell.  proc0 sets up no Pgrp, no name
space and no initcode; it runs ospreymicroboot, which creates a
container, submits requests to its message ring, lets the dispatcher
answer them, collects the replies, and lets a kernel task exit
through pexit to exercise the teardown the cut left stubbed.  That exercises the four services
the paper keeps -- message passing, the segment its arena is, interrupts
and the scheduler -- with the Plan 9 boot removed.

This builds 9xup64, boots it, and checks the task ran and its message
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
    r = subprocess.run(['mk', 'CONF=xup64', '9xup64'], cwd='os/osprey/pc64',
                       env=env, capture_output=True, text=True)
    if r.returncode != 0:
        print('FAIL 9xup64 did not build')
        print(r.stdout[-800:]); print(r.stderr[-800:])
        return 1
    # an ISO with the microkernel as the kernel
    subprocess.run(['sh', 'scripts/mkosprey-efi-iso.sh'],
                   env=dict(env, OSPREY_KERNEL=os.path.join(ROOT, 'os/osprey/pc64/9xup64')),
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    log = tempfile.mktemp(prefix='osprey-user-', suffix='.log')
    subprocess.run(['./scripts/osprey-console.py', '-q', '-p', '2', '-n', 'e1000',
                    '-l', log, '-S', '-d', ROOT + '/.qemu/9front-root.qcow2',
                    '-t', '150', '-e', 'the microkernel idles', '-c', 'echo done'],
                   env=env, capture_output=True, text=True)
    try:
        t = plain(open(log, errors='replace').read())
    except OSError:
        t = ''

    results = []
    results.append(("xup64 enters user mode on the microkernel",
                    'osprey: touser' in t))
    results.append(("and a program runs there whose file personality is a user-space library, not the kernel's",
                    'whose file personality is a library' in t))
    results.append(("and it maps its container's message ring through the microkernel's address-space service",
                    'message ring with segattach' in t))
    results.append(("and the library opens a file by name at a server over the ring",
                    'opened a file at the server over the ring' in t))
    results.append(("and reads the file's full contents back over the ring, served by the task not the kernel",
                    'serves this file from a task by message passing' in t))
    results.append(("and a user-level graphics driver draws to the frame buffer the microkernel exposed",
                    'drew a windowed desktop to the frame buffer' in t))
    results.append(("and user-level keyboard and mouse drivers read the rings the microkernel's interrupts fill",
                    'keyboard and mouse drivers reading exposed rings' in t))
    results.append(("and it exits through the microkernel's minimal syscall interface, no Plan 9 personality",
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
