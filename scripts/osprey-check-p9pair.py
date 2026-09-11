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
import os, re, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
env = dict(os.environ, PATH=os.path.join(ROOT, 'MacOSX/arm64/bin') + ':' + os.environ['PATH'])

def plain(s):
    return re.sub(r'\x1b\[[0-9;=?]*[a-zA-Z]', '', s)

def drewfromanother(t):
    """The second container's readback.  Inside its own box the red it
    asked for, and inside the first client's box but outside its own the
    green that was already there: one screen, written by two containers
    through one server."""
    m = re.search(r'draw: and it drew on the same screen: inside its own box the frame buffer word is '
                  r'(0x[0-9a-f]+), and inside the first client\'s box but outside its own it is still (0x[0-9a-f]+)', t)
    if m is None:
        return False
    return int(m.group(1), 16) == 0xff0000 and int(m.group(2), 16) == 0x00ff00


def riopainted(t):
    """What the screen reads back after rio has had it.  rio fills its
    view with its own background, 0x777777FF, so on this XRGB32 frame
    buffer every word the probe samples - the centre and four points
    well inside the corners - is 0x00777777.  Checked as numbers, out of
    the memory the display controller scans, not as a message rio
    printed."""
    m = re.search(r'draw: the screen reads back centre (0x[0-9a-f]+), corners '
                  r'(0x[0-9a-f]+) (0x[0-9a-f]+) (0x[0-9a-f]+) (0x[0-9a-f]+)', t)
    if m is None:
        return False
    return all(int(g, 16) == 0x777777 for g in m.groups())


def rioalive(t):
    """rio is still there when the machine idles.  The kernel's last dump
    names every process still running; a window system that started and
    died would have painted the screen just the same, so this is what
    tells the two apart."""
    if "rio: can't" in t:
        return False
    return len(re.findall(r'osprey proc: container \d+ pid \d+ /boot/rio: \w+', t)) >= 2


def mouserecord(t):
    """The record /dev/mouse returned.  rio's form is 'm' then four
    twelve-column decimal fields - x, y, buttons, milliseconds - so this
    checks the shape and that the position is on the 1280x800 screen,
    rather than matching a string the driver could print without having
    read anything."""
    m = re.search(r'draw: and /dev/mouse reads a record: m\s*(-?\d+)\s+(-?\d+)\s+(-?\d+)\s+(-?\d+)', t)
    if m is None:
        return False
    x, y, b, ms = (int(g) for g in m.groups())
    return 0 <= x < 1280 and 0 <= y < 800 and 0 <= b <= 7 and ms >= 0


def drewpixels(t):
    """The two words read back out of the frame buffer after the draws.
    XRGB32 puts the pixel in memory as 0x00RRGGBB, so the box is 0x00ff00
    and the ground 0x0000ff - the colours the client asked for, checked
    as numbers rather than matched as text."""
    m = re.search(r'draw: two draws crossed the pipe and reached the screen: '
                  r'the frame buffer word inside the box is (0x[0-9a-f]+) and outside it (0x[0-9a-f]+)', t)
    if m is None:
        return False
    return int(m.group(1), 16) == 0x00ff00 and int(m.group(2), 16) == 0x0000ff


def heapgrew(t):
    """The sbrk line: the break really moved by what was asked, and every
    byte of the pattern read back.  The heap segment exec leaves above a
    legacy image is one page, so a break that moved half a megabyte is a
    segment the kernel grew, not memory that was already there."""
    m = re.search(r'cat: sbrk grew the heap (\d+) bytes at ([0-9a-f]+), now to ([0-9a-f]+); \d+ bytes written and read back, (\d+) wrong', t)
    if m is None:
        return False
    asked, start, now, wrong = int(m.group(1)), int(m.group(2), 16), int(m.group(3), 16), int(m.group(4))
    return wrong == 0 and asked == 512*1024 and now - start == asked


def pipelineran(t):
    """The second stage read the whole file from its standard input, and the
    shell reaped three stages in all (one for the first line, two for the
    pipeline)."""
    if 'sh: /boot/cat /n/hello | /boot/cat' not in t:
        return False
    m = re.search(r'cat: (\d+) bytes read from my standard input and written to my standard output; the read ended with (-?\d+)', t)
    if m is None or int(m.group(1)) <= 0:
        return False
    if int(m.group(2)) != 0:		# 0 is end of file; -1 would be the call giving up with the same count
        return False
    return len(re.findall(r"sh: a stage of the pipeline ended: \d+ \d+ \d+ \d+ ''", t)) == 3


def execinplace(t):
    """Twenty generations of exec, the last one reading the file through the
    descriptor opened before the first, and an exit status of 0."""
    if 'exec: generation 20 read through the inherited descriptor' not in t:
        return False
    if 'read nothing' in t or 'seek of descriptor' in t:
        return False
    if 'exec: 20 generations, each a whole exec of this binary in this same process, and the descriptor opened before the first is still open' not in t:
        return False
    return re.search(r"p9: pair-client: wait: /boot/exec \(container \d+\) exited with status 0 - it exec'd itself in place twenty times", t) is not None


def seekworks(t):
    """The same first line read twice with a seek back to the start between,
    and the same again after twenty execs."""
    r = re.findall(r'exec: generation (\d+) read through the inherited descriptor \d+: (.*)', t)
    if len(r) < 4:
        return False
    gens = [g for g, _ in r]
    texts = set(x for _, x in r)
    return gens[:2] == ['0', '0'] and gens[-1] == '20' and len(texts) == 1


def main():
    keep = '-k' in sys.argv[1:]
    r = subprocess.run(['mk', 'CONF=p9pair', '9p9pair'], cwd='os/osprey/pc64',
                       env=env, capture_output=True, text=True)
    if r.returncode != 0:
        print('FAIL 9p9pair did not build'); print(r.stdout[-800:]); print(r.stderr[-800:]); return 1
    subprocess.run(['sh', 'scripts/mkosprey-efi-iso.sh'],
                   env=dict(env, OSPREY_KERNEL=os.path.join(ROOT, 'os/osprey/pc64/9p9pair'), OSPREY_INI='ospreykey=this machine\'s secret\n*riodemo=1'),
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
                    '-t', '240', '-u', 'the microkernel idles'],
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

    now = int(time.time())
    hz = re.search(r'by request \(\d+ of \d+ at (\d+) hz\)', t)
    rt = re.search(r'p9: pair-client: 1000 requests put on the ring and answered by the server personality in \d+ cycles: (\d+) cycles each', t)
    rtus = (int(rt.group(1)) * 1000000.0 / int(hz.group(1))) if hz and rt else None
    m = re.search(r"pair-client: read (\d+) entries from the server personality's exported root", t)
    results = [
        ("the real-time clock is read in user space, by the personality's own outb/inb on the CMOS ports, no kernel rtc device in the data path",
         re.search(r'p9 rtc: read the CMOS clock in user space by its own outb/inb \(ports 0x70/0x71\): \d{4}-\d\d-\d\d \d\d:\d\d:\d\d', t) is not None),
        ("and the task hands the kernel the time of day by request: the kernel read no clock at boot, and the seconds it was given are the host's own time within ten minutes",
         (lambda mm: mm is not None and abs(int(mm.group(1)) - now) < 600)(re.search(r"osprey: container \d+ set the kernel's time of day by request: (\d+) seconds since the epoch; it holds the console, the capability granted at boot", t))
         and re.search(r"p9 rtc: set the kernel's time of day to \d+ seconds since the epoch, by request", t) is not None),
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
         'p9: pair-client: pi-p group of 7, the first saying who I am, answered with 7 replies in one round trip' in t
         and 'p9: pair-client: pi-p read * (version 2): "* data version length name latest"' in t
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
        ("forty more versions overrun the 61-sector log; the tick reclaims under the storage task's reservation, saying what each tick spent of it, and a writer reclaims only when the log filled between two ticks, one step for its own record",
         'p9: pair-client: wrote forty more versions of /n/hello over 9P' in t
         and 'read it back: "version 42 of forty' in t
         and len(re.findall(r'lfs: reclaim on the tick: dropped', t)) >= 1
         and len(re.findall(r'lfs: reclaim on the tick: \d+ steps?, spent \d+ cycles of the [1-9]\d+ this period', t)) >= 1
         and all(int(x) <= 3 for x in re.findall(r'lfs: reclaim for a writer: .* (\d+) sectors free', t))
         and 'the log is full' not in t),
        ("at the end the kernel reports the storage task's reservation and what it used of it, as the talk's dumptask does",
         re.search(r'osprey status: proc 3 core \d+ \w+ budget (19\d{5}|200\d{4}) used \d+ period (99\d{5}|100\d{5}) ', t) is not None),	# the cycle rate is measured, so these vary by a little
        ("a second boot on the same image reads the checkpoint, finds the wrapped log and the file at version 46 - the forty versions, the replica test's and the cache test's and the write through the cache after them: the store is persistent",
         'from the checkpoint' in t2 and re.search(r'lfs: hello version 46, 63 bytes', t2) is not None
         and 'lfs: found /n/hello on the disk: "written through the cache; the close committed it on the server"' in t2),
        ("the microkernel runs a client personality that mounts a second personality over the ring",
         'pair-client: mounting the server personality over the ring' in t),
        ("and a second personality, a container of its own, answers 9P about its name space",
         'server personality: name space up, answering 9P over the ring' in t and 'p9 server: serving this name space over the ring' in t),
        ("and the client reads the server personality's exported root over 9P, the kernel only routing",
         m is not None and int(m.group(1)) >= 10),
        ("and create and remove over 9P: the client creates a file on the server, writes it, reads it back, and removes it - all on the ring",
         'p9: pair-client: created /n/clientmade over 9P' in t
         and 'p9: pair-client: read /n/clientmade back over 9P: "made by the client over 9P"' in t
         and 'p9: pair-client: removed /n/clientmade over 9P' in t),
        ("and the remove is a record rather than a change: a tombstone at the head of the log, nothing written in place",
         re.search(r'lfs: removed clientmade after version 1: a tombstone at sector \d+', t) is not None),
        ("and the file stays removed across a mount: the second boot's scan reads the tombstone and does not resurrect it, while hello, which was not removed, is there",
         re.search(r'lfs: hello version 46', t2) is not None
         and re.search(r'lfs: clientmade version', t2) is None),
        ("and it exits cleanly, two library operating systems on the microkernel, one serving the other, no panic",
         'the program exited' in t and 'panic' not in t),
        ("a request exec starts a program - the Linux binary in the server's file system - in a container of its own, delegated to the same server",
         re.search(r'osprey exec: container (\d+) starts /boot/linux for container 1, served by container 3', t) is not None
         and re.search(r'p9: pair-client: exec /boot/linux started container \d+', t) is not None),
        ("the server lays it out and pages it in, and it runs to exit: its file calls, brk and mmap answered",
         'buddy: exec /boot/linux for container' in t and 'linux: read(fd, buf, 512) returned 488 bytes' in t
         and 'linux: brk grew the heap by 65536 bytes, zero-filled' in t
         and re.search(r'osprey exec: container \d+ \(/boot/linux\) exited with status 0', t) is not None),
        ("exec starts a Plan 9 binary the same way, the buddy laying its a.out out, and it runs its file work",
         'buddy: exec /boot/legacy for container' in t and 'a Plan 9 a.out, text' in t
         and 'legacy: read(fd, buf, 512) returned 488 bytes' in t
         and 'legacy: the buddy answered every trap' in t),
        ("the Plan 9 binary creates a file, writes it, reads it back and stats it - all through the buddy's ABI",
         re.search(r'legacy: create\("/n/p9test"\) returned fd \d+', t) is not None
         and re.search(r'legacy: wrote (\d+) bytes to the new file', t) is not None
         and 'legacy: read 46 bytes back from the file: "a file written and read back through the buddy"' in t
         and re.search(r'legacy: fstat\("/n/p9test"\) returned a (\d+)-byte stat message', t) is not None
         and re.search(r'legacy: stat\("/n/p9test"\) by name returned a (\d+)-byte stat message', t) is not None),
        ("the legacy binary removes the file it made, through the buddy, and the store takes it",
         'legacy: removed /n/p9test through the buddy' in t),
        ("errstr crosses too: a remove of a name that is not there leaves the real reason, which the program reads back over the buddy",
         re.search(r'legacy: remove refused, errstr from the buddy: "([^"]+)"', t) is not None),
        ("the buddy makes a pipe: the program writes one end and reads the message from the other",
         re.search(r'legacy: pipe\(\) returned fds \d+ and \d+ from the buddy', t) is not None
         and 'legacy: wrote one pipe end and read 29 bytes from the other: "through a pipe the buddy made"' in t),
        ("a legacy program rforks its own name space and binds in it: /n bound into / makes /hello read /n/hello, the buddy running the call in the container's own ns",
         re.search(r'legacy: rforked a private ns and bound /n into /; /hello \(= /n/hello\) reads: "\S', t) is not None),
        ("and mount: it mounts the exportfs #X onto /mnt in that private ns and reads /mnt/n/hello through the 9P loopback",
         re.search(r'legacy: mounted #X at /mnt and read /mnt/n/hello over 9P: "\S', t) is not None),
        ("rfork(RFPROC) forks the legacy container: the kernel makes a copy-on-write child, the parent gets its id",
         re.search(r'legacy: rfork\(RFPROC\) forked a child, id \d+; I am the parent', t) is not None
         and re.search(r'osprey fork: container \d+ forked container \d+', t) is not None),
        ("the forked child is a separate flow of control and inherits the parent's open files: it reads the file the parent opened, through the descriptor the fork had the buddy clone",
         re.search(r'legacy: I am the forked child; rfork\(RFPROC\) returned 0 to me, and I read the inherited fd: "\S', t) is not None
         and 'legacy: rfork(RFPROC) failed' not in t
         and 'could not read the inherited fd' not in t),
        ("and it inherits the parent's name space: the child opens /hello, a name only in the private name space the parent rforked and bound - so the fork carried the name space, not just the descriptors",
         'legacy: the forked child opened /hello, a name only in the parent\'s rforked name space - the fork carried the name space' in t
         and 'the name space did not cross' not in t),
        ("and the parent reaps it: wait() returns the forked child's pid - the fork's other end, the kernel answering await for the container it made",
         re.search(r'legacy: I awaited and reaped my forked child; its wait message: "\d+ ', t) is not None),
        ("a process's own pid is the same number its parent was given: the child reads getpid(), which is a word of the Tos the kernel filled, and it is the id rfork handed the parent - not the kernel's pid for it",
         re.search(r'legacy: the child I started is id (\d+) to me, and getpid\(\) reads (\d+) to it', t) is not None
         and (lambda m: m and m.group(1) == m.group(2))(
             re.search(r'legacy: the child I started is id (\d+) to me, and getpid\(\) reads (\d+) to it', t))
         and "legacy: BUG: a process's own pid and the id its parent was given are different numbers" not in t),
        ("and a note addressed by that number arrives: the parent posts to the pid the child read for itself and the child's handler catches it - which is what a threaded program does to its own procs when it shuts down, and what rio does at the end",
         re.search(r'legacy: posted a note to \d+, the number the child read for itself with getpid\(\), and it is the same number rfork gave me', t) is not None
         and 'legacy self-pid child: my note handler got the note posted to it: "interrupt"' in t
         and 'legacy: BUG: the note to' not in t
         and 'which is not a container' not in t),
        ("and the number follows a move: the process carried into a container of its own reads that container's identity for its own pid afterwards, not the one it had before",
         re.search(r'legacy: and getpid\(\) reads (\d+) after the move too - the pid a program reads for itself followed it into the new container', t) is not None
         and 'legacy: BUG: after the move getpid() reads' not in t),
        ("the device-carried medium: the client puts a real IP packet (an ICMP echo request) on the osprey ring to the server container, and the server receives it and hands it to the stack at its end - the medium's two ends as two containers, the kernel only routing the frame",
         'p9: pair-client: sent an ICMP echo request (10.0.0.1->10.0.0.2) to the server container over the ring - the device-carried medium' in t
         and re.search(r'osprey medium: a 28-byte frame arrived over the ring from container \d+ and was handed to the stack at this end', t) is not None),
        ("and the stack accepts it: the server's IP stack answers the echo request with an echo reply, so a real packet that crossed the ring was received and acted on, not just handed over",
         'osprey medium: the stack answered with an ICMP echo reply - it accepted a real IP packet that crossed the ring from the peer container' in t),
        ("what a request costs between two personalities - put on the ring, carried by the kernel, taken by the server's select, answered, routed home - a thousand of them timed by the cycle counter: %s each" % ('%.1f us' % rtus if rtus else 'not measured'),
         rtus is not None and rtus < 2000),
        ("the client container brings up the real Plan 9 IP stack of its own - devip, ip.c, tcp.c - with an osprey interface whose wire is the ring to the server container",
         'p9 ip: client container: the real Plan 9 IP stack is up in this container too; its osprey interface 10.0.1.1 is the ring wire to the server container' in t
         and "p9 ip: stack B's osprey interface 10.0.1.2 is the ring wire to the client container" in t),
        ("and its own tcp.c's frames leave over the ring - the stack's own output, not a frame built by hand - and the server's stack's frames arrive in the client's own packet buffers and on its output queue, filled in memory by the server and taken by the client's select on one kernel wakeup each: nothing polls",
         re.search(r"osprey medium: the stack's own \d+-byte frame left this container over the ring to the peer's stack - the client end of the device-carried wire", t) is not None
         and re.search(r'p9 ip: client container: done after \d+ ticks; ([3-9]|\d\d+) frames of its stack\'s crossed the ring to the server container and ([3-9]|\d\d+) of the server\'s stack\'s came back on this container\'s output queue, taken by select ([1-9]\d*) times, no polls', t) is not None),
        ("the two containers' tcp.c complete a three-way handshake across the ring, and the server container's stack accepts the connection",
         re.search(r"p9 ip: client container: the two containers' tcp.c completed a handshake across the ring - Established", t) is not None
         and re.search(r"p9 ip: ring server: accepted a connection from the client container's tcp.c across the ring as conversation \d+", t) is not None),
        ("and a byte stream crosses each way: the server container's tcp.c reads the line the client's sent, and the client's reads the answer - two whole stacks in two containers, one conversation, over a wire the kernel only routes",
         'p9 ip: ring server: read 57 bytes the client container\'s stack sent across the ring: "sent by the client container\'s own tcp.c, across the ring"' in t
         and 'p9 ip: client container: read 61 bytes back from the server container\'s tcp.c across the ring: "answered by the server container\'s own tcp.c, across the ring"' in t),
        ("and a gateway: stack B in the server container, a wire on each side, forwards with the real ip.c - the client's tcp.c reaches stack A, which has no wire to it, through stack B, and a line crosses each way one hop further",
         re.search(r'p9 ip: client container: handshake with stack A through the gateway - Established', t) is not None
         and re.search(r'p9 ip: gateway server: stack A accepted a connection from 10\.0\.1\.1!\d+, forwarded by stack B', t) is not None
         and 'p9 ip: gateway server: stack A read 44 bytes from the client container through the gateway: "sent through stack B as a gateway to stack A"' in t
         and 'p9 ip: client container: read 39 bytes back from stack A through the gateway: "answered by stack A, behind the gateway"' in t
         and re.search(r"p9 ip: gateway: stack B's ip.c forwarded the conversation - ForwDatagrams: ([4-9]|\d\d+)", t) is not None),
        ("and a firewall set by policy: the client, which holds the container, writes its firewall attribute over pi-p, and stack B puts up a rule in the real stack's own ipmux - source, protocol, destination port - diverting the client's SYNs before tcp.c sees them; the client takes the attribute down and the connect, held until then, is accepted",
         re.search(r"p9 ip: pi-p wire: session [0-9a-f]+ \(osprey\) set the container's firewall attribute: \"up\"", t) is not None
         and re.search(r'p9 ip: firewall: osprey set the firewall attribute on the container over pi-p; stack B\'s ipmux now diverts TCP from 10\.0\.1\.1 to port 9004 before tcp.c sees it', t) is not None
         and re.search(r'p9 ip: firewall: diverted a \d+-byte TCP packet from 10\.0\.1\.1 to port 9004 - the rule holds, tcp.c never saw it', t) is not None
         and 'p9 ip: firewall: the client set the firewall attribute to "down" over pi-p; the rule is lifted' in t
         and re.search(r'p9 ip: firewall: the next SYN reached tcp.c and the connection was accepted as conversation \d+', t) is not None
         and re.search(r'p9 ip: firewall: read \d+ bytes back through the connection the rule had held: "answered once the firewall\'s rule was lifted"', t) is not None),

        ("pi-p on a wire of its own: a group about the server personality's files crosses the two stacks' tcp.c across the ring and is answered there, not on the ring",
         re.search(r'p9 ip: pi-p over the wire: opened /n/hello in session [0-9a-f]+, read data \(version \d+\): "version 42 of forty', t) is not None
         and "p9 ip: pi-p over the wire: a group of 5, the first saying who I am, crossed the two stacks' tcp.c across the ring and came back with 5 replies" in t
         and re.search(r'p9 ip: pi-p wire: a \d+-byte group came over the wire on connection 1, answered with \d+ bytes of replies', t) is not None),
        ("and the session outlives the connection: the connection is closed, a second one resumes the session by number, and the fid opened on the first is still open and reads",
         'p9 ip: pi-p wire: connection 1 from the client container closed; the sessions it carried live on' in t
         and re.search(r'p9 ip: pi-p over the wire: a new connection resumed session [0-9a-f]+ and read fid 1, still open, data \(version \d+\): "version 42 of forty', t) is not None),
        ("and isochronous data on it: a Tstream is answered on the wire (refused over the ring), and the attribute arrives three times at the asked rate with nothing sent to make it happen",
         'p9 ip: pi-p over the wire: Tstream answered, period 100 ms' in t
         and len(re.findall(r'p9 ip: pi-p over the wire: stream frame \d arrived unasked, tag 7, version "\d+", \d+ ms after the last', t)) == 3
         and 'three frames of the stream came at the asked rate with nothing sent to make them happen' in t),
        ("resume, not restart: the kernel carries the running legacy process into a container of its own - registers, stack, data, open files, name space - and destroys the one it came from; the process goes on from the call with its stack intact and reads through a descriptor it opened before the move",
         re.search(r"osprey move: container (\d+)'s process \(/boot/legacy\) resumed as container (\d+), registers and stack as they were; container \1 destroyed", t) is not None
         and re.search(r'legacy: I was moved: I am container \d+ now, my stack still holds 42, and the fd I opened before the move reads: "version 42 of forty', t) is not None
         and 'the kernel would not move me' not in t),
        ("and the moved process is still its parent's child: it exits from the new container and the client's wait is answered with that container, not a phantom of the old - it ends on the fault it caught, so the status it exits with is \"note handled\", which is a status and not a success",
         re.search(r'osprey exec: the program exited with the status "note handled"', t) is not None
         and (lambda a, b: len(a) > 0 and b is not None and a[-1][1] == b.group(1))(
             re.findall(r"osprey move: container (\d+)'s process \(/boot/legacy\) resumed as container (\d+)", t),
             re.search(r'osprey exec: container (\d+) \(/boot/legacy\) exited with status 1', t))),
        ("and as a group: a thread sharing the address space is stopped, carried along with its registers and stack into a container of its own sharing the moved memory, and goes on counting there after the move; the moved parent is still its parent and reaps it",
         re.search(r'osprey move: group member container \d+ \(pid \d+, sharing the address space\) resumed as container \d+ with container \d+\'s; container \d+ destroyed', t) is not None
         and re.search(r'legacy: moved with my thread: I am container \d+ now; the thread had counted to \d+ before the move and to \d+ after it - it came along, still running in the shared memory', t) is not None
         and re.search(r'legacy: reaped my thread after the move; its wait message: "\d+ ', t) is not None
         and 'did not stop' not in t and 'the group move did not carry' not in t),
        ("dynamic replicated data: the client container keeps a replica of the server's file and follows a stream of the file's committed version over the wire, answering reads from its copy while the stream says the version is unchanged",
         re.search(r'p9 ip: replica: holding /n/hello at version (\d+) \(\d+ bytes\) from the wire; watching its committed version on a stream', t) is not None
         and re.search(r'p9 ip: replica: the stream says version \d+ still, \d+ reads answered from the replica without asking the server', t) is not None),
        ("and when another path writes a new version, the stream says so within a period and the replica refetches over the wire: the copy is current again, and the reads after it are of the new text",
         'p9 ip: replica: another path, 9P over the ring, wrote a new version while the replica watched' in t
         and re.search(r'p9 ip: replica: the stream says version (\d+) now, not (\d+): refetched over the wire, "a new version the replica must notice" - the replica is current again', t) is not None
         and re.search(r'p9 ip: replica: done - \d+ stream frames, \d+ reads answered from the replica, 1 refetch', t) is not None),
        ("a caching file system: #K bound over /n in the client container's own name space, so an open of /n/hello is answered from a copy of the server's file - fetched over the wire on the first open, from the copy on the second with nothing asked of the server - and ls /n lists it",
         re.search(r'p9 ip: cache: read /n/hello through this container\'s name space \(a miss, fetched\): "a new version the replica must notice"', t) is not None
         and re.search(r'p9 ip: cache: read /n/hello through this container\'s name space \(a hit, from the copy\): "a new version the replica must notice"', t) is not None
         and re.search(r'cache: /n/hello: answered from the copy, version \d+, nothing asked of the server', t) is not None
         and re.search(r'p9 ip: cache: ls /n lists hello, version \d+, \d+ bytes', t) is not None),
        ("and it stays current by the wire: another path writes a new version, the stream of the committed version says so, and the next open refetches and reads the new text",
         re.search(r'cache: /n/hello: the stream said version (\d+), the copy is (\d+): refetched over the wire - version \1 now', t) is not None
         and 'p9 ip: cache: read /n/hello again after the stream said the version changed: "a version written after the cache held the file"' in t
         and re.search(r'p9 ip: cache: done - 1 miss, 1 hit, 1 refetch, [1-9]\d* stream frames taken off the wire', t) is not None),
        ("the cache is a file system: a write through it is a pi-p write and close on the wire, committed on the server as a version, which the other path - 9P over the ring - reads back there",
         re.search(r'cache: /n/hello: written through - a pi-p write and close on the wire committed version \d+ on the server', t) is not None
         and 'p9 ip: cache: wrote /n/hello through the cache, and 9P over the ring reads it back on the server: "written through the cache; the close committed it on the server"' in t),
        ("its directory lists what the cache holds, each with the version and length the cache knows",
         re.search(r"p9 ip: cache: ls /n lists what the cache holds: ([1-9]\d*) files \(.*cachef.*\)", t) is not None),
        ("and nine files through a cache of eight: the ninth evicts the least recently used - its fid closed on the wire, its stream stopped on the server",
         re.search(r'cache: /n/\w+ evicted for /n/cachef\d, the least recently used: its fid closed on the wire, its stream stopped', t) is not None
         and re.search(r'p9 ip: cache: nine files opened through the cache of eight: [1-9] evicted, the least recently used; 1 written through', t) is not None),
        ("and the stream is the lease's heartbeat: past the server's three-second lease an entry is still held and read from the copy - before, a streamed fid lapsed and the copy went stale for good",
         "p9 ip: cache: 3500 ms later /n/cachef8 is still held - read from the copy; the stream's frames renewed its lease on the server" in t
         and 'past the lease: the entry is dropped' not in t),
        # The five calls beyond the file traps that rio's libc uses.  Two
        # are the buddy's, since a working directory and a mount point are
        # name-space things; three are the kernel's, since a clock, a note
        # and a place to block are not files.
        ("chdir(2) is the buddy's, and the working directory is the container's own: the program chdirs to /n and opens a relative name, which the buddy resolves against that container's directory and not its worker's",
         re.search(r'legacy: chdir\'d to /n and opened the relative name hello, which reads: "version \d+ of forty', t) is not None),
        ("and a fork inherits that working directory, while a child's own chdir does not move its parent: the two containers run their calls on the same shared workers, so a directory kept on the worker would move both",
         'legacy: the forked child inherited the working directory: it opened the relative name hello too' in t
         and 'legacy: and the child chdir\'d to / on its own, where the relative name is n/hello' in t
         and 'legacy: and my own working directory did not move when my child chdir\'d: hello still opens here' in t
         and 'legacy: BUG: the forked child did not inherit the working directory' not in t
         and 'legacy: BUG: my working directory moved when my child chdir\'d' not in t),
        ("unmount(2) takes a container's own mount off its own mount point: the file readable through the mount a moment before is not reachable after it, and nothing else lost a name",
         'legacy: unmounted /mnt; /mnt/n/hello is no longer reachable, which is what unmount means' in t
         and 'legacy: BUG: /mnt/n/hello still readable after unmount' not in t),
        ("nsec(2) is not a system call but a read of /dev/bintime, and the personality serves that file out of the kernel's clock: the program's two readings run forward across a sleep",
         'p9: #T bound onto /dev; nsec(2) reads /dev/bintime, the kernel\'s clock' in t
         and re.search(r'legacy: nsec\(\) ran forward (\d+) milliseconds over a 50 millisecond sleep', t) is not None
         and 'legacy: BUG: nsec() did not run forward' not in t),
        ("alarm(2) is answered by the kernel and delivered by the alarm kproc, which the microkernel path had never started: the program asks for a note in 150 milliseconds, its handler gets it, and noted(NCONT) carries it on",
         'legacy: my note handler got the alarm note I asked for: "alarm"; noted(NCONT)' in t
         and 'legacy: alarm(150) delivered its note and I woke to it' in t
         and 'legacy: BUG: alarm(150) never delivered a note' not in t),
        ("rendezvous(2) between two processes of one address space: a thread forked with RFMEM meets the program on a tag and each takes the word the other left - libthread's proccreate is this, and rio makes six of them",
         'legacy: rendezvous on tag 0x9001 met my thread and took the word it left: 0x1234' in t
         and 'legacy: BUG: rendezvous returned' not in t),
        ("and what RFMEM shares is the heap as well as the image: a buffer malloc gave the parent before the fork is written by the thread and read back by the parent - which is what makes one allocator serve both, and what lib9p's postmountsrv depends on",
         'legacy: and the heap is shared too:' in t
         and 'sbrk memory is not shared across RFMEM' not in t),
        ("and a legacy program is given a Tos: the kernel fills it and passes its address past the end of the argument vector, and the entry gives libc that and its private words - without them nsec(2) stores through a nil private on its first call",
         'legacy: nsec() ran forward' in t
         and 'legacy process osprey-exec killed by note: sys: trap: fault write addr=0x0' not in t),
        ("postnote(2) is not a system call either but a write to /proc/n/note, and the personality serves that too: the program posts \"interrupt\" to a container it started, the note reaches that program's notify(2) handler, and it exits on it - which is what a window system does to the command in a window",
         'p9: #p bound onto /proc; postnote(2) writes /proc/n/note, and the kernel posts it' in t
         and re.search(r'legacy: posted the note "interrupt" to the child I started, container \d+, by writing /proc/\d+/note', t) is not None
         and 'legacy child: my note handler got the note posted to it: "interrupt"; exiting on it' in t
         and 'legacy: BUG: the child was never interrupted' not in t
         and 'legacy: BUG: postnote to my own child' not in t),
        ("and the group form, which is the one rio uses: a note to a container and to everything that container started - the child and the grandchild under it both take it and both end on it, from one write to /proc/n/notepg",
         re.search(r'legacy: posted the note "interrupt the group" to container \d+ and everything it started, by writing /proc/\d+/notepg', t) is not None
         and 'legacy child: my note handler got the note posted to it: "interrupt the group"; exiting on it' in t
         and 'legacy grandchild: my note handler got the note posted to it: "interrupt the group"; exiting on it' in t
         and 'legacy: BUG: the grandchild was never interrupted' not in t
         and 'legacy: BUG: the child of the group was never interrupted' not in t),
        ("and the authority for a note is having started what it goes to: the same program's note to a container it did not start is refused by the kernel, which is where the question belongs - the personality only says who is asking",
         re.search(r'osprey: container \d+ asked to note container 1 and was refused: it did not start it', t) is not None
         and 'legacy: and posting a note to container 1, which I did not start, was refused - authority for a note is having started it' in t
         and 'legacy: BUG: I was allowed to note a container I did not start' not in t),
        ("a note that is not a fault: posted by request, delivered to the program's notify(2) handler, and noted(NCONT) resumes the interrupted program at the instruction after the call - the continuation the legacy ABI was missing",
         'legacy: my note handler got a note that is not a fault: "osprey: a note by request"; noted(NCONT)' in t
         and 'legacy: resumed after the note - noted(NCONT) brought me back to the instruction after the call (7)' in t),
        ("a declined fault reaches the Plan 9 program as a note, delivered to its notify(2) handler, which catches its own fault - not a microkernel panic",
         'legacy: my note handler caught the fault: "sys: trap: fault read addr=0x0"' in t
         and 'legacy: BUG: still running' not in t
         and 'microkernel: donotify' not in t),
        ("authority on the kernel's requests is a capability set at boot: the boot personality holds the console and its rtc task sets the time of day, while a legacy container that does not hold the console is refused",
         'p9 rtc: set the kernel\'s time of day to' in t
         and re.search(r"osprey: container \d+ set the kernel's time of day by request: \d+ seconds since the epoch; it holds the console, the capability granted at boot", t) is not None
         and re.search(r"osprey: container \d+ asked to set the time of day and was refused: it does not hold the console \(no Capsettime\)", t) is not None
         and 'legacy: the kernel refused to let me set the time of day - I do not hold the console' in t),
        ("exec carries an argument vector, and an arbitrary program runs on the server personality: /boot/cat, an ordinary Plan 9 binary that is not the hand-written demonstration, is exec'd with a file argument, receives its argv, opens the file through the buddy and writes its contents, and exits 0",
         'cat: started with 2 arguments; argv[0] = /boot/cat' in t
         and 'cat: opening /n/hello (argument 1), served by the buddy' in t
         and re.search(r'p9: pair-client: wait: /boot/cat \(container \d+\) exited with status 0 - it read /n/hello through the buddy and wrote it out', t) is not None),
        ("dup(2) is served by the buddy for a legacy program: /boot/cat dup's the descriptor it opened, and reads the file's contents through the duplicate - the buddy's descriptor table, not the personality's select-over-arms which shares dup's syscall number",
         re.search(r"cat: dup'd descriptor \d+ to \d+ through the buddy; /n/hello through the duplicate ->", t) is not None
         and 'cat: <- end of /n/hello through the duplicate' in t),
        ("brk_(2) grows a legacy program's heap: /boot/cat's libc sbrk's half a megabyte - far past the one page exec left above the image, so the kernel must really grow the segment - writes a pattern the length of it and reads every byte back unchanged",
         heapgrew(t)),
        ("exec(2) in place for a legacy program - the exec a shell makes after it forks, not the ring request that starts a program beside it: /boot/exec replaces itself with itself twenty times in the one container, keeps across every one of them the descriptor it opened before the first, and exits 0",
         execinplace(t)),
        ("and a bad name is a refusal, not a killing: the exec of a path that is not there returns -1 and the program goes on running and reading from the image it is on - the buddy commits nothing of its image record until the new binary has parsed",
         'exec: exec of /boot/notthere was refused, as it should be, and I am still running' in t
         and 'exec: BUG:' not in t),
        ("seek(2) reaches the buddy with the descriptor the program named: the program reads the file's first line, seeks back to the start and reads it again, and gets the same bytes - Plan 9's seek yields its answer through a pointer it passes first, whose slot the descriptor was being read from",
         seekworks(t)),
        ("fd2path(2) is served by the buddy: /boot/cat asks the path of the descriptor it dup'd and is told /n/hello - the name the buddy's own name space resolved it in, not a name the program had",
         re.search(r'cat: descriptor \d+ is /n/hello, by fd2path through the buddy', t) is not None
         and 'cat: fd2path of' not in t),
        ("a shell, on the server personality: /boot/sh - an ordinary Plan 9 program - reads a script the client wrote to the disk, and for each line forks a process, execs it in place and waits for its exit status, all four answered by a peer container over the ring",
         'sh: reading the script /n/script, my file calls answered by the buddy' in t
         and 'sh: /boot/cat /n/hello' in t
         and 'sh: the script is done' in t
         and re.search(r"p9: pair-client: wait: /boot/sh \(container \d+\) exited with status 0 - it ran a script with a pipeline in it", t) is not None),
        ("and a pipeline in it: the shell makes a pipe, dups one end onto each stage's standard descriptor and execs both, and the first stage's whole output crosses the pipe to the second, which reads it to end of file - the writer's end closing, not a call giving up - and writes it out",
         pipelineran(t)),
        ("a program this tree did not write runs on the server personality: /boot/kbdsrv is os/osprey/cmd/draw/kbd.c linked against the 9front libraries built from the source in 9front/src - libthread and lib9p above the source-built libc, a hundred kilobytes in three segments where every legacy program before it was a few tens - and the buddy lays it out, the kernel pages it in and enters it through init9main.c, and its own main() runs",
         re.search(r'buddy: exec /boot/kbdsrv for container \d+: a Plan 9 a\.out, text \d+ data \d+ bss \d+', t) is not None
         and re.search(r'osprey buddy: /boot/kbdsrv laid out by the buddy: entry 0x200028, 3 segments', t) is not None
         and re.search(r'p9: pair-client: wait: /boot/kbdsrv \(container \d+\) exited with status 1', t) is not None),
        ("and it says why it stopped, and its parent is told that it did: the same binary asked for a segment this kernel has not got - named on the command line, so that the check does not depend on a real ring being absent - its sysfatal printed the kernel's own reason through %r, errstr(2) being a call the buddy answers out of the error string it keeps and a call the kernel served itself one the buddy never saw fail, and exits(2) carried that reason out as the container's status, where a wait saw it was not a success",
         'kbdsrv: segattach nosuchring: bad arg in system call' in t
         and 'osprey exec: the program exited with the status "segattach nosuchring: bad arg in system call"' in t
         and re.search(r'p9: pair-client: wait: /boot/kbdsrv -snosuchring \(container \d+\) exited with status 1', t) is not None),
        ("the draw server runs, and the screen the microkernel exposed is a draw device: /boot/drawsrv is os/osprey/cmd/draw linked against the same source-built 9front libraries, three hundred kilobytes of libmemdraw, libmemlayer, libdraw and lib9p above libc; it maps the frame buffer, initialises the kernel's own devdraw.c in user space, and postmountsrv forks a container that answers 9P on a pipe and mounts it at /dev",
         re.search(r'buddy: exec /boot/drawsrv for container \d+: a Plan 9 a\.out, text \d+ data \d+ bss \d+', t) is not None
         and re.search(r'draw: the frame buffer is mapped at 0x[0-9a-f]+, 4096000 bytes', t) is not None
         and 'draw: the mount returned; the first client of the server starts' in t),
        ("and a client of it draws: the program opens /dev/draw/new through the mount, is given the client number and a 1280x800 x8r8g8b8 screen, and writes draw messages - allocate three images, fill the screen, put a box in it - every one of which crosses the pipe to the server container",
         re.search(r'draw: the first client is client \d+ of the server, and the screen it is given is 1280x800, channel\s+x8r8g8b8', t) is not None),
        ("and the pixels are there: the frame buffer is read back afterwards, and the word inside the box is the green that was asked for and the word outside it the blue the screen was filled with - not a return code, the memory the display controller scans",
         drewpixels(t)),
        ("and the server is reachable from outside the container that started it: postmountsrv posted its pipe in /srv - #s bound into the name space containers share - and the name outlives the process that posted it, so a second container that never had the server's mount opens /srv/draw, mounts that at /dev for itself, and the draw device gives it a client number of its own on the same 1280x800 screen",
         re.search(r'draw: a second container found the server by name in /srv and mounted it at /dev', t) is not None
         and re.search(r"draw: the second container's client is client \d+ of the server, and the screen it is given is 1280x800", t) is not None),
        ("and its pixels land on the same screen the first client drew: the box it asked for is the red it asked for, and where the first client's box was and its own is not, the green is still there",
         drewfromanother(t)),
        ("and the three files rio wants are in that one container's name space: /dev/draw is the mount it made of the server it found in /srv, and /dev/kbd and /dev/mouse are the personality's own - served out of the user-space i8042 driver it already runs, and reached the way every other file call from a container is, through the buddy",
         'p9: #m bound onto /dev; /dev/kbd and /dev/mouse are the i8042 driver\'s, in user space' in t
         and 'draw: and /dev/kbd opens beside them; it is not read, because a read of it waits for a key' in t
         and 'draw: one container holds /dev/draw, /dev/mouse and /dev/kbd - the three rio wants' in t),
        ("and /dev/mouse answers a read with a mouse record: the driver's decoded position and buttons in rio's own m-record form, with the kernel's clock for the timestamp, answered without waiting for a movement nobody made",
         mouserecord(t)),
        ("rio runs: 9front's own window system, 6407 lines this tree builds itself and nothing in it written or changed for this machine, laid out by the buddy and entered through init9main.c - started through the same draw binary with -x, which mounts /srv/draw at /dev and execs rio in place so that rio opens /dev/draw and finds the screen where a window system expects it",
         re.search(r'buddy: exec /boot/rio for container \d+: a Plan 9 a\.out, text \d+ data \d+ bss \d+', t) is not None
         and re.search(r'osprey buddy: /boot/rio laid out by the buddy: entry 0x200028, 3 segments', t) is not None
         and 'draw: /srv/draw mounted at /dev; becoming /boot/rio in place' in t),
        ("and it paints the screen: rio's own background, 0x777777, is the word at the centre and at four points inside the corners of the frame buffer, read back by a container that drew nothing and only mapped the screen the kernel exposes",
         riopainted(t)),
        ("and it is still running when the machine idles: rio's libthread procs are containers the kernel forked, they are in the kernel's last dump of what is running, and rio printed no complaint - a window system that started and died would have left the same pixels",
         rioalive(t)),
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
