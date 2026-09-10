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
    # the program is in that pause; the second when that program is done
    # painting.
    #
    # The second used to fire at the end of the run, which was the same
    # thing while /boot/libdraw was the last program to touch the
    # screen.  rio is not: it runs afterwards, calls initdraw and takes
    # the whole screen for itself, so a shot at the end of the run
    # photographs rio's screen and says nothing about libdraw's.  The
    # shot is taken where the claim is, which is where the painting
    # ends.
    rawshot = tempfile.mktemp(prefix='osprey-p9-raw-', suffix='.ppm')
    subprocess.run(['./scripts/osprey-console.py', '-q', '-p', '2', '-n', 'e1000',
                    '-l', log, '-S', '-d', ROOT + '/.qemu/9front-root.qcow2',
                    '-t', '150', '-u', 'the microkernel idles',
                    '--shot-at',
                    'libdraw: painted the screen 112233 and 200 150 600 450 cc7722=' + rawshot,
                    '--shot-at',
                    r'libdraw: real libdraw painted 700 150 1100 450 33aa55=' + shot],
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
                    re.search(r'osprey user: \d+ bytes of address space at 0x1c00000 for a program the caller loads itself', t) is not None
                    and re.search(r'p9 exec: /boot/prog2: text \d+, data \d+, bss \d+; \d+ bytes of address space at 0x1c00000, entry 0x1c00028', t) is not None
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
                    and re.search(r'p9 spawn: /boot/libcat runs as \d+ at 0x[0-9a-f]+, with its own descriptor table \(-1 -1 -1\)', t) is not None
                    and 'libsh: /boot/libcat ended, status ""' in t))
    def scriptline(t, cmd):
        """What the log says while one line of the shell's script runs.

        The shell echoes each line as "libsh: <line>", and one of those
        lines is a prefix of another, so the match is on the whole line
        and the slice ends at the next line the shell echoes.  Scoping
        by line is the point: several script lines spawn the same
        programs, and a criterion that searched the whole log would take
        one line's spawns for another's - which is how the "cat | cat"
        criterion broke when a five-stage line was added below it.
        """
        def echo(l):
            # The shell says three things that begin this way: the line
            # it is about to run, "<program> ended, status ..." and
            # "<program>: cannot start it".  Only the first is a
            # boundary.
            return (l.startswith('libsh: /boot/')
                    and ' ended, status ' not in l
                    and not l.endswith(': cannot start it'))

        lines = [l.strip() for l in t.split('\n')]
        want = 'libsh: ' + cmd
        for i, l in enumerate(lines):
            if l == want:
                for j in range(i + 1, len(lines)):
                    if echo(lines[j]):
                        return '\n'.join(lines[i:j])
                return '\n'.join(lines[i:])
        return ''

    def wcslot(t):
        """The address the loader gave a wc, if it gave it a slot."""
        for a in re.findall(r'p9 spawn: /boot/libwc runs as \d+ at (0x[0-9a-f]+), '
                            r'with its own descriptor table \(0 -1 -1\)', t):
            if int(a, 16) >= 0x2c00000:
                return a
        return None

    results.append(("and it runs a pipeline: two spawned programs at two addresses, each with its own descriptor table, the first's standard output and the second's standard input the two ends of one pipe of the personality's - and the shell closes its own copies, which is the only reason the far end ever sees end of file",
                    re.search(r'p9 spawn: /boot/libcat runs as \d+ at 0x[0-9a-f]+, with its own descriptor table \(-1 0 -1\)', t) is not None
                    # wc has no fixed address any more: it is a module,
                    # so the far end of the pipeline is wherever the
                    # loader put it, and what is required is that it be
                    # a slot rather than a particular number.
                    and wcslot(t) is not None
                    and 'libwc: 8 lines 79 words 454 bytes off the pipe, read as a call into the personality' in t))
    results.append(("and the two stages are alive at once, not one after the other: 200000 bytes cross a pipe that holds 32768, so the writer blocks and the reader must run to drain it - six times over - and every byte arrives, counted at the far end",
                    'p9: a pipe holds 32768 bytes before its writer waits for its reader' in t
                    and re.search(r'p9 spawn: /boot/libgen runs as \d+ at 0x2000000', t) is not None
                    and 'libwc: 3125 lines 3125 words 200000 bytes off the pipe' in t
                    # No failed write in THIS pipeline.  The guard is
                    # scoped by position, not by the message being absent
                    # from the log: a later line of the same script makes
                    # a generator's write fail on purpose, and the bare
                    # "the message is absent" form this replaces was
                    # broken the moment that line was added.  Everything
                    # up to the count above belongs to this pipeline.
                    and 'libgen: the write failed'
                        not in t[:t.index('libwc: 3125 lines 3125 words 200000 bytes off the pipe')]))
    #
    # The two halves of one claim, in two lines of the same script.  cat
    # is a relocatable module, so two of it run in one pipeline, each in
    # a slot the loader took.  gen still is its address, so two of it
    # cannot, and the refusal is by name.
    twocats = scriptline(t, '/boot/libcat /hello | /boot/libcat')
    catpipe = re.findall(r'p9 spawn: /boot/libcat runs as \d+ at (0x[0-9a-f]+), '
                         r'with its own descriptor table \((?:-1 0 -1|0 -1 -1)\)', twocats)
    results.append(("and two of one image run in one pipeline, because that image is a module: cat is linked relocatable, so the shell's \"cat | cat\" gets two copies at two slots the loader chose, reading and writing the two ends of one pipe",
                    twocats != ''
                    and len(catpipe) == 2 and catpipe[0] != catpipe[1]
                    and twocats.count('libsh: /boot/libcat ended, status ""') >= 2))
    #
    # A slot is ground for whatever module goes in it next, so it is
    # asked for at the size a slot is - not at the size of the module
    # that happened to be laid in it first.  A program at a base of its
    # own is asked for at its own size, because nothing else is ever
    # laid there.  Both are in the same boot, and the two numbers are
    # different by more than a rounding.
    attachments = re.findall(
        r'p9 load: (\d+) bytes of address space at (0x[0-9a-f]+) for (\S+), '
        r'attachment (\d+) of (\d+)', t)
    slotsized = [a for a in attachments if int(a[0]) == 0x400000]
    ownsized = [a for a in attachments if int(a[0]) < 0x400000]
    # One of each is the claim - that the two kinds are asked for
    # differently and both are in this boot.  Counting the fixed-base
    # ones would make this fail the day one more of them becomes a
    # module, which is a change to celebrate rather than to trip over.
    results.append(("and a relocation slot is ground the size of a slot, not the size of the module first laid in it: a slot holds one module and then another, and the second may be the larger, so the region asked of the kernel is the whole slot - while a program at a base of its own is asked for at its own size, which is smaller, and the same boot shows both",
                    len(slotsized) >= 2
                    and all(int(a[1], 16) >= 0x2c00000 for a in slotsized)
                    and len(ownsized) >= 1
                    and all(int(a[1], 16) < 0x2c00000 for a in ownsized)))
    #
    # And the record of it has a size in it.  The base alone would let a
    # module be laid in a region attached for a smaller one, which is a
    # program writing past its ground and a fault a long way from the
    # cause.  The count is checked because the old table held eight and
    # this boot takes eight: it was exactly full, and one more program
    # made into a module would have overflowed it in silence.
    results.append(("and the loader has not quietly run out of the ground it remembers: every attachment this boot takes is recorded with the size it was given, none is refused for want of a record, and the count is reported rather than left to be guessed",
                    len(attachments) >= 8
                    and 'attachment records are taken' not in t
                    and all(int(a[3]) == i + 1 for i, a in enumerate(attachments))
                    and int(attachments[-1][4]) > len(attachments)))
    #
    # Three modules alive at once, in three slots.  The number at the
    # far end is the whole of what both cats said as well as the file:
    # print on this personality writes descriptor 1, so a stage's own
    # narration goes into its pipe rather than to the console, and the
    # last stage counts all of it.  454 of that is the first cat and the
    # file, which is what the two-stage line above counts; the other 191
    # is the middle cat, whose descriptor 1 is the second pipe rather
    # than the console.
    three = scriptline(t, '/boot/libcat /hello | /boot/libcat | /boot/libwc')
    trio = re.findall(r'p9 spawn: /boot/lib(?:cat|wc) runs as \d+ at (0x[0-9a-f]+)', three)
    results.append(("and three modules run in one pipeline, in three slots: \"cat | cat | wc\" is two copies of one image and a third of another, none of them at an address of its own, and what the far end counts is the file and everything both cats said on the way - 454 bytes of it the first cat and the file, the other 191 the middle cat, whose descriptor 1 is the second pipe and not the console",
                    len(trio) == 3 and len(set(trio)) == 3
                    and all(int(a, 16) >= 0x2c00000 for a in trio)
                    and 'libwc: 11 lines 114 words 645 bytes off the pipe' in three))
    #
    # And every slot at once.  The shell is a module as well now, so it
    # holds one for as long as its script runs and a five-stage pipeline
    # under it is six modules in six slots - which is all of them.  A
    # count of slots nothing ever reaches would say nothing about them,
    # and the shell's own stage limit was raised to five for this.
    five = scriptline(t, '/boot/libcat /hello | /boot/libcat | /boot/libcat | '
                         '/boot/libcat | /boot/libwc')
    quints = re.findall(r'p9 spawn: /boot/lib(?:cat|wc) runs as \d+ at (0x[0-9a-f]+)', five)
    shslot = re.search(r'p9 reloc: /boot/libsh laid at (0x[0-9a-f]+),', t)
    results.append(("and every relocation slot the personality has is held at once, by the shell and the pipeline under it: the shell is a module too, so it keeps a slot for as long as its script runs, and a five-stage pipeline beside it is six modules in six slots with no slot left over - the count is reached rather than written down",
                    len(quints) == 5 and len(set(quints)) == 5
                    and all(int(a, 16) >= 0x2c00000 for a in quints)
                    and shslot is not None
                    and shslot.group(1) not in quints
                    and 'slots are taken' not in t
                    and five.count('libsh: /boot/libcat ended, status ""') >= 4
                    and 'libsh: /boot/libwc ended, status ""' in five
                    # And the bytes went the length of it.  Five stages
                    # that exited clean while relaying nothing would
                    # pass everything above.  1027 is the arithmetic the
                    # three-stage line establishes: 454 for the file and
                    # the first cat, and 191 more for each cat that
                    # relays it, of which there are three.
                    and 'libwc: 17 lines 184 words 1027 bytes off the pipe' in five))
    #
    # The shell itself is one, which is the exec path rather than the
    # spawn path: p9exec takes a slot for a module and gives it back,
    # and until the shell was a module nothing had ever gone that way.
    results.append(("and the shell itself has no address of its own: it is the program the personality execs rather than one the shell spawns, so it is p9exec that takes a slot for it and frees it - a path that had never run while every program the personality execs was linked at a base",
                    shslot is not None and int(shslot.group(1), 16) >= 0x2c00000
                    and re.search(r'p9 exec: entering /boot/libsh at 0x[0-9a-f]+ with the '
                                  r"personality's own name space under it", t) is not None
                    and 'p9 exec: /boot/libsh returned; the personality is still here, '
                        'its name space never reloaded' in t))
    #
    # The name space, from a program the personality loaded.  bind,
    # chdir and unmount were the library's own and its caller could not
    # reach them, which is a fixed list of names rather than a name
    # space.  The program reaches one file three ways and requires the
    # fourth to fail: an unmount that did nothing would leave a test of
    # bind alone passing, so the failure is as much of the claim as the
    # three successes.
    ns = scriptline(t, '/boot/libns')
    nsn = re.search(r'libns: the name space is the program\'s to change: three ways to '
                    r'one file, (\d+) bytes off each, and the fourth refused', ns)
    results.append(("and a program the personality loaded can change the name space, not only read through it: /boot/libns reaches one file by its whole name, by chdir and no slash, and through a bind of its own - the same bytes each way - and then unmounts the binding and is refused, which is what says the unmount did something",
                    nsn is not None and int(nsn.group(1)) > 0
                    and 'libns: that is not the name space I asked for' not in ns
                    and re.search(r'libns: after unmount /n, /n/libcat reads -1', ns) is not None
                    and 'libns: #K is back on /n, which is where the personality had it' in ns))
    #
    # And a name space of the program's own.  Every flow of control here
    # shares the personality's Pgrp by pointer, so a bind is the
    # library's bind; rfork(RFNAMEG) is the way out of that, and Plan 9's
    # answer to the same question.
    #
    # The program cannot check this itself - it has only its own name
    # space to look through - so the check is in two halves and the
    # second is the shell's.  libns binds /boot onto /n after taking a
    # name space of its own; the next script line asks cat for
    # /n/libcat, in the shell's name space, and cat must not find it.  A
    # private name space that was not private would leave that file
    # there, and every line libns prints would still read correctly.
    privcat = scriptline(t, '/boot/libcat /n/libcat')
    results.append(("and a program can take a name space of its own, which is what a shared one has to have a way out of: rfork(RFNAMEG) hands it a copy - everything that resolved still resolves - and a bind it makes in that copy is its own, which the shell's next command proves by being unable to open the file the bind made",
                    'libns: rfork(RFNAMEG) gave me a name space of my own' in ns
                    and re.search(r'libns: in it, /boot/libcat still reads (\d+), so it is a copy '
                                  r'and not an empty one', ns) is not None
                    and re.search(r'libns: in my own name space /n/libcat reads (\d+), and the '
                                  r'personality should not see it', ns) is not None
                    and 'libsh: /boot/libcat /n/libcat' in privcat
                    and 'cat: cannot open /n/libcat' in privcat))
    #
    # And the same question of the environment, which is a different
    # group and needs the same two halves: a variable set before the
    # rfork must be readable by the shell afterwards and one set after
    # must not be.
    envcat = scriptline(t, '/boot/libcat /env/libnsshared /env/libnsprivate')
    results.append(("and an environment of its own as well as a name space: a variable the program set before rfork(RFENVG) is still there in the copy and still there for the shell, and one it set afterwards is in its own group only - which the shell's next command shows by reading the first file and being unable to open the second",
                    'libns: rfork(RFENVG) gave me an environment of my own' in ns
                    and 'libns: in it, libnsshared is "before", so it is a copy and not an empty one' in ns
                    and 'libns: and libnsprivate is "after" here' in ns
                    and 'cat: descriptor 4 is /env/libnsshared' in envcat
                    and 'cat: cannot open /env/libnsprivate' in envcat))
    #
    # The descriptor table.  A spawned program's is already its own, so
    # what RFFDG separates cannot be seen from outside; what can be seen
    # from inside is that the two bits differ, which is the whole of the
    # claim being made for them.
    results.append(("and the two descriptor-table bits do different things: a descriptor the program opened before rfork(RFFDG) still reads, because that is a copy of the table, and does not read after rfork(RFCFDG), because that is an empty one - the difference being the claim, since a spawned program's table is already its own and nothing outside it can see the separation",
                    re.search(r'libns: after rfork\(RFFDG\) the descriptor I held reads (\d+), '
                              r'because that is a copy', ns) is not None
                    and 'libns: after rfork(RFCFDG) it reads -1, because that is an empty table' in ns))
    #
    # await(2), which libc's wait() is written on and rio's wait on
    # that.  It waits for a program of this flow's own rather than for a
    # pid, and the line it answers is parsed in the program with
    # tokenize - the same parser libc's wait() uses on it - so a line
    # with the wrong shape fails here rather than in rio much later.
    #
    # The third wait has to be refused.  A wait with none of its own
    # left that answered anyway would be taking somebody else's program,
    # and one that slept would be a hang.
    awaited = re.findall(r'libns: await says (\d+) ended, status "([^"]*)", '
                         r'in (\d+) (\d+) (\d+) ms', ns)
    started = re.search(r'libns: started two of /boot/libcat, as (\d+) and (\d+)', ns)
    results.append(("and a program can wait for what it started without naming it: await answers whichever of its own ended, in five fields that the program parses with tokenize, which is the parser libc's wait uses on the same line - and a third wait, with none of its own left, is refused rather than answered with somebody else's program or left asleep",
                    started is not None
                    and len(awaited) == 2
                    and {a[0] for a in awaited} == {started.group(1), started.group(2)}
                    and 'libns: a third await, with none of mine left, refused: no living processes' in ns
                    and 'libns: await gave' not in ns
                    and 'libns: a third await answered' not in ns))
    #
    # notify(2).  nil is what rio's winshell asks for and it is
    # answered truthfully: it asks for no note handler and there is
    # none.  A handler is refused, because nothing here posts a note to
    # a loaded program and one that was recorded would never be called.
    #
    # The refusal is also the first thing that ever wrote an errstr from
    # a program rather than reading one, and it found that half of the
    # exchange truncating to seven characters - kstrcpy with sizeof of a
    # char*.  So the whole message is required here, not the first word
    # of it: a check that asked only for "refused" would have passed
    # over the bug that found.
    results.append(("and notify(2) answers nil and refuses a handler, with the reason a program can read: nil asks for no note handler and there is none here, and a handler recorded is a handler nothing would ever call - which is the shape of pretending this table has refused throughout",
                    'libns: notify(nil) answered: there is no note handler, which is the truth here' in ns
                    and 'libns: notify with a handler refused: notify: this personality posts no '
                        'notes to a loaded program, so a handler would never be called' in ns
                    and 'libns: notify with a handler was accepted' not in ns
                    and 'libns: a note handler ran' not in ns))
    results.append(("and what this personality cannot mean by rfork is refused by name rather than granted, with the bits it cannot mean named in the message: RFPROC would split the caller's own flow of control, which spawn and proccreate are what there is for, and a success that did nothing would leave a program believing it was two",
                    re.search(r'libns: rfork\(RFPROC\) refused: rfork 0x10: this personality '
                              r'cannot mean 0x10 of it \(RFPROC, RFMEM, RFNOWAIT, RFREND, '
                              r'RFNOTEG and RFNOMNT are not here\)', ns) is not None
                    and 'rfork(RFPROC) was granted' not in ns))
    results.append(("and the limit still holds for a program that is its address: the script's last line asks for two of /boot/libgen, which is linked at one, and the second is refused by name - the two would be the one image sharing its one data segment, descriptor table and heap - and the shell carries on",
                    'p9 exec: /boot/libgen is already running at 0x2000000; it is one image and cannot be two programs' in t
                    and 'libsh: /boot/libgen: cannot start it' in t))
    results.append(("and a spawned program that fails ends with the failure as its status: the stage that was started writes into a pipe whose reader never arrived, the personality answers -1 and a reason the way a libc does, and the program makes that reason its exit status, which the shell reads out of the wait",
                    re.search(r'libgen: the write failed after \d+ bytes: Ehungup', t) is not None
                    and 'libsh: /boot/libgen ended, status "Ehungup"' in t
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
    # gave it a table of every absolute address in it - so the loader
    # takes a free slot for each copy and gives it back when the copy
    # ends.  The arithmetic each copy prints is over a table of function
    # pointers and a table of string pointers, both in its data: a
    # pointer that was not corrected is a wrong number or a fault, not a
    # subtly different string.
    laid = re.findall(r'p9 reloc: /boot/reloc laid at (0x[0-9a-f]+), \d+ bytes, '
                      r'(\d+) absolute addresses corrected; it was linked at 0', t)
    ran = re.findall(r'reloc: 5 function pointers summing to 15, '
                     r'5 string pointers of total length 21: '
                     r'"relocation is the way out"', t)
    spawned = re.findall(r'p9 spawn: /boot/reloc runs as (\d+) at (0x[0-9a-f]+)', t)
    both = re.search(r'p9: two of /boot/reloc ran at once, as (\d+) and (\d+), '
                     r'each in a slot of its own', t)
    results.append(("and a program with no address of its own is laid wherever the loader puts it: /boot/reloc is a relocatable module, linked at 0 with a table of every absolute address in it, and each time it is loaded the loader corrects every one of them to the slot it chose",
                    len(laid) >= 4 and len({n for _, n in laid}) == 1
                    and int(laid[0][1]) > 0
                    and len(ran) == len(laid) and 'reloc: that is not the' not in t))
    results.append(("and two of it run at the same time, each in a slot of its own - which is the thing a fixed base cannot do, and the thing the shell is refused a few lines above: a program with an address is that address, and two of it would be one image sharing one data segment, one descriptor table and one heap",
                    both is not None and both.group(1) != both.group(2)
                    and len(spawned) == 2 and spawned[0][1] != spawned[1][1]))
    results.append(("and a slot is given back when its program ends and taken again by the next: the address the first copy ran at is used again by a later load, so the range is allocated rather than assigned",
                    len(laid) >= 4 and laid[0][0] in [a for a, _ in laid[2:]]))
    #
    # p9execreloc is told which slot to use rather than asking for one,
    # and it now claims that slot from the allocator and frees it after.
    # The witness is that the shell, which asks, is given a slot one of
    # those named runs used and gave back.
    execreloc = re.findall(r'p9 exec: entering /boot/reloc at (0x[0-9a-f]+), where it was '
                           r'put rather than where it was linked', t)
    results.append(("and a module laid in a slot the caller names is claimed from the allocator all the same, and given back: /boot/reloc is run twice at two slots named outright, and the slot the shell is later given - the shell asks rather than names - is one of them, which it could only be if the named runs had returned it",
                    len(execreloc) >= 2 and len(set(execreloc)) >= 2
                    and shslot is not None and shslot.group(1) in execreloc))
    #
    # And the exec path gives a slot back.  p9exec takes one for a
    # module and frees it when the program returns, and while the shell
    # was the last module to run there was nothing to see that in: the
    # free ran with no witness.  So a module is loaded through p9exec
    # once more after the shell has ended, and the slot it is given must
    # be the one the shell held - which is free only because p9exec
    # freed it.
    after = t[t.index('p9: the shell has ended;'):] if 'p9: the shell has ended;' in t else ''
    afterslot = re.search(r'p9 exec: entering /boot/reloc at (0x[0-9a-f]+) with the '
                          r"personality's own name space under it", after)
    results.append(("and p9exec gives a slot back as well as taking one: a module is loaded through it again once the shell has ended, and the slot it is given is the one the shell was holding - which is free only because the exec that ran the shell freed it, a line that had nothing to witness it while the shell was the last module to run",
                    afterslot is not None
                    and shslot is not None
                    and afterslot.group(1) == shslot.group(1)
                    and 'reloc: 5 function pointers summing to 15' in after
                    and 'reloc: that is not the' not in after))
    #
    # rio.  The real 9front rio, from the source in 9front/src/cmd/rio,
    # linked against this personality and against nothing else - the
    # prebuilt archive of generated system-call stubs is off its link
    # line, so a call it makes that the personality does not answer is a
    # link error rather than a fault.
    #
    # What is claimed here is exactly what happens and no more: it is
    # laid in a slot, entered, takes flows of control of its own through
    # the personality's proccreate, and gets as far as its own file
    # system server, which wants a name this personality's name space
    # does not have.  Then it ends, and the personality is still there.
    # It does not draw a window and nothing here says it does.
    rio = re.search(r'p9 reloc: /boot/rio laid at (0x[0-9a-f]+), (\d+) bytes, '
                    r'(\d+) absolute addresses corrected; it was linked at 0', t)
    rioprocs = re.findall(r'p9 proccreate: p9server gets a second flow of control as (\d+), '
                          r'sharing its memory and its descriptors', t)
    #
    # What a window system finds here, asked before one runs.  Five of
    # the six open and the sixth is honestly absent: rio opens /dev/snarf
    # with OCEXEC and carries on without it, so its absence is a fact
    # about this name space and not a failure.
    #
    # The probe had to be given an error handler of its own.  p9open is
    # the personality's own open and raises rather than answering -1 -
    # which every other caller in main.c already knew - so a probe whose
    # whole purpose is to ask about names that may not be there unwound
    # out of p9main and came back as a wild jump.
    devs = dict(re.findall(r'p9: rio will want (/dev/\w+): (it opens|not there)', t))
    results.append(("and what a window system needs is in the name space before one runs: /dev/draw, /dev/mouse, /dev/kbd, /dev/cons and /dev/winname all open, and /dev/snarf does not exist - which rio opens with OCEXEC and carries on without, so it is a fact about this name space rather than a failure of it",
                    all(devs.get(d) == 'it opens' for d in
                        ('/dev/draw', '/dev/mouse', '/dev/kbd', '/dev/cons', '/dev/winname'))
                    and devs.get('/dev/snarf') == 'not there'))
    results.append(("and rio itself runs on it, as far as its own file system: the real 9front rio, linked against this personality with the archive of system-call stubs left off, is laid in a slot with two thousand absolute addresses corrected, is entered, and takes flows of control of its own through the personality's proccreate - which is libthread's procrfork underneath",
                    rio is not None
                    and int(rio.group(1), 16) >= 0x2c00000
                    and int(rio.group(3)) > 1000
                    and len(rioprocs) >= 3
                    and "p9 exec: entering /boot/rio at " in t))
    #
    # And it gets past the thing that stopped it first.  rio's cexecpipe
    # binds the pipe device onto /mnt/temp and opens both ends through
    # it; the root device keeps /mnt/temp and /mnt/wsys for exactly that,
    # and the personality's own bind demonstration had been leaving the
    # environment device over /mnt with MREPL, hiding both.  What rio
    # said about it was "can't create file system server: Enonexist:
    # '/mnt/temp'", so the absence of that line is the claim, together
    # with the fourth flow of control it only reaches afterwards.
    #
    # What is NOT claimed: that rio draws a window, or reaches its event
    # loop, or ends.  It runs on past its file system and the boot ends
    # with it still inside p9exec, and where it goes after that is not
    # established here.
    results.append(("and it gets past its own file system, which the personality's name space had been hiding: rio binds the pipe device onto /mnt/temp, which the root device keeps for it, and the bind demonstration in the personality had been leaving the environment device over /mnt - so rio makes its file server and a fourth flow of control, where before it stopped on the name",
                    "can't create file system server" not in t
                    and len(rioprocs) >= 4
                    and 'panic' not in t
                    and 'osprey user: the program exited; the microkernel idles' in t))
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
