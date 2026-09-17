#!/usr/bin/env python3
"""Boot the Osprey microkernel built for 386, and say it stands as amd64's does.

u386 is upc64's configuration for the other object type this tree builds:
the machine layer is 9front's 386 one in os/osprey/pc, and the port
layer, the policy layer and the adapter are the sources amd64 builds.
The plan says the architecture adapter is selected by OBJTYPE; this is
the second object type, so it is what says so.

This builds 9u386 and boots it with qemu-system-i386.  The 386 kernel
carries a multiboot header, so qemu loads it directly and no ISO or
9boot is needed; the console is the 8250, named on the command line.
The criteria are osprey-check-micro.py's, read from the same lines, and
one more: that the image is a 386 one, so that a build which quietly
made something else cannot pass.

What this does not reach: the microkernel boot enters no user mode.
The file server image (userprog.i) is built for 386 and linked in, and
touserv, touserat and the 386 register check are assembled and linked,
but none of them runs here; the kernel's boot stands in for the server
a program would be, as it does on amd64.

usage: scripts/osprey-check-micro386.py [-k]
"""
import os, re, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
env = dict(os.environ, PATH=os.path.join(ROOT, 'MacOSX/arm64/bin') + ':' + os.environ['PATH'])
KERNEL = os.path.join(ROOT, 'os/osprey/pc/9u386')
TIMEOUT = 90

def plain(s):
    return re.sub(r'\x1b\[[0-9;=?]*[a-zA-Z]', '', s).replace('\r', '')

def main():
    keep = '-k' in sys.argv[1:]
    r = subprocess.run(['mk', 'CONF=u386', '9u386'], cwd='os/osprey/pc',
                       env=env, capture_output=True, text=True)
    if r.returncode != 0:
        print('FAIL 9u386 did not build')
        print(r.stdout[-800:]); print(r.stderr[-800:])
        return 1

    log = tempfile.mktemp(prefix='osprey-micro386-', suffix='.log')
    q = subprocess.Popen(['qemu-system-i386', '-m', '256', '-smp', '2',
                          '-display', 'none', '-monitor', 'none', '-no-reboot',
                          '-serial', 'file:' + log,
                          '-kernel', KERNEL, '-append', 'console=0'],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # until the idle line or a panic, rather than for the whole timeout
    t = ''
    deadline = time.time() + TIMEOUT
    while time.time() < deadline and q.poll() is None:
        time.sleep(1)
        try:
            t = plain(open(log, errors='replace').read())
        except OSError:
            t = ''
        if 'osprey micro: idle' in t or 'panic' in t:
            time.sleep(1)
            break
    if q.poll() is None:
        q.kill()
    q.wait()
    try:
        t = plain(open(log, errors='replace').read())
    except OSError:
        t = ''

    with open(KERNEL, 'rb') as f:
        magic = int.from_bytes(f.read(4), 'big')

    results = []
    results.append(("the kernel built is a 386 image (Plan 9 a.out magic 0x1eb)",
                    magic == 0x1eb))
    #
    # Two processors, as the amd64 checks run: the second is started by
    # mpstartap through the warm-reset vector and the real-mode
    # apbootstrap, and it says so itself in cpuidprint.  Until the
    # header-stripping rule was fixed the AP began eight bytes into that
    # bootstrap and took the machine down two seconds into the boot.
    #
    results.append(("and its second processor starts and identifies itself",
                    re.search(r'cpu1: \d+MHz', t) is not None))
    results.append(("the 386 microkernel boots into a task, not the Plan 9 shell",
                    'osprey micro: a task, no plan 9 boot' in t
                    and 'proc0: groups' not in t))
    m = re.search(r'osprey micro: (\d+) of 4 requests answered', t)
    results.append(("and its message ring answers every request a task submits",
                    m is not None and m.group(1) == '4'))
    results.append(("and it reaches its idle loop rather than panicking",
                    'osprey micro: idle' in t and 'panic' not in t))
    results.append(("and a kernel task exits through pexit and the stubbed group closes cleanly",
                    'osprey micro: a kernel task exited, teardown clean' in t
                    and 'panic' not in t))
    results.append(("and the bare console writes straight to the 8250, owing nothing to a device",
                    'osprey micro: bare console (kdebugputc) works' in t))
    results.append(("and a select over arms wakes on a real interrupt, the clock's, with no name space",
                    'osprey micro: a select woke on the clock interrupt' in t))
    results.append(("and a container answers another's open by delegation, which the kernel's cut personality could not",
                    'osprey micro: a delegated open was answered by a server container' in t
                    and 'panic' not in t))

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
