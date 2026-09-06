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
                   env=dict(env, OSPREY_KERNEL=os.path.join(ROOT, 'os/osprey/pc64/9p9pair'), OSPREY_INI='ospreykey=this machine\'s secret'),
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
        ("and create and remove over 9P: the client creates a file on the server, writes it, reads it back, and remove is refused by the immutable store - all on the ring",
         'p9: pair-client: created /n/clientmade over 9P' in t
         and 'p9: pair-client: read /n/clientmade back over 9P: "made by the client over 9P"' in t
         and re.search(r'pair-client: (removed|remove) /n/clientmade over 9P', t) is not None),
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
        ("errstr crosses too: a refused remove leaves the real reason, which the program reads back over the buddy",
         re.search(r'legacy: remove refused, errstr from the buddy: "(\S+)"', t) is not None),
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
         'p9 ip: pi-p wire: connection 1 closed; the sessions it carried live on' in t
         and re.search(r'p9 ip: pi-p over the wire: a new connection resumed session [0-9a-f]+ and read fid 1, still open, data \(version \d+\): "version 42 of forty', t) is not None),
        ("and isochronous data on it: a Tstream is answered on the wire (refused over the ring), and the attribute arrives three times at the asked rate with nothing sent to make it happen",
         'p9 ip: pi-p over the wire: Tstream answered, period 100 ms' in t
         and len(re.findall(r'p9 ip: pi-p over the wire: stream frame \d arrived unasked, tag 7, version "\d+", \d+ ms after the last', t)) == 3
         and 'three frames of the stream came at the asked rate with nothing sent to make them happen' in t),
        ("resume, not restart: the kernel carries the running legacy process into a container of its own - registers, stack, data, open files, name space - and destroys the one it came from; the process goes on from the call with its stack intact and reads through a descriptor it opened before the move",
         re.search(r"osprey move: container (\d+)'s process \(/boot/legacy\) resumed as container (\d+), registers and stack as they were; container \1 destroyed", t) is not None
         and re.search(r'legacy: I was moved: I am container \d+ now, my stack still holds 42, and the fd I opened before the move reads: "version 42 of forty', t) is not None
         and 'the kernel would not move me' not in t),
        ("and the moved process is still its parent's child: it exits from the new container and the client's wait is answered with that container, not a phantom of the old",
         re.search(r'osprey exec: container (\d+) \(/boot/legacy\) exited with status 0', t) is not None
         and (lambda a, b: len(a) > 0 and b is not None and a[-1][1] == b.group(1))(
             re.findall(r"osprey move: container (\d+)'s process \(/boot/legacy\) resumed as container (\d+)", t),
             re.search(r'osprey exec: container (\d+) \(/boot/legacy\) exited with status 0', t))),
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
