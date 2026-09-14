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
                   env=dict(env, OSPREY_KERNEL=os.path.join(ROOT, 'os/osprey/pc64/9p9linux'), OSPREY_INI='ospreykey=this machine\'s secret'),
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    log = tempfile.mktemp(prefix='osprey-p9linux-', suffix='.log')
    # A raw disk for the user-level virtio driver, as the p9buddy and p9pair
    # checks give one.  With a SATA disk (-d, -S) p9blk finds no device
    # exposed and returns silently, so the buddy mounts no store and there
    # is no real file for the Linux program to open - only the root
    # directory of a name space with nothing in it.
    img = tempfile.mktemp(prefix='osprey-p9linux-blk-', suffix='.img')
    d = bytearray(64 * 512)
    stamp = b'osprey block device test image, sector 0 written by the host'
    d[:len(stamp)] = stamp
    open(img, 'wb').write(d)
    subprocess.run(['./scripts/osprey-console.py', '-q', '-p', '2', '-n', 'e1000',
                    '-l', log, '--blk', img,
                    '-t', '150', '-u', 'the microkernel idles'],
                   env=env, capture_output=True, text=True)
    try: t = plain(open(log, errors='replace').read())
    except OSError: t = ''

    m = re.search(r'linux: read\(fd, buf, \d+\) returned (\d+) bytes, served by the buddy', t)
    gd = re.search(r'linux: (\d+) entries in (\d+) calls, as dirent64 records', t)
    pages = re.findall(r'osprey buddy: page 0x[0-9a-f]+ of the legacy image supplied by the buddy', t)
    results = [
        # The entry is read out of both messages and required to agree
        # rather than matched against a fixed address.  It used to be
        # pinned to 0x4010xx, which is not an invariant of anything - it
        # is where clang happened to put _start, and adding a function to
        # linuxlegacy.c moved it to 0x4011f5 and failed a criterion that
        # had nothing to do with the change.  What is actually being
        # claimed is that the buddy laid the binary out at the entry its
        # own ELF header names, and that the two halves of the buddy say
        # the same address; a window of 256 bytes tested neither.
        ("the buddy lays the Linux binary out from its own file system (exec), the kernel carrying no copy, at the entry the ELF header names",
         (lambda a, b: a is not None and b is not None
                       and a.group(1) == b.group(1)
                       and int(a.group(1), 16) >= 0x400000)(
             re.search(r'buddy: exec /boot/linux for container \d+: entry 0x([0-9a-f]+)', t),
             re.search(r'laid out by the buddy: entry 0x([0-9a-f]+)', t))
         and 'no page mapped yet' in t),
        ("its page faults are taken to the buddy, which supplies each page from the file (text, rodata, bss)",
         len(pages) >= 3 and 'page 0x401000 of the legacy image supplied from its file' in t
         and 'kernel fault' not in t),
        ("an unmodified Linux binary runs on the microkernel and a buddy personality serves it",
         'linux: an unmodified Linux binary' in t and 'p9 server: serving this name space over the ring' in t),
        ("its open() traps in the Linux ABI (number in rax, args in registers) and the buddy answers with a descriptor",
         re.search(r'linux: open\("/"\) returned fd \d+', t) is not None),
        ("its read() is forwarded and the buddy returns the file's bytes, copied back to the Linux buffer",
         m is not None and int(m.group(1)) > 0),
        # The calls a Linux program built against a libc actually makes.
        # open(2) compiles to openat(AT_FDCWD, ...) in glibc and in musl,
        # and a program finds its way about a file with lseek and fstat.
        # This buddy mapped five numbers - read, write, open, close, lseek
        # - and refused everything else, so a binary from a toolchain
        # rather than from this tree would have failed at its first open.
        ("and the calls a real Linux binary makes, not only the five this had mapped: openat(AT_FDCWD, path) opens the buddy's own store, the read returns its bytes, and lseek moves within it",
         re.search(r'linux: openat\(AT_FDCWD, "/n/hello"\) returned fd \d+', t) is not None
         and 'linux: read 46 bytes of it: "hello from the log-structured store, version 1"' in t
         and 'linux: lseek to 6 returned 6 and the 16 bytes there are "from the log-str"' in t),
        # And stat, which is the one where the two worlds do not agree on
        # anything: the buddy answers with a 9P stat message and x86-64
        # Linux wants a 144-byte struct stat.  What a program reads out of
        # one - the kind of the file, its permissions, its length - is
        # translated; the rest is left zero rather than invented, because
        # this file system has no inode numbers or link counts to report.
        ("and stat, where the two ABIs agree on nothing: the buddy's 9P stat message is translated into an x86-64 struct stat, and the program reads its file's length and mode out of the fields Linux keeps them in - 46 bytes and a regular file for the store's own file, the directory bit for the directory holding it",
         'linux: fstat returned 0, st_size 46, st_mode 0100666' in t
         and 'linux: stat("/n") returned 0 and st_mode 040555, which has the directory bit' in t),
        # A directory listing is the other place the two ABIs disagree
        # about what comes back: the buddy answers a directory read with
        # 9P stat messages and Linux wants dirent64 records.  The program
        # had been reading the 9P ones through read(2) and could make
        # nothing of them; anything from a toolchain calls getdents64.
        # The records are translated - the qid path standing for the inode
        # number, which is what 9P has that names a file uniquely - and
        # the program walks them by reclen, calling until it gets 0, which
        # is how a directory is listed.
        ("and a directory listing crosses the same way: getdents64 returns the buddy's 9P stat messages as dirent64 records, and the program walks them by reclen over as many calls as the buffer needs - fourteen entries of the buddy's root, each with the directory bit",
         gd is not None and int(gd.group(1)) == 14 and int(gd.group(2)) >= 2
         and re.search(r'getdents64 on /: boot/4 bin/4 dev/4 env/4 fd/4 mnt/4 n/4 net/4 net\.alt/4 proc/4 rc/4 root/4 srv/4 shr/4', t) is not None),
        # Making a file and renaming one, which needed the flags translated
        # rather than passed through.  Linux's flags are not Plan 9's: the
        # two agree only on the bottom two bits (O_RDONLY, O_WRONLY,
        # O_RDWR are OREAD, OWRITE, ORDWR), so O_TRUNC - 0x200, where
        # OTRUNC is 16 - was a mode bit meaning nothing and the open was
        # refused, and O_CREAT had no counterpart at all because Plan 9
        # creates with a call of its own.  A rename is a wstat there and a
        # call of its own here, so the kernel builds the Dir; a new path
        # in another directory would have to be a copy and is refused with
        # EXDEV, the errno for exactly that.
        ("and a Linux program can make a file and rename one: O_CREAT becomes Plan 9's create with the mode it asked for, O_TRUNC becomes OTRUNC rather than a bit meaning nothing, and rename becomes a wstat naming the new name - with a rename into another directory refused as EXDEV, because a wstat does not move a file",
         re.search(r'lfs: committed linuxname version 1, 27 bytes', t) is not None
         and re.search(r'lfs: renamed linuxname to linuxmoved after version 1: 27 bytes carried over', t) is not None
         and 'linux: rename returned 0 and /n/linuxmoved reads "renamed by a Linux program' in t
         and 'linux: a rename into another directory returned -18 (EXDEV: a wstat does not move a file)' in t),
        # And removing one, which a program that can make a file ought to
        # be able to do and could not: create and rename were mapped and
        # unlink was not.  Plan 9's remove takes down a directory as
        # readily as a file, so AT_REMOVEDIR asks for nothing extra.
        ("and it can remove one: unlink becomes Plan 9's remove, and unlinking the same name again is ENOENT rather than a second success",
         'linux: unlink returned 0, and unlinking it again returned -2 (ENOENT: it is gone)' in t),
        # The rest of what a libc does before it reaches main.  writev is
        # the one that matters: a libc's stdout gathers its pieces and
        # writes them in one call, so without it a real binary prints
        # nothing at all.  ioctl is asked of the output at startup to
        # decide whether to buffer a line at a time, and the honest answer
        # on this kernel is ENOTTY - there are no terminal ioctls, so
        # nothing it has is a terminal, and answering 0 would tell it
        # there was one it could then ask about.  set_tid_address is
        # called before anything else and its answer kept as the thread
        # id.
        ("and the rest of a libc's own startup: writev gathers two pieces into one call and both land in order with the count of what went, ioctl of the output says ENOTTY because there are no terminal ioctls here, and getpid and set_tid_address agree on the process's id",
         'linux: writev wrote this in two pieces: the second piece' in t
         and 'linux: writev returned 57 for 40 + 17' in t
         and re.search(r'ioctl\(TCGETS\) returned -25 \(ENOTTY\), getpid and set_tid_address agree on ([1-9]\d*)', t) is not None),
        # The thread pointer, which is the call standing between a program
        # that makes its own raw system calls and one built against a
        # libc: musl's __init_tp and glibc's TLS setup are both
        # arch_prctl(ARCH_SET_FS, p), and every thread-local access
        # afterwards is fs-relative.  This kernel uses FS for nothing
        # (mmuinit sets its base to zero and leaves it), so the whole of
        # the work is the register and keeping it across a switch.
        # Without the restore in procrestore the second read below faults
        # at address 16 - FS base back to zero - and the program dies of
        # SIGSEGV, which is what a real binary would do.
        ("and the thread pointer a Linux libc keeps in FS: arch_prctl(ARCH_SET_FS) sets it, a store through %fs:16 lands in the block both the segment and a plain pointer name, ARCH_GET_FS reads the same base back, and it is still there after twenty thousand system calls and a round trip to the buddy - a base kept only in the processor would be whatever the last process left",
         re.search(r'arch_prctl\(ARCH_SET_FS\) returned 0, a store through %fs:16 reads back 1 both ways, '
                   r'and ARCH_GET_FS returned 0 with the base it was given: 1', t) is not None
         and 'linux: after 20000 system calls and a round trip to the buddy' in t
         and re.search(r'the thread pointer is still there: %fs:16 reads back 1 and the base is '
                       r'still its own: 1', t) is not None),
        # The half of an ABI a test usually leaves out.  Linux returns a
        # small negative number in rax and a libc turns it into -1 and
        # errno; anything outside -4095..-1 is a successful return.  This
        # had been handing back a 32-bit -1 - 4294967295, a large positive
        # number that is an error by no reading - so a program could not
        # tell a failed open from a descriptor.  What found it was running
        # this check against the kernel from before the getdents64
        # mapping: the program walked 4294967295 bytes of its own stale
        # buffer and faulted.  9P has no errno, so the buddy's own message
        # is fetched on the failure path and two names are told apart,
        # because a program acts on them: a file that is not there
        # (ENOENT, 2) and one it may not have (EACCES, 13).  A call this
        # kernel does not map is ENOSYS (38), which is what a program
        # tests for.
        ("and a failed call comes back as Linux says one does, a small negative number in rax: a missing file is ENOENT, translated from the message the buddy answers with because 9P carries no errno, and a call this kernel does not map is ENOSYS",
         'linux: openat of a missing file returned -2 and an unmapped call returned -38' in t),
        ("brk grows a heap the kernel zero-fills on demand, and it holds what the program writes",
         'linux: brk grew the heap by 65536 bytes, zero-filled and holding what was written' in t),
        ("anonymous mmap gives a mapping the program writes at both ends, and munmap takes it back",
         re.search(r'linux: mmap gave an anonymous mapping at 0x[0-9a-f]+, written at both ends, munmap returned 0', t) is not None
         and 'WRONG' not in t),
        ("stdin and stdout are the buddy's console: read(0) is end of file and write(1) reaches the console",
         'linux: read(0) on stdin returned 0 (end of file' in t),
        ("a file mapping's pages come from the buddy, read from the file: the first page of /boot/linux is its ELF header",
         re.search(r'linux: file mapping of /boot/linux at 0x[0-9a-f]+, first bytes are its ELF magic', t) is not None
         and 'of a mapped file supplied by the buddy' in t),
        ("a fault the buddy declines is SIGSEGV: delivered to the handler, which maps the page, and the store then goes through",
         'osprey linux: SIGSEGV at 0x20000000000 delivered to the handler' in t
         and 'linux: SIGSEGV 11 at 0x20000000000 delivered; the handler mapped the page' in t
         and 'linux: the faulting store went through after the handler returned: 42, one SIGSEGV' in t),
        # The Linux branch of the syscall entry, which no other check on
        # this branch reaches.  syscallentry and forkret are this
        # kernel's own rather than 9front's, and syscall() in trap.c does
        # more still for a Linux process: it takes the number from rax
        # and copies rdi, rsi, rdx, r10, r8 and r9 into the argument
        # block.  rax, rcx and r11 are excluded because the ABI says so -
        # rax carries the number and the result, rcx and r11 are what
        # SYSRET consumes.  The count printed is the one the loop
        # counted, and it is required to be the count asked for: a loop
        # that misread its argument still finishes with every register
        # intact.
        ("and twelve registers survive a hundred system calls, which is the whole set the Linux ABI promises back",
         re.search(r"linux: twelve registers survived (\d+) of \1 system calls, "
                   r"the Linux ABI's own set less rax, rcx and r11", t) is not None),
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
