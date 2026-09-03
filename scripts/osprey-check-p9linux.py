#!/usr/bin/env python3
"""Boot p9linux: a buddy operating system serving an unmodified Linux binary.

p9linux runs an unmodified, statically linked Linux x86-64 program in one
container and a Plan 9 personality in a second.  The program (built by
clang for Linux, raw syscalls, no libc) is a file in the buddy's own file
system, /boot/linux; the kernel carries no copy.  The buddy lays it out
(exec: it reads the ELF headers and answers with the entry and segments,
which the kernel makes empty) and supplies each page as the process first
touches it, whether the process touched it or the kernel did reading a
syscall argument out of it.  The program opens and reads a file in the
Linux system-call ABI - number in rax, arguments in rdi/rsi/rdx, rcx and
r11 clobbered, every other register preserved; the microkernel's SYSCALL
entry stores every register into the Ureg, syscall() reads the Linux
convention from it, and each file call is forwarded over the ring to the
buddy, which emulates it against its own name space.  The program cannot
tell a peer served it, and checks that a callee-saved register survived
every trap.  brk, anonymous mmap and munmap are answered by the kernel's
own address-space service.  This is the paper's buddyOS for the Linux
ABI: per-process interposition of both system calls and page faults.
"""
import os, re, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
env = dict(os.environ, PATH=os.path.join(ROOT, 'MacOSX/arm64/bin') + ':' + os.environ['PATH'])

def plain(s):
    return re.sub(r'\x1b\[[0-9;=?]*[a-zA-Z]', '', s)

def main():
    keep = '-k' in sys.argv[1:]
    r = subprocess.run(['mk', 'CONF=p9linux', '9p9linux'], cwd='os/osprey/pc64',
                       env=env, capture_output=True, text=True)
    if r.returncode != 0:
        print('FAIL 9p9linux did not build'); print(r.stdout[-800:]); print(r.stderr[-800:]); return 1
    subprocess.run(['sh', 'scripts/mkosprey-efi-iso.sh'],
                   env=dict(env, OSPREY_KERNEL=os.path.join(ROOT, 'os/osprey/pc64/9p9linux')),
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    log = tempfile.mktemp(prefix='osprey-p9linux-', suffix='.log')
    subprocess.run(['./scripts/osprey-console.py', '-q', '-p', '2', '-n', 'e1000',
                    '-l', log, '-S', '-d', ROOT + '/.qemu/9front-root.qcow2',
                    '-t', '150', '-u', 'the microkernel idles'],
                   env=env, capture_output=True, text=True)
    try: t = plain(open(log, errors='replace').read())
    except OSError: t = ''

    m = re.search(r'linux: read\(fd, buf, \d+\) returned (\d+) bytes, served by the buddy', t)
    pages = re.findall(r'osprey buddy: page 0x[0-9a-f]+ of the legacy image supplied by the buddy', t)
    results = [
        ("the buddy lays the Linux binary out from its own file system (exec), the kernel carrying no copy",
         re.search(r'buddy: exec /boot/linux for container \d+: entry 0x401000', t) is not None
         and 'laid out by the buddy: entry 0x401000' in t and 'no page mapped yet' in t),
        ("its page faults are taken to the buddy, which supplies each page from the file (text, rodata, bss)",
         len(pages) >= 3 and 'page 0x401000 of the legacy image supplied from its file' in t
         and 'kernel fault' not in t),
        ("an unmodified Linux binary runs on the microkernel and a buddy personality serves it",
         'linux: an unmodified Linux binary' in t and 'p9 server: serving this name space over the ring' in t),
        ("its open() traps in the Linux ABI (number in rax, args in registers) and the buddy answers with a descriptor",
         re.search(r'linux: open\("/"\) returned fd \d+', t) is not None),
        ("its read() is forwarded and the buddy returns the file's bytes, copied back to the Linux buffer",
         m is not None and int(m.group(1)) > 0),
        ("brk grows a heap the kernel zero-fills on demand, and it holds what the program writes",
         'linux: brk grew the heap by 65536 bytes, zero-filled and holding what was written' in t),
        ("anonymous mmap gives a mapping the program writes at both ends, and munmap takes it back",
         re.search(r'linux: mmap gave an anonymous mapping at 0x[0-9a-f]+, written at both ends, munmap returned 0', t) is not None
         and 'WRONG' not in t),
        ("close() returns 0 and a callee-saved register (rbx) survives every syscall, as the Linux ABI requires",
         'linux: close returned 0' in t and 'rbx preserved across every syscall' in t
         and 'CLOBBERED' not in t),
        ("it exits through Linux exit(), no unimplemented syscall, no user trap, no panic",
         'the program exited' in t and 'unimplemented syscall' not in t
         and 'user trap' not in t and 'panic' not in t),
    ]
    bad = 0
    for what, ok in results:
        print('%-4s %s' % ('ok' if ok else 'FAIL', what))
        if not ok: bad += 1
    if keep or bad: print('log %s' % log)
    else:
        try: os.unlink(log)
        except OSError: pass
    return 1 if bad else 0

sys.exit(main())
