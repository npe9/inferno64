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
directory was read through it, a second device was mounted and a
name resolved across the mount table into it, a 9P server
mounted over the microkernel ring - the server a container of its
own - its file read back across #M, and both a local file and the
server's file opened and read by file descriptor, with no panic.

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
    results.append(("and it mounts a second device and resolves a name with no device prefix across the mount table into it",
                    'resolved /greeting through the mount table and read \"hello osprey\"' in t))
    m = re.search(r'served by device type=(\d+) \(mnt=(\d+)\)', t)
    results.append(("and it mounts a 9P server over a transport and resolves a name across #M, served by the mount device not the transport",
                    m is not None and m.group(1) == m.group(2)))
    results.append(("and the file's bytes come back over 9P across the microkernel ring from a server container (Tversion/Tattach/Twalk/Topen/Tread through devmnt)",
                    'read from the 9P server over the mount: "hello from the 9P server, a container across the ring' in t))
    results.append(("and a program reaches the name space by file descriptor (open/read/close over an fd table), naming both a local file and the file the 9P server holds",
                    'from /greeting through the name space' in t and 'from /hello over the ring' in t))
    results.append(("and it lists the server's directory by descriptor over 9P, unpacking a stat entry per file",
                    'motd (69 bytes)' in t and 'readme (56 bytes)' in t))
    results.append(("and it writes a file the server holds and reads it back, a full read-write round trip over 9P by descriptor",
                    'wrote 48 bytes to /scratch over the ring' in t and 'read /scratch back over the ring: "a program on the personality wrote this over 9P' in t))
    m2 = re.search(r'exportfs served (\d+) entries from the personality', t)
    results.append(("and the personality is itself a 9P server: it exports its own name space and reads its root back over 9P (a loopback mount)",
                    'exportfs loopback' in t and m2 is not None and int(m2.group(1)) >= 10))
    results.append(("and it stats a file and seeks within it by descriptor - metadata and random access, not just sequential reads",
                    'stat /hello: name hello, length 54' in t and 'after seek to 6, read "from the 9P server' in t))
    results.append(("and it creates a file by name and binds a device onto a name, reading the file back across the binding",
                    'created #e/bound' in t and 'read /mnt/bound across the binding: "reached through a bind' in t))
    m3 = re.search(r'the union listing spanned (\d+) entries', t)
    results.append(("and a union directory read of \"/\" composes the root device, the environment and the 9P mount into one listing",
                    'ls / (a union' in t and m3 is not None and int(m3.group(1)) >= 18))
    results.append(("and the name space carries a pipe - two ends of a channel a program talks through, written and read",
                    'wrote one end of a pipe, read the other: "sent through a pipe"' in t))
    m4 = re.search(r'looked up /srv/export, mounted it, read (\d+) entries', t)
    results.append(("and it publishes a service in /srv by name, then looks it up and mounts it (how Plan 9 name spaces compose services)",
                    'posted the personality' in t and m4 is not None and int(m4.group(1)) >= 10))
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
