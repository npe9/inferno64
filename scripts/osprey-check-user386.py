#!/usr/bin/env python3
"""Boot xu386 and say a user program runs on the 386 microkernel.

xu386 is xup64's configuration for 386, as u386 is upc64's: the cut
core that enters user mode and runs userprog, which reaches the kernel
through the microkernel's minimal system calls and opens and reads a
file at a user-mode server over its message ring.  This builds 9xu386,
boots it with qemu-system-i386 through its multiboot header, and applies
the criteria osprey-check-user.py applies to xup64, read from the same
lines.

All of xup64's criteria are here, including the graphics and input
ones, and those two arrive by a different road: xup64's frame buffer is
set by the EFI loader, and this kernel is loaded by qemu's multiboot
loader, which sets no video mode.  os/osprey/pc/machfb.c sets one
itself, through the Bochs display registers qemu's stdvga carries, and
the port layer exposes that memory.  So the line is not "the same thing
built for the other object type": it is a thing neither machine had,
and it is why this check names -vga std rather than taking the default.

The register criterion reads the 386 line: six registers, BX, CX, DX,
SI, DI and BP, across INT $64 (os/osprey/pc/userregtorture.s).

What no 386 check reaches yet: iogrant and the TSS I/O-permission
bitmap in the machine layer.  The drivers this program runs read rings
the kernel's own handlers fill; the drivers that ask for ports
(ReqIoport) belong to the personality, which is built for amd64 only.

usage: scripts/osprey-check-user386.py [-k]
"""
import json, os, re, socket, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
env = dict(os.environ, PATH=os.path.join(ROOT, 'MacOSX/arm64/bin') + ':' + os.environ['PATH'])
KERNEL = os.path.join(ROOT, 'os/osprey/pc/9xu386')
TIMEOUT = 90

def sendinput(qmp):
    """Press a few keys and move the mouse, over QMP.

    This is what makes the 386 interrupt path run: IRQ1 and IRQ12 into
    the kernel's handlers, each filling a ring in the program's own data
    area and giving a semaphore, and the user drivers waiting on those
    semaphores with select.  Without it the drivers wait twenty seconds
    and report nothing, which says only that they waited.
    """
    try:
        s = socket.socket(socket.AF_UNIX)
        s.connect(qmp)
        f = s.makefile('rw')
        f.readline()
        f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush(); f.readline()
        for k in ('a', 'b', 'c', 'spc'):
            f.write(json.dumps({"execute": "send-key",
                "arguments": {"keys": [{"type": "qcode", "data": k}]}}) + "\n")
            f.flush(); f.readline()
            time.sleep(0.2)
        for _ in range(6):
            f.write(json.dumps({"execute": "input-send-event", "arguments": {"events": [
                {"type": "rel", "data": {"axis": "x", "value": 15}},
                {"type": "rel", "data": {"axis": "y", "value": 7}}]}}) + "\n")
            f.flush(); f.readline()
            time.sleep(0.2)
        s.close()
    except OSError:
        pass


def plain(s):
    return re.sub(r'\x1b\[[0-9;=?]*[a-zA-Z]', '', s).replace('\r', '')

def main():
    keep = '-k' in sys.argv[1:]
    r = subprocess.run(['mk', 'CONF=xu386', '9xu386'], cwd='os/osprey/pc',
                       env=env, capture_output=True, text=True)
    if r.returncode != 0:
        print('FAIL 9xu386 did not build')
        print(r.stdout[-800:]); print(r.stderr[-800:])
        return 1

    log = tempfile.mktemp(prefix='osprey-user386-', suffix='.log')
    qmp = tempfile.mktemp(prefix='osprey-user386-', suffix='.qmp')
    q = subprocess.Popen(['qemu-system-i386', '-m', '256', '-smp', '2',
                          '-vga', 'std',	# named, not defaulted: machfb.c programs this card
                          '-display', 'none', '-monitor', 'none', '-no-reboot',
                          '-serial', 'file:' + log,
                          '-qmp', 'unix:%s,server,nowait' % qmp,
                          '-kernel', KERNEL, '-append', 'console=0'],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # until the drivers finish or a panic, rather than for the whole timeout
    t = ''
    injected = False
    deadline = time.time() + TIMEOUT
    while time.time() < deadline and q.poll() is None:
        time.sleep(1)
        try:
            t = plain(open(log, errors='replace').read())
        except OSError:
            t = ''
        if 'selecting on their interrupt semaphores' in t and not injected:
            injected = True
            sendinput(qmp)
        if 'drivers done' in t or 'panic' in t:
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
    results.append(("xu386 enters user mode on the microkernel",
                    'osprey: touser' in t))
    results.append(("and a program runs there whose file personality is a user-space library, not the kernel's",
                    'whose file personality is a library' in t))
    results.append(("and a system call gives back every register it was not told to keep: six of them held across INT $64 from user mode - AX carries the result, and nothing else is spent on the call",
                    re.search(r'osprey user: six registers survived (\d+) of \1 system calls, '
                              r'so _syscallintr and forkret gave back every one they were not told to keep', t)
                    is not None))
    #
    # The interrupt half of the same question, measured in the kernel by
    # os/osprey/pc/regtorture.s before user mode is entered: six
    # registers held across real clock interrupts, and the same loop
    # with interrupts off clean, so a clobber is the entry and not the
    # loop.  The tick count is required to be non-zero: a loop no
    # interrupt landed in has measured nothing.
    #
    results.append(("and an interrupt gives back every register too: six held across real clock interrupts in the kernel's own loop",
                    re.search(r'osprey regcheck: six registers survived \d+ iterations over [1-9]\d* clock ticks, '
                              r'and the same loop with interrupts off is clean', t)
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
    #
    # The frame buffer, which on this machine the kernel sets for
    # itself: no loader here leaves a mode, so os/osprey/pc/machfb.c
    # programs qemu's stdvga through the Bochs display registers and the
    # port layer exposes that memory as the segment the program maps.
    # What this says is that the driver wrote into the memory the kernel
    # exposed - which is what amd64's criterion says too; neither looks
    # at pixels.
    #
    results.append(("and a user-level graphics driver draws to the frame buffer the microkernel exposed",
                    'drew a windowed desktop to the frame buffer' in t))
    results.append(("and user-level keyboard and mouse drivers select on the interrupt semaphores the microkernel exposes",
                    'selecting on their interrupt semaphores' in t))
    #
    # And that those drivers were woken by real interrupts, not just
    # left waiting: the keys and mouse motion this check injects over
    # QMP arrive as IRQ1 and IRQ12, the kernel's handlers fill the rings
    # and give the semaphores, and the drivers count what they read.
    # Without the injection the loop waits twenty seconds and reports
    # nothing, which says only that it waited.
    #
    m2 = re.search(r'osprey user: keyboard saw (\d+) keys, mouse moved (\d+) steps', t)
    results.append(("and real keyboard and mouse interrupts reach those drivers: the keys and motion injected are counted back",
                    m2 is not None and int(m2.group(1)) > 0 and int(m2.group(2)) > 0))
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
