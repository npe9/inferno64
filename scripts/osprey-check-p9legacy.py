#!/usr/bin/env python3
"""Boot p964 and run an unmodified Plan 9 binary on the library operating system.

Every other program on p964 is linked against p9crt.c and calls the
personality as a library: it makes no system call at all.  That is a
library per program, and a library per program is not an operating
system.  /boot/legacy is the other thing - an ordinary Plan 9 binary,
libc and the generated system-call stubs, nothing of this personality
linked into it, the same image the buddy configuration runs - and it
traps.

Under it is a microkernel that answers five calls and has no name space.
So the personality asks the kernel for its program's traps: the kernel
copies the frame the call arrived on to the stack and re-enters the task
at a handler in the personality, which does the work with the name space
it already has and hands the frame back with a value in it.  The
program's libc sees an ordinary system-call return.

The demonstration is behind *legacydemo= in plan9.ini because of what it
does to the machine: the program ends by faulting on purpose, to test a
note handler it has no way of having here.

The control is the same binary in the same boot with the service not
asked for: it dies at "unimplemented syscall 14", which is what every
Plan 9 binary did here before this.
"""
import os, re, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
env = dict(os.environ, PATH=os.path.join(ROOT, 'MacOSX/arm64/bin') + ':' + os.environ['PATH'])

def plain(s):
    return re.sub(r'\x1b\[[0-9;=?]*[a-zA-Z]', '', s)

def boot(ini, until):
    subprocess.run(['sh', 'scripts/mkosprey-efi-iso.sh'],
                   env=dict(env, OSPREY_KERNEL=os.path.join(ROOT, 'os/osprey/pc64/9p964'),
                            OSPREY_INI=ini),
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    log = tempfile.mktemp(prefix='osprey-p9legacy-', suffix='.log')
    subprocess.run(['./scripts/osprey-console.py', '-q', '-p', '2', '-n', 'e1000',
                    '-l', log, '-S', '-d', ROOT + '/.qemu/9front-root.qcow2',
                    '-t', '150', '-u', until],
                   env=env, capture_output=True, text=True)
    try:
        return log, plain(open(log, errors='replace').read())
    except OSError:
        return log, ''

def main():
    keep = '-k' in sys.argv[1:]
    r = subprocess.run(['mk', 'CONF=p964', '9p964'], cwd='os/osprey/pc64',
                       env=env, capture_output=True, text=True)
    if r.returncode != 0:
        print('FAIL 9p964 did not build'); print(r.stdout[-800:]); print(r.stderr[-800:]); return 1

    # Read to where rio is started and not to where the legacy program
    # returned: the criteria below are about what the personality does
    # afterwards, and a marker that fires before them is a race the
    # machine wins or loses under load rather than a claim.
    log, t = boot('*legacydemo=1', 'p9 spawn: /boot/rio runs as')
    # and the control: the same kernel, the same binary, the service not
    # asked for.  It is a separate boot because the service is asked for
    # once, at the one place the program is entered.
    clog, c = boot('*legacycontrol=1', 'the program exited')

    # the number of bytes its read(2) got back, which is a directory
    # read of / through the personality's name space
    m = re.search(r'legacy: read\(fd, buf, \d+\) returned (\d+) bytes', t)
    # where the kernel was told the program is, and where the personality is
    reg = re.search(r'serves the system calls made from (0x[0-9a-f]+) to (0x[0-9a-f]+) - its legacy program\'s image - at (0x[0-9a-f]+)', t)

    results = [
        ("an unmodified Plan 9 binary - libc, the generated system-call stubs, no personality linked into it - is laid at UTZERO and entered by the library operating system beside it",
         'entering /boot/legacy at 0x200028 as an ordinary Plan 9 binary' in t
         and 'address space at 0x200000 for /boot/legacy' in t),

        ("the personality asks the kernel for that program's system calls, naming the image they must come from: a trap from inside it is the program's, and a trap from anywhere else is the personality's own - which matters because a task here has many flows and they are all calling the kernel while the program runs",
         reg is not None and int(reg.group(1), 16) == 0x200000
         and int(reg.group(2), 16) > 0x200000 and int(reg.group(3), 16) >= 0x40000000),

        ("its open(2) - a real trap in the Plan 9 ABI, made by libc's own stub - is answered by the personality's name space with a descriptor",
         re.search(r'legacy: open\("/"\) returned fd \d+', t) is not None),

        ("and its read(2) comes back with the bytes: a directory read of / through the same namec the personality serves its own programs with",
         m is not None and int(m.group(1)) > 0),

        ("pipe(2), rfork(RFNAMEG), bind(2), unmount(2) and chdir(2) are served too, so the program changes a name space of its own and the personality's is left as it was",
         'pipe() returned fds' in t
         and 'rforked a private ns and bound /n into /' in t
         and 'unmounted /mnt' in t
         and 'p9 exec: /boot/legacy had a name space of its own; the personality has its own back' in t),

        ("a request of the microkernel's own (number 60, above the Plan 9 table) is passed on rather than answered, because a program making one is asking the kernel and not this name space - and the kernel refuses it on its merits",
         'asked to set the time of day and was refused' in t),

        ("exits(2) returns to the personality rather than ending the task.  On this microkernel EXITS idles the machine; a library operating system whose program's exit stopped the machine could run one program and no more",
         'p9 legacy: /boot/legacy exited with status' in t
         and 'p9 legacy: /boot/legacy returned; the personality is still here' in t),

        ("and a fault in the program is caught by the personality the way a kernel catches a process's: the program ends there and the machine does not stop.  The program faults on purpose, reading address 0 to test a note handler",
         'now reading a bad address on purpose' in t
         and re.search(r'fault at user pc 0x20[0-9a-f]+, inside .*own program: handed to it, not a panic', t) is not None
         and 'my program faulted' in t),

        ("and the same source runs both ways: /boot/libcat is catp9.c linked against p9crt.c, which is a library per program, and /boot/cat is the same source built the ordinary Plan 9 way - libc, the generated stubs, an argument vector, a heap grown with sbrk - and this personality serves both.  The second reads the file, grows a heap of half a megabyte through brk(2), duplicates a descriptor and names it with fd2path",
         'entering /boot/cat at 0x200028 as an ordinary Plan 9 binary' in t
         and re.search(r'cat: sbrk grew the heap \d+ bytes at [0-9a-f]+, now to [0-9a-f]+; \d+ bytes written and read back, 0 wrong', t) is not None
         and 'cat: descriptor 4 is /hello, by fd2path' in t
         and 'hello from the 9P server' in t
         and 'p9 legacy: /boot/cat returned; the personality is still here' in t),

        ("the personality goes on to run the window system afterwards, in the same boot, with its name space and its working directory back where they were",
         'p9: starting /boot/rio' in t and 'p9 spawn: /boot/rio runs as' in t),

        # "panic:" and not "panic", because the line that says the fault
        # was handed to the personality says it by naming what it is not.
        ("and the machine does not panic through any of it",
         'panic:' not in t and 'cpu0: exiting' not in t),

        ("CONTROL: the same binary in the same kernel with the service not asked for dies where every Plan 9 binary died here before - at its first file system call, unimplemented",
         'osprey user: unimplemented syscall 14' in c
         and 'legacy: open("/") failed' in c
         and 'legacy: open("/") returned fd' not in c),
    ]
    bad = 0
    for what, ok in results:
        print('%-4s %s' % ('ok' if ok else 'FAIL', what))
        if not ok: bad += 1
    print('p9legacy ok=%d fail=%d' % (len(results)-bad, bad))
    if keep or bad:
        print('log %s' % log)
        print('control log %s' % clog)
    else:
        for f in (log, clog):
            try: os.unlink(f)
            except OSError: pass
    return 1 if bad else 0

sys.exit(main())
