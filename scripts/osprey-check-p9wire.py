#!/usr/bin/env python3
"""Two microkernels on one wire, the real stack in user space on each.

Two p9pair machines are booted on a qemu socket network - two virtual
machines and a cable - each with a virtio network device the kernel
exposes to its server personality, which drives it from user space
(netvirtio.c) and binds the real Plan 9 IP stack on it
(ospreyvnetmedium.c).  The machines tell themselves apart by the MAC
the bench gives them: 1 announces a port on the wire, 2 connects to it
across the cable, and a line crosses each way - two tcp.c's in two
user-space personalities on two machines, ARP and all, the kernels
carrying interrupts and nothing else.

usage: scripts/osprey-check-p9wire.py [-k]
"""
import os, re, subprocess, sys, tempfile, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
env = dict(os.environ, PATH=os.path.join(ROOT, 'MacOSX/arm64/bin') + ':' + os.environ['PATH'])

def plain(s):
    return re.sub(r'\x1b\[[0-9;=?]*[a-zA-Z]', '', s)

def boot(netdev, mac, until, log, img, delay=0):
    time.sleep(delay)		# the listening end must be up before the other connects
    subprocess.run(['./scripts/osprey-console.py', '-q', '-p', '2',
                    '-n', 'virtio-net-pci,disable-legacy=on,mac=' + mac, '--netdev', netdev,
                    '-l', log, '--blk', img, '-t', '240', '-u', until],
                   env=env, capture_output=True, text=True)

def main():
    keep = '-k' in sys.argv[1:]
    r = subprocess.run(['mk', 'CONF=p9pair', '9p9pair'], cwd='os/osprey/pc64',
                       env=env, capture_output=True, text=True)
    if r.returncode != 0:
        print('FAIL 9p9pair did not build'); print(r.stdout[-800:]); print(r.stderr[-800:]); return 1
    subprocess.run(['sh', 'scripts/mkosprey-efi-iso.sh'],
                   env=dict(env, OSPREY_KERNEL=os.path.join(ROOT, 'os/osprey/pc64/9p9pair'), OSPREY_INI='ospreykey=the same secret, typed into both machines'),
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    logs, imgs = [], []
    for i in (1, 2):
        logs.append(tempfile.mktemp(prefix='osprey-p9wire-%d-' % i, suffix='.log'))
        img = tempfile.mktemp(prefix='osprey-p9wire-blk-', suffix='.img')
        d = bytearray(64 * 512)
        stamp = b'osprey block device test image, sector 0 written by the host'
        d[:len(stamp)] = stamp
        open(img, 'wb').write(d)
        imgs.append(img)
    port = 17895
    t1 = threading.Thread(target=boot, args=('socket,id=n0,listen=:%d' % port, '52:54:00:00:d1:01',
                                             'osprey migrate: the exchange is complete on this machine - 2 carried away, 2 taken in and done', logs[0], imgs[0]))
    t2 = threading.Thread(target=boot, args=('socket,id=n0,connect=:%d' % port, '52:54:00:00:d1:02',
                                             'osprey migrate: the exchange is complete on this machine - 2 carried away, 2 taken in and done', logs[1], imgs[1], 4))
    t1.start(); t2.start(); t1.join(); t2.join()
    for img in imgs:
        try: os.unlink(img)
        except OSError: pass
    t = [plain(open(l, errors='replace').read()) for l in logs]
    results = [
        ("each kernel exposes its virtio network device to the server personality - the BAR as a segment, the interrupt as a semaphore - and nothing more",
         all(re.search(r'osprey net: exposed virtio network device \d+\.\d+\.\d+, BAR \d+ at 0x[0-9a-f]+ size \d+ as "virtionet", interrupt \d+ as semaphore 5', x) is not None for x in t)),
        ("a driver above each kernel brings the device up - reset, features, two queues and the receive buffers in the container's own slice - and reads its MAC",
         'vnet: virtio network device driven from user space, mac 52:54:00:00:d1:01, 16 receive buffers posted' in t[0]
         and 'vnet: virtio network device driven from user space, mac 52:54:00:00:d1:02, 16 receive buffers posted' in t[1]),
        ("the real Plan 9 stack binds an ethernet medium on that driver, and each machine takes its address on the wire from its MAC",
         'p9 wire: stack A bound the vnet medium on the user-space driver and is 10.1.0.1 on the wire (from the MAC); machine 1' in t[0]
         and 'p9 wire: stack A bound the vnet medium on the user-space driver and is 10.1.0.2 on the wire (from the MAC); machine 2' in t[1]),
        ("machine 2's tcp.c connects to machine 1's across the cable - ARP, the handshake, real frames through two user-space drivers - and machine 1 accepts it",
         re.search(r"p9 wire: machine 2's handshake with machine 1 across the cable - Established", t[1]) is not None
         and re.search(r'p9 wire: machine 1 accepted a connection over the cable from 10\.1\.0\.2!\d+ as conversation \d+', t[0]) is not None),
        ("and a line crosses each way between the two machines' stacks, and both drivers count the frames they carried",
         'p9 wire: machine 1 read 56 bytes from the other machine: "sent across the cable by machine 2\'s tcp.c in user space"' in t[0]
         and 'p9 wire: machine 2 read the answer across the cable: "answered across the cable by machine 1\'s tcp.c in user space"' in t[1]
         and re.search(r'machine 1 answered the other machine; its user-space driver took [1-9]\d* frames in and put [1-9]\d* out, 0 dropped', t[0]) is not None
         and re.search(r'its user-space driver took [1-9]\d* frames in and put [1-9]\d* out, 0 dropped', t[1]) is not None),
        ("and a megabyte across the cable: tcp.c's bursts run far past the driver's sixteen slots, the medium queues what the device has no slot for and sends it when the interrupt frees one, and nothing is dropped - the throughput printed",
         re.search(r'p9 wire: machine 1 took 1048576 bytes across the cable in \d+ ms \(\d+ KB/s\); its driver dropped 0 frames', t[0]) is not None
         and re.search(r'p9 wire: machine 2 sent 1048576 bytes across the cable and the other machine said "got it"; its driver put \d+ frames out, dropped 0, refused \d+ for want of a slot, of which the medium queued (\d+) and sent \1 later', t[1]) is not None),
        ("migration: each machine's legacy process asks to be carried over the wire, its kernel parks it and its server pulls the segments, register frame and every resident page out by request and sends them across the cable, and the other machine's server has its kernel make, fill and start a process from them",
         all(re.search(r"p9 migrate: container \d+'s process carried over the wire to 10\.1\.0\.[12], with 1 of its group: ([1-9]\d*) pages, \d+ bytes; it is container \d+ there", x) is not None for x in t)
         and all(re.search(r'p9 migrate: a process arrived over the wire from 10\.1\.0\.[12]!\d+, [1-9]\d* pages, and runs here as container \d+', x) is not None for x in t)
         and all(re.search(r'osprey migrate: a process arrived over the wire and is container \d+ here, [1-9]\d* pages, its registers and stack as they were; resumed', x) is not None for x in t)),
        ("and the process goes on from its request's return on the other machine, its stack as it was, and the container it left is destroyed there and its parent told",
         all(re.search(r'legacy: I was carried over the wire to the other machine with my thread: I am container \d+ here, my stack still holds 42', x) is not None for x in t)
         and all(re.search(r"osprey migrate: container \d+'s process \(/boot/legacy\) has gone over the wire; container \d+ destroyed, its parent told", x) is not None for x in t)
         and all('no other machine took me' not in x for x in t)),
        ("and its group crosses with it: the thread sharing its address space is stopped, carried after it with its own stack, and made to share the arrived memory on the other machine, where it goes on counting and is reaped by the arrived parent",
         all(re.search(r'p9 migrate: a member of its group arrived with it, [1-9]\d* pages of its own, and runs here as container \d+ sharing container \d+\'s memory', x) is not None for x in t)
         and all(re.search(r'the thread had counted to \d+ before the crossing and to \d+ after it - it came with me, still running in the shared memory', x) is not None for x in t)
         and all(re.search(r'legacy: reaped my thread after the crossing; its wait message: "\d+ ', x) is not None for x in t)
         and all(re.search(r'osprey migrate: group member container \d+ \(pid \d+\) has gone over the wire with it; container \d+ destroyed', x) is not None for x in t)),
        ("what the process has crosses with it: its text and data are a buddy image's, so the sender lets go of every page equal to the image and carries only the forty dirty pages and the rest that differ - under sixty pages, not the whole image - and the far buddy lays the same image out for the arrival, which pages in from it",
         all(re.search(r"osprey migrate: container \d+'s process's text and data are its buddy's image: [1-9]\d* pages let go \(text, data equal to the image, zeros\), (4\d|5\d) pages that differ kept to carry, \d+ in segments shared with a process that stays", x) is not None for x in t)
         and all(re.search(r"p9 migrate: container \d+'s process carried over the wire to 10\.1\.0\.[12], with 1 of its group: (4\d|5\d) pages,", x) is not None for x in t)
         and all(re.search(r'buddy: container \d+ arrived: image /boot/legacy laid out for it, [1-9]\d* descriptors reopened at their offsets', x) is not None for x in t)
         and all(re.search(r'legacy: and what I had came with me: my 40 dirty pages \(40 intact\)', x) is not None for x in t)),
        ("and its descriptor table crosses: the buddy's record of each open descriptor - name, mode, offset - goes with the header and is reopened at the far end, where the arrived process reads /n/hello through the descriptor it opened before crossing",
         all(re.search(r'buddy: container \d+ departs: image /boot/legacy, [1-9]\d* descriptors in its record', x) is not None for x in t)
         and all(re.search(r'legacy: and what I had came with me: .* the descriptor I opened before the crossing reads here: "[^"]+"', x) is not None for x in t)),
        ("and two cross at once: a second process forked before the crossing asks at the same moment, alone; the kernel's departures table holds both, each server end carries its own over a connection of its own, the taker takes them in on kprocs of its own, and both arrive",
         all(re.search(r"osprey migrate: container \d+'s crossing begins while container \d+'s is in flight - 2 at once", x) is not None for x in t)
         and all(re.search(r"p9 migrate: container \d+'s process carried over the wire to 10\.1\.0\.[12], with 0 of its group: [1-9]\d* pages,", x) is not None for x in t)
         and all(re.search(r'legacy: the second process crossed at the same time: I am container \d+ here, my 40 dirty pages came with me \(40 intact\), and my descriptor opened before the crossing reads: "[^"]+"', x) is not None for x in t)),
        ("and a member blocked in the kernel crosses: the thread is a minute into a sleep when the parent asks, the kernel's note interrupts the sleep, the call returns interrupted on the way out and the thread stops there; it lands with its parent, sees the interrupted call and goes on counting",
         all(re.search(r"legacy thread: my minute's sleep was interrupted for the move; I go on counting where I am", x) is not None for x in t)
         and all(re.search(r'the thread had counted to 1 before the crossing and to ([2-9]|[1-9]\d+) after it', x) is not None for x in t)),
        ("and the parked process waited on its transfer's own progress, not a minute's count: no crossing stalled and none was refused",
         all('crossing stalled' not in x and 'was not taken by the other machine' not in x for x in t)),
        ("pi-p across the cable checks who is asking: both kernels hold the key (typed into both, since the wire is the personality's), and machine 2's session that is nobody's asks machine 1's personality to open /n/hello and is refused - the file is the personality's",
         all('osprey: the key is set from the configuration, fingerprint' in x for x in t)
         and re.search(r'p9 ip: pi-p across the cable: a session that is nobody\'s asked the other machine\'s personality to open /n/hello and was refused: "not yours', t[1]) is not None
         and re.search(r"p9 ip: pi-p wire: refused /n/hello, which is osprey's, to session [0-9a-f]+, which is nobody's", t[0]) is not None),
        ("and with a ticket its own kernel signed (ReqTicket), which machine 1's personality has its kernel check (ReqCheckticket), the session has the name in the ticket and reads the file",
         re.search(r'p9 ip: pi-p across the cable: my kernel signed a ticket for "osprey": "osprey \d+ \d+ [0-9a-f]+"', t[1]) is not None
         and re.search(r'p9 ip: pi-p wire: the kernel checked a ticket: session [0-9a-f]+ is "osprey" \(the ticket was for container \d+ where it was signed\)', t[0]) is not None
         and re.search(r'p9 ip: pi-p across the cable: with the ticket the other machine\'s kernel checked, the session is "osprey"; it opened /n/hello there and read \(version \d+\): "[^"]+"', t[1]) is not None),
        ("the wire is a capability set at boot: each machine's server holds the network device, so the containers it serves may carry a process over the wire - the authority granted when the device was exposed",
         all(re.search(r'osprey: container \d+ holds the network device now; it and the containers it serves may carry a process over the wire \(Capwire\)', x) is not None for x in t)),
        ("and neither machine panics",
         all('panic' not in x for x in t)),
    ]
    bad = 0
    for what, ok in results:
        print('%-4s %s' % ('ok' if ok else 'FAIL', what))
        if not ok: bad += 1
    if keep or bad: print('\n'.join('log %s' % l for l in logs))
    else:
        for l in logs:
            try: os.unlink(l)
            except OSError: pass
    return 1 if bad else 0

sys.exit(main())
