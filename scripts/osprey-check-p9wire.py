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
                   env=dict(env, OSPREY_KERNEL=os.path.join(ROOT, 'os/osprey/pc64/9p9pair')),
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
                                             'osprey migrate: the exchange is complete on this machine', logs[0], imgs[0]))
    t2 = threading.Thread(target=boot, args=('socket,id=n0,connect=:%d' % port, '52:54:00:00:d1:02',
                                             'osprey migrate: the exchange is complete on this machine', logs[1], imgs[1], 4))
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
