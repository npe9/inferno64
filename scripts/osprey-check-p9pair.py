#!/usr/bin/env python3
"""Boot p9pair: two Plan 9 personalities as buddies over the ring.

p9pair is the microkernel running two containers, each the Plan 9 file
personality as a user-space library.  One is the client, the other the
server; the client delegates to the server, so its 9P requests forward
over the ring, and the server answers them from its own name space by an
exportfs.  This is the paper's library-OS mechanism ("library operating
systems on top of the Osprey kernel") with two of them, one delegating
file operations to the other - one-directional, and NOT the paper's
buddyOS, which is legacy-binary system-trap emulation, a different and
unbuilt mechanism.
"""
import os, re, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
env = dict(os.environ, PATH=os.path.join(ROOT, 'MacOSX/arm64/bin') + ':' + os.environ['PATH'])

def plain(s):
    return re.sub(r'\x1b\[[0-9;=?]*[a-zA-Z]', '', s)

def main():
    keep = '-k' in sys.argv[1:]
    r = subprocess.run(['mk', 'CONF=p9pair', '9p9pair'], cwd='os/osprey/pc64',
                       env=env, capture_output=True, text=True)
    if r.returncode != 0:
        print('FAIL 9p9pair did not build'); print(r.stdout[-800:]); print(r.stderr[-800:]); return 1
    subprocess.run(['sh', 'scripts/mkosprey-efi-iso.sh'],
                   env=dict(env, OSPREY_KERNEL=os.path.join(ROOT, 'os/osprey/pc64/9p9pair')),
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    log = tempfile.mktemp(prefix='osprey-p9pair-', suffix='.log')
    # a raw disk image for the user-level block driver: sector 0 says who wrote it,
    # sector 1 is what the driver writes; no -snapshot, so the write must reach it
    img = tempfile.mktemp(prefix='osprey-p9pair-blk-', suffix='.img')
    nsect = 64		# small on purpose: the client's forty versions overrun it, so reclamation must run
    d = bytearray(nsect * 512)
    stamp = b'osprey block device test image, sector 0 written by the host'
    d[:len(stamp)] = stamp
    open(img, 'wb').write(d)
    # the second serial port: the server's uart task writes it, a reader on the host watches it
    com2 = tempfile.mktemp(prefix='osprey-p9pair-com2-', suffix='.sock')
    com2log = tempfile.mktemp(prefix='osprey-p9pair-com2-', suffix='.out')
    reader = subprocess.Popen([sys.executable, 'scripts/osprey-com2read.py', com2, '300'],
                              stdout=open(com2log, 'w'), stderr=subprocess.DEVNULL)
    subprocess.run(['./scripts/osprey-console.py', '-q', '-p', '2', '-n', 'e1000',
                    '-l', log, '--blk', img, '-2', 'unix:%s,server,nowait' % com2,
                    '-t', '150', '-u', 'the microkernel idles'],
                   env=env, capture_output=True, text=True)
    try: reader.terminate()
    except OSError: pass
    try: c2 = plain(open(com2log, errors='replace').read())
    except OSError: c2 = ''
    try: os.unlink(com2log)
    except OSError: pass
    try: lastsector = open(img, 'rb').read()[(nsect-1)*512:]
    except OSError: lastsector = b''
    try: t = plain(open(log, errors='replace').read())
    except OSError: t = ''
    # a second boot on the same image: what the first committed to the log is found again
    log2 = tempfile.mktemp(prefix='osprey-p9pair-boot2-', suffix='.log')
    subprocess.run(['./scripts/osprey-console.py', '-q', '-p', '2', '-n', 'e1000',
                    '-l', log2, '--blk', img,
                    '-t', '150', '-u', 'the microkernel idles'],
                   env=env, capture_output=True, text=True)
    try: t2 = plain(open(log2, errors='replace').read())
    except OSError: t2 = ''
    try: os.unlink(img)
    except OSError: pass

    m = re.search(r"pair-client: read (\d+) entries from the server personality's exported root", t)
    results = [
        ("the kernel exposes the virtio block device's registers and interrupt to the server personality, and nothing more",
         'osprey blk: exposed virtio block device' in t and 'as "virtioblk"' in t),
        ("a driver above the kernel brings the device up and reads sector 0, the host's text",
         'as "virtioblk"' in t	# the driver's own banner line is often split by a kernel print
         and 'blk: read sector 0: status 0, text "osprey block device test image, sector 0 written by the host"' in t),
        ("it writes sector 1 and reads it back, each completion taken by select on the interrupt's semaphore",
         'blk: write sector 63: status 0' in t and 'blk: read sector 63 back: status 0, text "osprey wrote the last sector from user space"' in t
         and re.search(r'blk: 3 requests, [1-9]\d* completions taken by select', t) is not None),
        ("and the write reached the disk: the host reads the stamp back from the image after the run",
         lastsector.startswith(b'osprey wrote the last sector from user space')),
        ("a log-structured file store on that disk is mounted into the server personality's name space, and creates a file: version 1 on the log",
         'lfs: mounted the log: 0 records' in t and 'lfs: mounted at /n' in t
         and 'lfs: committed hello version 1, 46 bytes, at sector 1' in t),
        ("the client reads the file across the ring over 9P, writes it, and the clunk commits version 2 to the disk",
         'p9: pair-client: read /n/hello from the disk over 9P: "hello from the log-structured store, version 1"' in t
         and 'lfs: committed hello version 2, 56 bytes' in t),
        ("the same file over pi-p, about the personality's files: one group - session, open, read of *, read of data, write, close - answered in one round trip",
         'p9: pair-client: pi-p group of 6 answered with 6 replies in one round trip' in t
         and 'p9: pair-client: pi-p read * (version 2): "* data version length name"' in t
         and 'p9: pair-client: pi-p read data (version 2): "written by the client over 9P, a new version on the disk"' in t),
        ("the write makes a version nobody else sees until the close commits it, as one record on the log",
         "p9: pair-client: pi-p write makes version 3, nobody else's until the close" in t
         and 'p9: pair-client: pi-p close committed version 3' in t
         and 'lfs: committed hello version 3, 52 bytes' in t),
        ("a second group resumes the session by number and reads the committed version",
         re.search(r'p9: pair-client: pi-p resumed session [0-9a-f]+, read data \(version 3\): "written over pi-p in one group; the close commits it"', t) is not None),
        ("the second serial port is handed to the server's uart task at boot, and a line the personality put on its output queue leaves the machine on it",
         re.search(r'osprey uart: eia1 handed to container \d+, served by its task', t) is not None
         and 'osprey uart task on the microkernel: served by a task, out of the second serial port' in c2),
        ("a container runs a group of processes that share its address space, and the second reads what the first wrote to the shared slice",
         'osprey group: container 7 made' in t
         and re.search(r"osprey group: container 7 runs two processes sharing its address space under one reservation; process two read 'A' that process one wrote to the shared slice", t) is not None),
        ("the group runs under one container's one reservation, both processes named on its status line, both billed",
         re.search(r'osprey status: proc 7 core \d+ \w+ budget \d+ used [1-9]\d* .* pid \d+ group \d+', t) is not None),
        ("the storage task sets its own reservation and takes the clock, both by request",
         'osprey: container 3 reserves 2000 us of every 10000 us, by request' in t
         and 'osprey: container 3 takes the clock tick on semaphore 2, by request' in t),
        ("forty more versions overrun the 61-sector log, and every reclaim step ran on the tick under that reservation, none on a writer",
         'p9: pair-client: wrote forty more versions of /n/hello over 9P' in t
         and 'read it back: "version 42 of forty' in t
         and len(re.findall(r'lfs: reclaim on the tick', t)) >= 10 and 'reclaim for a writer' not in t
         and 'the log is full' not in t),
        ("at the end the kernel reports the storage task's reservation and what it used of it, as the talk's dumptask does",
         re.search(r'osprey status: proc 3 core \d+ \w+ budget (19\d{5}|2000000) used \d+ period (99\d{5}|10000000) ', t) is not None),
        ("a second boot on the same image reads the checkpoint, finds the wrapped log and the file at version 42: the store is persistent",
         'from the checkpoint' in t2 and re.search(r'lfs: hello version 4\d, 82 bytes', t2) is not None
         and 'lfs: found /n/hello on the disk: "version 42 of forty' in t2),
        ("the microkernel runs a client personality that mounts a second personality over the ring",
         'pair-client: mounting the server personality over the ring' in t),
        ("and a second personality, a container of its own, answers 9P about its name space",
         'server personality: name space up, answering 9P over the ring' in t and 'p9 server: serving this name space over the ring' in t),
        ("and the client reads the server personality's exported root over 9P, the kernel only routing",
         m is not None and int(m.group(1)) >= 10),
        ("and it exits cleanly, two library operating systems on the microkernel, one serving the other, no panic",
         'the program exited' in t and 'panic' not in t),
        ("a request exec starts a program - the Linux binary in the server's file system - in a container of its own, delegated to the same server",
         re.search(r'osprey exec: container (\d+) starts /boot/linux for container 1, served by container 3', t) is not None
         and re.search(r'p9: pair-client: exec /boot/linux started container \d+', t) is not None),
        ("the server lays it out and pages it in, and it runs to exit: its file calls, brk and mmap answered",
         'buddy: exec /boot/linux for container' in t and 'linux: read(fd, buf, 512) returned 470 bytes' in t
         and 'linux: brk grew the heap by 65536 bytes, zero-filled' in t
         and re.search(r'osprey exec: container \d+ \(/boot/linux\) exited with status 0', t) is not None),
        ("exec starts a Plan 9 binary the same way, the buddy laying its a.out out, and it runs to exit",
         'buddy: exec /boot/legacy for container' in t and 'a Plan 9 a.out, text' in t
         and 'legacy: read(fd, buf, 512) returned 470 bytes' in t
         and 'legacy: the buddy answered every trap' in t
         and re.search(r'osprey exec: container \d+ \(/boot/legacy\) exited with status 0', t) is not None),
        ("the Plan 9 binary creates a file, writes it, reads it back and stats it - all through the buddy's ABI",
         re.search(r'legacy: create\("/n/p9test"\) returned fd \d+', t) is not None
         and re.search(r'legacy: wrote (\d+) bytes to the new file', t) is not None
         and 'legacy: read 46 bytes back from the file: "a file written and read back through the buddy"' in t
         and re.search(r'legacy: fstat\("/n/p9test"\) returned a (\d+)-byte stat message', t) is not None
         and re.search(r'legacy: stat\("/n/p9test"\) by name returned a (\d+)-byte stat message', t) is not None),
        ("errstr crosses too: a refused remove leaves the real reason, which the program reads back over the buddy",
         re.search(r'legacy: remove refused, errstr from the buddy: "(\S+)"', t) is not None),
        ("wait is answered by somebody: the client's wait returns the child's exit status",
         re.search(r'p9: pair-client: wait: container \d+ exited with status 0', t) is not None
         and 'panic' not in t and 'killed by SIGSEGV' not in t),	# the Linux child takes one SIGSEGV on purpose
    ]
    bad = 0
    for what, ok in results:
        print('%-4s %s' % ('ok' if ok else 'FAIL', what))
        if not ok: bad += 1
    if keep or bad: print('log %s\nlog %s' % (log, log2))
    else:
        for l in (log, log2):
            try: os.unlink(l)
            except OSError: pass
    return 1 if bad else 0

sys.exit(main())
