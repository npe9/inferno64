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
                    '-t', '150', '-u', 'the microkernel idles'],
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
    #
    # The syscall half of "does an entry give back every register it was
    # given".  The interrupt half is measured in the kernel
    # (regtorture.s, pc64's init0); this is the other entry, and it is
    # the one that is this kernel's own code rather than 9front's -
    # syscallentry and forkret carry both the Plan 9 and the Linux ABI,
    # so they save and restore every register.  It has to be asked from
    # user mode because that is the only place a system call comes from.
    #
    # The answered count is required to be 0 as well as the registers
    # clean: a path that refused every call would still have exercised
    # the entry, and that is worth being able to tell apart from one
    # that served them.
    results.append(("and a system call gives back every register it was not told to keep: eleven of them held across real system calls made from user mode, which is the entry this kernel wrote itself - AX carries the result, CX and R11 are what SYSRET consumes and BP is the call number, so those four are excluded by the ABI and named rather than quietly skipped",
                    re.search(r'osprey user: eleven registers survived (\d+) of \1 system calls, '
                              r'so syscallentry and forkret gave back every one they were not told to keep', t)
                    is not None))
    results.append(("and it maps its container's message ring through the microkernel's address-space service",
                    'message ring with segattach' in t))
    results.append(("and the library opens a file by name at a server over the ring",
                    'opened a file at the server over the ring' in t))
    results.append(("and reads the file's full contents back over the ring, served by the task not the kernel",
                    'serves this file from a task by message passing' in t))
    results.append(("and the server that answered is itself a user program, its own ring and its client's slice mapped",
                    'a user-mode file server; its own ring and its client' in t))
    results.append(("and it waited for that request with select over its ring's arm, the talk's central call in user space",
                    'select over its ring' in t))
    results.append(("and a user-level graphics driver draws to the frame buffer the microkernel exposed",
                    'drew a windowed desktop to the frame buffer' in t))
    results.append(("and user-level keyboard and mouse drivers select on the interrupt semaphores the microkernel exposes",
                    'selecting on their interrupt semaphores' in t))
    results.append(("and it exits through the microkernel's minimal syscall interface, no Plan 9 personality",
                    'the program exited' in t and 'panic' not in t))
    #
    # The console task's slots, which the kernel fills and it pushes.
    # The kernel used to decide a slot was free by counting - the
    # queue's length and one in flight - which is one short, so under
    # load it rewrote a slot the task was still pushing and the console
    # came out spliced.  A slot is given back now, and this says so.
    #
    # It does not discriminate on its own: with the program this check
    # runs, the kernel before the fix passed it too, and so did the p9
    # check, which writes far more.  What found the bug was userprog
    # making two more console writes at that moment, and what this is
    # for is the next thing that writes that much.
    #
    results.append(("and no console slot was rewritten under the task while it was pushing it",
                    'changed between being filled and being pushed' not in t))

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
