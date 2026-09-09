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
    # Two screendumps, because the screen is painted twice and the
    # second painting takes the whole of it.  /boot/libdraw paints by
    # hand first, pauses, and then runs the real libdraw, whose
    # gengetwindow allocates a window over the whole screen and clears
    # it - which is what any Plan 9 graphics program does.  The first
    # shot fires the moment the hand-written paint reports itself, while
    # the program is in that pause; the second at the end of the run.
    rawshot = tempfile.mktemp(prefix='osprey-p9-raw-', suffix='.ppm')
    subprocess.run(['./scripts/osprey-console.py', '-q', '-p', '2', '-n', 'e1000',
                    '-l', log, '-S', '-d', ROOT + '/.qemu/9front-root.qcow2',
                    '-t', '150', '-u', 'the microkernel idles', '--shot', shot,
                    '--shot-at',
                    'libdraw: painted the screen 112233 and 200 150 600 450 cc7722=' + rawshot],
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
    results.append(("and a write that is refused leaves the descriptor's offset where it found it: the write path advances the channel's offset before it calls the device and winds it back by what the device did not take, so a write into a pipe with no reader - which takes none of it - must come back to the offset it started at, a drift there showing up only on some later write to the same channel",
                    re.search(r"p9: a write of 19 bytes into a pipe with no reader was refused \([^)]+\); the write end's offset was 0 before and 0 after", t) is not None))
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
    # here, and both were written before the machine was ever booted.
    # The program paints twice.  First by hand, writing the draw
    # protocol into /dev/draw itself: the whole screen 0x112233 and the
    # rectangle (200,150)-(600,450) 0xCC7722.  Then through the real
    # libdraw, built from source in 9front/src and linked unmodified:
    # (700,150)-(1100,450) 0x33AA55 with a string written in black
    # inside it.
    #
    # 400 by 300 is 120000 pixels of each rectangle, and 1280 by 800
    # less the two of them - 784000 - is what is left of the
    # background.  The libdraw rectangle is 120000 too, but split
    # between its own colour and the glyphs of the string, so the two
    # counts are added and the black is required to be some of it: a
    # rectangle with no string in it would pass a test that only counted
    # 0x33AA55, and it would mean the font never built.  Each box is the
    # rectangle it was asked for, its far edge exclusive as a Plan 9
    # rectangle's is.
    #
    # Exact counts, because nothing dithers a frame buffer and nothing
    # else is drawing on this configuration: there is no mouse driver on
    # it, so the pointer page stays unreported and the draw server's
    # arrow is never composited.
    raw = readppm(rawshot)
    rw = rh = 0
    nfore = nback = 0
    fbox = (0, 0, 0, 0)
    if raw is not None:
        rw, rh, rd = raw
        nfore, fbox = boxof(rd, (0xcc, 0x77, 0x22), rw)
        nback, _ = boxof(rd, (0x11, 0x22, 0x33), rw)

    pix = readppm(shot)
    pw = ph = 0
    nlib = ntext = nwhite = nfore2 = nback2 = 0
    lbox = tbox = (0, 0, 0, 0)
    if pix is not None:
        pw, ph, pd = pix
        nlib, lbox = boxof(pd, (0x33, 0xaa, 0x55), pw)
        ntext, tbox = boxof(pd, (0x00, 0x00, 0x00), pw)
        nwhite, _ = boxof(pd, (0xff, 0xff, 0xff), pw)
        nfore2, _ = boxof(pd, (0xcc, 0x77, 0x22), pw)
        nback2, _ = boxof(pd, (0x11, 0x22, 0x33), pw)

    def inside(box, r):
        return box[0] >= r[0] and box[1] >= r[1] and box[2] <= r[2] and box[3] <= r[3]
    results.append(("and a program that draws runs on it: /boot/libdraw opens /dev/draw for a client of its own, reads the twelve fields that say what the screen is, and writes the draw protocol into it - and that /dev/draw is the kernel's own devdraw.c compiled into this personality, so the write is a call in the program's own address space and the protocol crosses no boundary at all",
                    re.search(r'libdraw: client \d+, the screen is 0 0 1280 800,\s*x8r8g8b8\s*, through /dev/draw of the personality that loaded me', t) is not None
                    and 'libdraw: painted the screen 112233 and 200 150 600 450 cc7722' in t))
    results.append(("and the pixels are on the display: the screen QEMU scans out while that program pauses is 1280x800 and holds exactly 120000 pixels of 0xCC7722 in the rectangle (200,150)-(600,450) and 904000 of 0x112233 everywhere else - the counts and the box written down before the machine was booted, because a library operating system drawing on the firmware frame buffer either lands there or does not",
                    raw is not None and (rw, rh) == (1280, 800)
                    and nfore == 400*300 and fbox == (200, 150, 599, 449)
                    and nback == 1280*800 - 400*300))
    results.append(("and the pause it was photographed in is the personality's own sleep, which was a system call the microkernel does not answer until now: the program asks for 4000 ms and nsec(2) - libc reading /dev/bintime through the personality's pread, not a trap - says it slept about that long",
                    re.search(r'libdraw: asked to sleep 4000 ms and slept (\d+), timed by nsec through /dev/bintime', t) is not None
                    and 3500 <= int(re.search(r'and slept (\d+), timed by nsec', t).group(1)) <= 8000))
    #
    # And the same screen through the real library.  initdraw is not a
    # call the personality was written for: it opens /dev/draw, reads the
    # twelve fields, opens the client's data and refresh files, builds
    # the default font out of libdraw's own compiled-in subfont, reads
    # /dev/winname and attaches to the image named there.  Every one of
    # those is a call into the personality in the program's own address
    # space, and three of them - pread, fstat, sleep - were libc system
    # calls that this microkernel does not answer until now.
    results.append(("and then the real libdraw runs on it, unmodified: initdraw opens /dev/draw, reads /dev/winname, attaches to the image the draw device named there, and builds the default font out of libdraw's own compiled-in subfont - all of it calling the personality in the program's own address space",
                    re.search(r'libdraw: initdraw: display image 0 0 1280 800, screen "noborder\.screen\.\d+" 0 0 1280 800, chan x8r8g8b8, font \*default\* 16 high', t) is not None))
    results.append(("and it draws with it: allocimage, draw and string paint (700,150)-(1100,450) 0x33AA55 with a line of text in it",
                    re.search(r'libdraw: real libdraw painted 700 150 1100 450 33aa55 and wrote "the library is the operating system" from 720 290 to \d+ 290', t) is not None))
    results.append(("and those pixels are on the display too, on a screen that is now libdraw's: the second screendump has 120000 pixels of 0x33AA55 and black glyphs together, all of them inside (700,150)-(1100,450) with the black a real part of it, and 904000 of white around them - and not one pixel of either colour the first half painted, because gengetwindow took the whole screen for a window and cleared it, which is what an ordinary Plan 9 graphics program does",
                    pix is not None and (pw, ph) == (1280, 800)
                    and nlib + ntext == 400*300
                    and ntext > 0
                    and inside(lbox, (700, 150, 1099, 449))
                    and inside(tbox, (700, 150, 1099, 449))
                    and nwhite == 1280*800 - 400*300
                    and nfore2 == 0 and nback2 == 0))
    #
    # And a threaded program.  The link of /boot/libthread leaves out the
    # prebuilt libc.a - the archive of generated system-call stubs -
    # altogether and resolves, so every call it and its libc make is
    # either the personality's through the table or code in its own
    # image, and the one system call a threaded program makes here is
    # the console.  That it ran at all is what says so.
    results.append(("and a threaded program runs on it: /boot/libthread is an ordinary Plan 9 libthread program on the real libthread built from source in 9front/src, its port being threadmain9.c - the four functions 9front keeps in libthread/main.c because they are the system a port has to supply - and its link leaves the prebuilt archive of system-call stubs out altogether and still resolves",
                    re.search(r'libthread: threadmain runs with 1 arguments, as thread \d+ of proc \d+', t) is not None))
    results.append(("and its threads hand values to each other: five values cross an unbuffered channel between two threads of one proc and sum to 15, which is a hand-off rather than a buffer - the sender blocks until the receiver takes each one, so neither thread could get through this alone and libthread's own scheduler is what runs the other",
                    'libthread: 5 values crossed an unbuffered channel between two threads of one proc, summing to 15' in t
                    and 'libthread: that is not the' not in t))
    #
    # And a proc of its own.  proccreate is a second flow of control
    # inside one program, which is what rfork(RFPROC|RFMEM) is on Plan 9
    # and what a kproc of the personality's cooperative scheduler is
    # here.  The two pids must differ: getpid on this personality is the
    # flow's own number, and two flows reading one number would mean the
    # per-process word the whole mechanism rests on was not per-process.
    m = re.search(r'libthread: the second proc runs as (\d+), and the first was (\d+)', t)
    results.append(("and a program can have a second flow of control of its own: proccreate is libthread's _schedfork, and where Plan 9 answers it with rfork(RFPROC|RFMEM) - whose child gets a copy of the stack at the same addresses and longjmps onto it - this personality starts the new flow at a function, because two stacks cannot be at one address in one address space",
                    'gets a second flow of control as' in t
                    and m is not None and m.group(1) != m.group(2)))
    results.append(("and values cross a channel between the two of them: five more, summing to 15, and this is not the same mechanism as between threads of one proc - the receiving proc has no ready thread and sleeps, and the sending proc wakes it, so this is the personality's own rendezvous and the per-process word that tells each flow which Proc it is running",
                    'libthread: 5 values crossed the same channel from a proc of its own, summing to 15' in t
                    and 'libthread: that is not the' not in t))
    results.append(("and the personality waits for a flow of control a program made for itself, in a way that lets the clock keep moving: the second proc sleeps 300 ms past the end of the first, and the wait is a timed sleep rather than a yield - a yield would sit on the run queue, the queue would never be empty, the cooperative clock would never advance and the sleeping proc would never wake, so the two would wait for each other for good",
                    'libthread: the second proc slept 300 ms past the end of the first, and the personality waited for it' in t
                    and '/boot/libthread returned; the personality is still here' in t))
    #
    # Relocation.  Every other program here is laid at the address it was
    # linked for, which is why p9lib.h has one base per program and why
    # the shell is told it cannot run two of an image at once.
    # /boot/reloc has no address of its own - 6l -u linked it at 0 and
    # gave it a table of every absolute address in it - so it is laid
    # twice, at two bases, and the same module runs at both.  The
    # arithmetic it prints is over a table of function pointers and a
    # table of string pointers, both in its data: a pointer that was not
    # corrected is a wrong number or a fault, not a subtly different
    # string.
    laid = re.findall(r'p9 reloc: /boot/reloc laid at (0x[0-9a-f]+), \d+ bytes, '
                      r'(\d+) absolute addresses corrected; it was linked at 0', t)
    ran = re.findall(r'reloc: 5 function pointers summing to 15, '
                     r'5 string pointers of total length 21: '
                     r'"relocation is the way out"', t)
    results.append(("and a program with no address of its own is laid at one the loader chooses: /boot/reloc is a relocatable module, linked at 0 with a table of every absolute address in it, and the loader corrects each as it lays it down",
                    len(laid) == 2 and laid[0][0] != laid[1][0]
                    and laid[0][1] == laid[1][1] and int(laid[0][1]) > 0))
    results.append(("and the same module runs at two addresses at once, which is the thing the fixed bases cannot do: both copies read their own function and string pointers correctly, so every absolute address in each was corrected to the base it was put at",
                    len(ran) == 2 and 'reloc: that is not the' not in t))
    results.append(("and it exits through the microkernel's minimal syscall interface, no in-kernel personality",
                    'the program exited' in t and 'panic' not in t))

    bad = 0
    for what, ok in results:
        print('%-4s %s' % ('ok' if ok else 'FAIL', what))
        if not ok:
            bad += 1
    print('the first screen is %dx%d: %d of 0xCC7722 in %r, %d of 0x112233'
          % (rw, rh, nfore, fbox, nback))
    print('the second is %dx%d: %d of 0x33AA55 in %r, %d of black in %r, '
          '%d white, %d of 0xCC7722, %d of 0x112233'
          % (pw, ph, nlib, lbox, ntext, tbox, nwhite, nfore2, nback2))
    if keep or bad:
        print('log %s' % log)
        print('shot %s' % shot)
        print('raw shot %s' % rawshot)
    else:
        for f in (log, shot, rawshot, shot + '.qmp'):
            try: os.unlink(f)
            except OSError: pass
    return 1 if bad else 0

sys.exit(main())
