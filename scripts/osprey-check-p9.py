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
server's file opened and read by file descriptor, with no panic --
and then that a program loaded beside the personality can start other
programs and wait for them, so a shell runs a script with a pipeline in
it, two programs alive at once in the one address space.

usage: scripts/osprey-check-p9.py [-k]
"""
import re
import os, re, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
env = dict(os.environ, PATH=os.path.join(ROOT, 'MacOSX/arm64/bin') + ':' + os.environ['PATH'])

def plain(s):
    return re.sub(r'\x1b\[[0-9;=?]*[a-zA-Z]', '', s)


def readppm(path):
    """QEMU's screendump, a binary P6."""
    try:
        d = open(path, 'rb').read()
    except OSError:
        return None
    if not d.startswith(b'P6'):
        return None
    fields, i = [], 2
    while len(fields) < 3:
        while i < len(d) and d[i:i+1].isspace():
            i += 1
        if d[i:i+1] == b'#':
            while i < len(d) and d[i:i+1] != b'\n':
                i += 1
            continue
        j = i
        while j < len(d) and not d[j:j+1].isspace():
            j += 1
        fields.append(int(d[i:j]))
        i = j
    i += 1
    w, h, _ = fields
    return w, h, d[i:i + w*h*3]


def boxof(pix, colour, w):
    """How many pixels are exactly this colour and the box they lie in."""
    tri = bytes(colour)
    n = 0
    x0 = y0 = 1 << 30
    x1 = y1 = -1
    i = pix.find(tri)
    while i >= 0:
        if i % 3 == 0:
            n += 1
            q = i // 3
            x, y = q % w, q // w
            if x < x0: x0 = x
            if x > x1: x1 = x
            if y < y0: y0 = y
            if y > y1: y1 = y
        i = pix.find(tri, i+1)
    return n, (x0, y0, x1, y1)

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
    shot = tempfile.mktemp(prefix='osprey-p9-', suffix='.ppm')
    subprocess.run(['./scripts/osprey-console.py', '-q', '-p', '2', '-n', 'e1000',
                    '-l', log, '-S', '-d', ROOT + '/.qemu/9front-root.qcow2',
                    '-t', '150', '-u', 'the microkernel idles', '--shot', shot],
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
                    re.search(r'opened / and read [5-9]\d\d bytes of directory through the name space', t) is not None))
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
    results.append(("and it duplicates a descriptor, the two sharing one channel and offset (what a shell redirects with)",
                    'the rest on its dup fd 2: " from the 9P server' in t))
    results.append(("and it loads a second program and runs it: the personality reads /boot/prog2 through the name space it built, asks the kernel only for the address space, lays the binary in it and calls its entry - the loading a library operating system does for itself",
                    re.search(r'osprey user: \d+ bytes of address space at 0x1000000 for a program the caller loads itself', t) is not None
                    and re.search(r'p9 exec: /boot/prog2: text \d+, data \d+, bss \d+; \d+ bytes of address space at 0x1000000, entry 0x1000028', t) is not None
                    and 'prog2: I am the second program on the library-OS personality, loaded into its address space and called by it' in t))
    results.append(("and that program reaches the file system by calling the personality, not by trapping: it opens and reads /greeting through the entry points it was handed, in its own address space",
                    'prog2: opened and read /greeting by calling the personality, no trap and no ring: "hello osprey"' in t))
    results.append(("and the name space under it is the one the first program built, still live: the second program creates a file in it and the first reads that file back afterwards, the personality never reloaded",
                    'prog2: created #e/fromprog2 through the same name space and wrote it' in t
                    and 'p9 exec: /boot/prog2 returned; the personality is still here, its name space never reloaded' in t
                    and 'p9: read what the second program wrote, through the same name space: "written by the second program"' in t))
    results.append(("and a real command runs on it: /boot/libcat is catp9.c, the same source as the cat that runs under the buddy on the server personality with no line changed, linked against the personality instead of against a kernel's system calls - it takes an argument vector, grows a heap, opens a file, dups the descriptor, asks its path and reads it, and every one of those is a call in its own address space",
                    'cat: started with 2 arguments; argv[0] = /boot/libcat' in t
                    and re.search(r'cat: sbrk grew the heap \d+ bytes at [0-9a-f]+, now to [0-9a-f]+; \d+ bytes written and read back, 0 wrong', t) is not None
                    and re.search(r"cat: dup'd descriptor \d+ to \d+ through the buddy; /hello through the duplicate ->", t) is not None
                    and re.search(r'cat: descriptor \d+ is /hello, by fd2path', t) is not None))
    results.append(("and the file it reads is the 9P server's, across the ring: the command names /hello with no device in it and the personality resolves it through its own mount, so a program with no kernel personality under it reads a file another container holds",
                    'hello from the 9P server, a container across the ring' in t
                    and 'cat: <- end of /hello through the duplicate' in t))
    results.append(("and the command exits into the personality that loaded it, not out of the task: exit is a call to the loader here, so the operating system outlives the program it ran",
                    'p9 exec: /boot/libcat exited with status "", into the personality that loaded it, not out of the task' in t
                    and 'p9 exec: /boot/libcat returned; the personality is still here, its name space never reloaded' in t))
    results.append(("and a shell runs on it, with processes under it: the personality starts a program on a flow of control of its own - a kproc with a descriptor table of its own, built empty and holding only what it was handed - and the shell waits for it and reads its status, which is what a library operating system has instead of fork and exec (a library cannot split its caller's C stack, so spawn is the two fused)",
                    re.search(r'libsh: \d+ bytes of script, read by calling the personality beside me', t) is not None
                    and re.search(r'p9 spawn: /boot/libcat runs as \d+ at 0x1400000, with its own descriptor table \(-1 -1 -1\)', t) is not None
                    and 'libsh: /boot/libcat ended, status ""' in t))
    results.append(("and it runs a pipeline: two spawned programs at two addresses, each with its own descriptor table, the first's standard output and the second's standard input the two ends of one pipe of the personality's - and the shell closes its own copies, which is the only reason the far end ever sees end of file",
                    re.search(r'p9 spawn: /boot/libcat runs as \d+ at 0x1400000, with its own descriptor table \(-1 0 -1\)', t) is not None
                    and re.search(r'p9 spawn: /boot/libwc runs as \d+ at 0x1800000, with its own descriptor table \(0 -1 -1\)', t) is not None
                    and 'libwc: 8 lines 79 words 454 bytes off the pipe, read as a call into the personality' in t))
    results.append(("and the two stages are alive at once, not one after the other: 200000 bytes cross a pipe that holds 32768, so the writer blocks and the reader must run to drain it - six times over - and every byte arrives, counted at the far end",
                    'p9: a pipe holds 32768 bytes before its writer waits for its reader' in t
                    and re.search(r'p9 spawn: /boot/libgen runs as \d+ at 0x2000000', t) is not None
                    and 'libwc: 3125 lines 3125 words 200000 bytes off the pipe' in t
                    and 'libgen: the write failed' not in t))
    results.append(("and the limit it documents is enforced, not merely written down: the last line of the script asks for two of one image at once and the second is refused by name, because a program is at the address it was linked for and nothing here relocates it - the two would be the one image sharing its one data segment, descriptor table and heap - and the shell carries on",
                    'p9 exec: /boot/libcat is already running at 0x1400000; it is one image and cannot be two programs' in t
                    and 'libsh: /boot/libcat: cannot start it' in t))
    results.append(("and a spawned program that fails ends with the failure as its status: the stage that was started writes into a pipe whose reader never arrived, the personality answers -1 and a reason the way a libc does, and the program makes that reason its exit status, which the shell reads out of the wait",
                    'cat: write failed: Ehungup' in t
                    and 'libsh: /boot/libcat ended, status "Ehungup"' in t
                    and 'libsh: the script is done, and the personality that started me is still here' in t))
    results.append(("and the shell ends into the personality that loaded it, having run its script, with the name space it and its programs shared still the one the personality built",
                    'libsh: the script is done, and the personality that started me is still here' in t
                    and 'p9 exec: /boot/libsh returned; the personality is still here, its name space never reloaded' in t))
    #
    # The screen.  What the program paints is written in drawlibp9.c and
    # here, and both were written before the machine was ever booted:
    # the whole screen 0x112233 and the rectangle (200,150)-(600,450)
    # 0xCC7722.  400 by 300 is 120000 pixels of the one and the rest of
    # 1280 by 800 - 904000 - of the other, and the box the first lie in
    # is that rectangle, its far edge exclusive as a Plan 9 rectangle's
    # is.  Exact counts, because nothing dithers a frame buffer and
    # nothing else is drawing on this configuration: there is no mouse
    # driver on it, so the pointer page stays unreported and the draw
    # server's arrow is never composited.
    pix = readppm(shot)
    pw = ph = 0
    nfore = nback = 0
    fbox = (0, 0, 0, 0)
    if pix is not None:
        pw, ph, pd = pix
        nfore, fbox = boxof(pd, (0xcc, 0x77, 0x22), pw)
        nback, _ = boxof(pd, (0x11, 0x22, 0x33), pw)
    results.append(("and a program that draws runs on it: /boot/libdraw opens /dev/draw for a client of its own, reads the twelve fields that say what the screen is, and writes the draw protocol into it - and that /dev/draw is the kernel's own devdraw.c compiled into this personality, so the write is a call in the program's own address space and the protocol crosses no boundary at all",
                    re.search(r'libdraw: client \d+, the screen is 0 0 1280 800,\s*x8r8g8b8\s*, through /dev/draw of the personality that loaded me', t) is not None
                    and 'libdraw: painted the screen 112233 and 200 150 600 450 cc7722' in t))
    results.append(("and the pixels are on the display: the screen QEMU scans out is 1280x800 and holds exactly 120000 pixels of 0xCC7722 in the rectangle (200,150)-(600,450) and 904000 of 0x112233 everywhere else - the counts and the box written down before the machine was booted, because a library operating system drawing on the firmware frame buffer either lands there or does not",
                    pix is not None and (pw, ph) == (1280, 800)
                    and nfore == 400*300 and fbox == (200, 150, 599, 449)
                    and nback == 1280*800 - 400*300))
    results.append(("and it exits through the microkernel's minimal syscall interface, no in-kernel personality",
                    'the program exited' in t and 'panic' not in t))

    bad = 0
    for what, ok in results:
        print('%-4s %s' % ('ok' if ok else 'FAIL', what))
        if not ok:
            bad += 1
    print('the screen is %dx%d: %d of 0xCC7722 in %r, %d of 0x112233'
          % (pw, ph, nfore, fbox, nback))
    if keep or bad:
        print('log %s' % log)
        print('shot %s' % shot)
    else:
        for f in (log, shot, shot + '.qmp'):
            try: os.unlink(f)
            except OSError: pass
    return 1 if bad else 0

sys.exit(main())
