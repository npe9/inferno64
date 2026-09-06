#!/usr/bin/env python3
"""A Bluetooth LE controller model, on the host end of the guest's uart.

This is the bench for the Bluetooth stack in appl/lib/bt and
appl/cmd/bt.  QEMU has had no Bluetooth device since the subsystem was
removed, and there is no radio on the build machine, so the guest's
second serial port is given to this instead: it speaks H4 -- the same
framing a UART-attached controller speaks -- answers HCI commands,
advertises two devices, accepts an LE connection, serves a small GATT
database over ATT, and pairs with LE legacy Just Works.

It is a model of a controller, not a radio, and it says so.  What it
proves is that the guest's framing, command serialisation, ACL
fragmentation and flow control, L2CAP, ATT, GATT and SMP are correct
against an independent implementation of the same specification.  What
it cannot prove is anything about real hardware timing, real
controller quirks or the air interface.

It is strictly reactive: it sends nothing until the guest has sent
something first.  The bench loses the first byte written into a uart
that has only just been enabled (seen live: a 10 byte host greeting
arrived as 9 bytes), so a model that speaks first would desynchronise
the guest's H4 parser through no fault of the guest.

The argument is either a unix socket path -- for a board whose second
serial port QEMU can hand over -- or a TCP port number, which is how a
board with only a console uart reaches it: QEMU user networking puts
the host at 10.0.2.2, so the guest dials tcp!10.0.2.2!<port>.

Usage: bthci.py {/path/to/socket | port} [--verbose]
"""

import os, socket, struct, sys, threading, time

verbose = '--verbose' in sys.argv or '-v' in sys.argv

# --bonded: the guest already holds the bond, from a key file rather
# than from pairing in this session.  The sensor advertises from its
# identity address for a few rounds and then rotates a resolvable
# private address, without any pairing happening first -- which is what
# a peripheral looks like the second time you meet it, and the only way
# to exercise resolution against a bond nothing in this run created.
bonded = '--bonded' in sys.argv

# --stall-connect: the first LE Create Connection is never answered, so
# the guest's own connection timeout is what ends it.  The cancel that
# follows succeeds, and the Connection Complete the specification
# promises after a successful cancel arrives with Unknown Connection
# Identifier (0x02).  The second attempt behaves normally.
stall_connect = '--stall-connect' in sys.argv

# --late-connect: the same, except the connection completes just as the
# guest gives up.  The cancel is refused with Command Disallowed (0x0c)
# and the Connection Complete arrives with a live handle -- the case
# where giving up and tearing down would throw away the connection that
# was asked for, and where dropping it on the floor leaks it.
late_connect = '--late-connect' in sys.argv

# --instant-connect: Command Status and Connection Complete back to
# back with no pause between them, so the completion can reach the
# guest before the process that asked for it has got as far as waiting.
instant_connect = '--instant-connect' in sys.argv

# --early-connect: the Connection Complete before the Command Status.
# No controller does this and the specification does not allow it; it
# is fault injection, and it is here because it is the only way from
# outside to put the completion in front of the guest while the process
# that will wait for it is still waiting for something else.  A stack
# that loses the answer to that loses it to an ordinary race too, just
# more rarely.
early_connect = '--early-connect' in sys.argv

# --orphan-connect: a controller that owes an event and does not send
# it when it should.  The first attempt is unanswered, the cancel is
# refused as if the connection had won the race -- and then no
# completion arrives until long after the guest has given up waiting
# for one, so the refusal it finally sends belongs to nothing.  The
# next attempt must not be handed it.
orphan_connect = '--orphan-connect' in sys.argv

# --orphan-live: the same, except what turns up late is a connection
# rather than a refusal.  The controller now holds a link the guest
# gave up on and does not know about, so the guest has to notice it
# when it finds it and close it, not merely ignore it.
orphan_live = '--orphan-live' in sys.argv

# --corrupt-prepare: the Prepare Write response echoes a byte that was
# not sent.  A client that does not read the echo commits whatever the
# server queued, which is the one place in ATT where ignoring the
# answer writes wrong bytes to the device rather than losing them.
# The write must fail and the value must be left alone.
corrupt_prepare = '--corrupt-prepare' in sys.argv

# --refuse-execute: the pieces queue cleanly and the commit is refused.
# A client that does not look at the Execute Write response reports a
# write that never happened.
refuse_execute = '--refuse-execute' in sys.argv

# --service-changed: once the guest has subscribed to Service Changed,
# the database moves -- a service appears -- and the device says so.  A
# client that believes the copy it walked first will never see it.
service_changed = '--service-changed' in sys.argv

# --sco: send SCO packets once the link is up.  Nothing here asked for
# a voice channel and the guest has nothing to do with them; what is
# being checked is that they are counted and said out loud rather than
# vanishing, and that a packet type nobody handles does not put the H4
# parser out of step with the stream.
sco = '--sco' in sys.argv

# --one-goes-quiet: the thermometer advertises for a few rounds and
# then stops, while the sensor keeps going.  A device that has stopped
# answering should leave the name space; one that is still answering
# should not.
one_goes_quiet = '--one-goes-quiet' in sys.argv

# --ask-params: the peripheral asks the central to change the
# connection parameters over L2CAP, twice -- once for something a
# controller will take and once for something it will not.  A central
# that says yes has undertaken to perform the update, so the model
# checks that the HCI command actually arrives.
ask_params = '--ask-params' in sys.argv

def log(*a):
    if verbose:
        print('bthci:', *a, file=sys.stderr, flush=True)

# ---------------------------------------------------------------- AES-128
# Only one block of AES-128 encryption is needed, for SMP's e().  It is
# written out here rather than pulled from a library so the bench has no
# dependency beyond the standard library.

SBOX = []
def _mkbox():
    p = q = 1
    box = [0]*256
    while True:
        p = p ^ ((p << 1) & 0xff) ^ (0x1b if p & 0x80 else 0)
        q ^= q << 1; q ^= q << 2; q ^= q << 4; q &= 0xff
        if q & 0x80: q ^= 0x09
        x = q ^ ((q << 1) | (q >> 7)) ^ ((q << 2) | (q >> 6)) \
              ^ ((q << 3) | (q >> 5)) ^ ((q << 4) | (q >> 4))
        box[p] = (x ^ 0x63) & 0xff
        if p == 1:
            break
    box[0] = 0x63
    return box
SBOX = _mkbox()

def xtime(a):
    a <<= 1
    if a & 0x100:
        a = (a ^ 0x1b) & 0xff
    return a

def aes128_encrypt_block(key, block):
    assert len(key) == 16 and len(block) == 16
    # key expansion
    w = [list(key[i*4:i*4+4]) for i in range(4)]
    rcon = 1
    for i in range(4, 44):
        t = list(w[i-1])
        if i % 4 == 0:
            t = t[1:] + t[:1]
            t = [SBOX[b] for b in t]
            t[0] ^= rcon
            rcon = xtime(rcon)
        w.append([w[i-4][j] ^ t[j] for j in range(4)])
    rk = [sum(w[4*r+c][j] << 0 for j in range(0)) for r in range(0)]  # unused

    s = [list(block[i::4]) for i in range(4)]   # state[r][c] = block[r+4c]

    def addrk(rnd):
        for c in range(4):
            for r in range(4):
                s[r][c] ^= w[4*rnd+c][r]

    addrk(0)
    for rnd in range(1, 11):
        for r in range(4):
            for c in range(4):
                s[r][c] = SBOX[s[r][c]]
        for r in range(1, 4):
            s[r] = s[r][r:] + s[r][:r]
        if rnd != 10:
            for c in range(4):
                a = [s[r][c] for r in range(4)]
                t = a[0] ^ a[1] ^ a[2] ^ a[3]
                b0 = a[0] ^ t ^ xtime(a[0] ^ a[1])
                b1 = a[1] ^ t ^ xtime(a[1] ^ a[2])
                b2 = a[2] ^ t ^ xtime(a[2] ^ a[3])
                b3 = a[3] ^ t ^ xtime(a[3] ^ a[0])
                s[0][c], s[1][c], s[2][c], s[3][c] = b0, b1, b2, b3
        addrk(rnd)
    out = bytearray(16)
    for c in range(4):
        for r in range(4):
            out[r + 4*c] = s[r][c]
    return bytes(out)

def e(k, m):
    """SMP's e(): AES-128 with both arguments least significant byte first."""
    return bytes(reversed(aes128_encrypt_block(bytes(reversed(k)), bytes(reversed(m)))))

def xor(a, b):
    return bytes(x ^ y for x, y in zip(a, b))

def c1(k, r, preq, pres, iat, rat, ia, ra):
    p1 = bytes([iat, rat]) + preq[:7] + pres[:7]
    p2 = ra[:6] + ia[:6] + b'\0\0\0\0'
    return e(k, xor(e(k, xor(r, p1)), p2))

def s1(k, r1, r2):
    return e(k, r2[:8] + r1[:8])

# ---------------------------------------------------------------- the model

def swap(b):
    return bytes(reversed(b))

def e(k, m):
    """The Bluetooth security function: AES-128 of one block, with both
    arguments and the answer in Bluetooth's least-significant-byte-first
    order rather than AES's."""
    return swap(aes128_encrypt_block(swap(k), swap(m)))

def ah(k, r):
    """The random address hash: e(k, r padded to a block) mod 2**24.
    k and r are in Bluetooth order, and so is the answer."""
    assert len(k) == 16 and len(r) == 3
    return e(k, r + bytes(13))[0:3]

# bluez unit/test-crypto.c, test_sih -- a vector from neither side of
# this bench, so a byte-order mistake shared between the model and the
# Limbo cannot pass it.
assert ah(bytes.fromhex('cdcc72dd868ccdce22fda121097d7d45'),
          bytes.fromhex('63f569')) == bytes.fromhex('da4819'), 'ah is wrong'

def rpa(irk):
    """A fresh resolvable private address for this identity resolving
    key: three random bytes with the top two bits marking it resolvable,
    and their hash under the key.  Least significant byte first, so the
    hash comes first and the random last."""
    prand = bytearray(os.urandom(3))
    prand[2] = (prand[2] & 0x3f) | 0x40
    prand = bytes(prand)
    return ah(irk, prand) + prand

IRK = bytes(range(16, 32))                    # what pairing distributes

ADDR = bytes.fromhex('554433221100')          # AA1122334455 written down
PEERS = [
    (bytes.fromhex('efcdab785634'), 0, 'thermometer'),   # 3456 78AB CDEF
    (bytes.fromhex('010203040506'), 1, 'sensor'),        # random address
]

# the GATT database: handle -> (uuid, value, kind)
# services
SVC = [
    (0x0001, 0x0005, 0x1800),
    (0x0010, 0x0013, 0x180f),
    # a writable characteristic with room for a value longer than any
    # MTU this bench negotiates, so a long write has somewhere to go
    (0x0020, 0x0022, 0xfff0),
    # Generic Attribute, whose one characteristic is how a device says
    # its database has moved
    (0x0030, 0x0033, 0x1801),
]

# what appears when the database moves, under --service-changed.  Two
# of them, a few seconds apart, because one indication cannot show
# whether the client's answer to one settles or feeds the next.
LATER = [
    ((0x0040, 0x0042, 0xfff5), (0x0041, 0x02, 0x0042, 0xfff6),
     0x0042, b'the service that arrived later'),
    ((0x0050, 0x0052, 0xfff7), (0x0051, 0x02, 0x0052, 0xfff8),
     0x0052, b'and one more after that'),
]
# characteristic declarations: (decl handle, props, value handle, uuid)
CHARS = [
    (0x0002, 0x02, 0x0003, 0x2a00),
    (0x0004, 0x02, 0x0005, 0x2a01),
    (0x0011, 0x12, 0x0012, 0x2a19),
    (0x0021, 0x0a, 0x0022, 0xfff1),
    (0x0031, 0x20, 0x0032, 0x2a05),          # indicate only
]
VALUES = {
    0x0003: b'inferno-bench',
    0x0005: bytes([0x00, 0x00]),
    0x0012: bytes([90]),
    0x0022: b'',
    0x0032: b'',
}

# client characteristic configuration, per descriptor handle
CCCD = {0x0013: 0, 0x0033: 0}
DESCS = [(0x0013, 0x2902), (0x0033, 0x2902)]

class Model:
    def __init__(self, conn):
        self.c = conn
        self.lock = threading.Lock()
        self.buf = b''
        self.scanning = False
        self.handle = None
        self.peer = None
        self.mtu = 100
        self.acl_in = b''
        self.pending_acl = 0
        self.smp = {}
        self.notified = 0
        self.stop = False
        # set once the keys have been distributed and the link is down:
        # from then on the sensor stops advertising from its identity
        # address and rotates a resolvable private address instead, the
        # way a peripheral that cares about being followed does.
        self.rotate = None
        self.rotations = 0
        self.rounds = 0
        self.stalled = None       # an attempt deliberately left unanswered
        self.stalls = 0
        self.prepared = []        # (handle, offset, value) queued by Prepare Write
        self.updates = []         # parameter updates the central performed
        self.paramresults = []    # what it answered to each request
        self.trace = []

    # ------------------------------------------------ wire
    def send(self, data):
        with self.lock:
            log('-> %s' % data[:32].hex())
            self.c.sendall(data)

    def event(self, code, params):
        self.send(bytes([4, code, len(params)]) + params)

    def cmd_complete(self, op, params):
        self.event(0x0e, bytes([1]) + struct.pack('<H', op) + params)

    def cmd_status(self, op, status=0):
        self.event(0x0f, bytes([status, 1]) + struct.pack('<H', op))

    def acl(self, cid, payload):
        # one ACL packet per L2CAP frame; the guest's own fragmentation
        # is exercised on the way down, not up
        frame = struct.pack('<HH', len(payload), cid) + payload
        pkt = struct.pack('<HH', self.handle & 0x0fff | (0x2 << 12), len(frame)) + frame
        self.send(bytes([2]) + pkt)

    def credits(self, n=1):
        self.event(0x13, bytes([1]) + struct.pack('<HH', self.handle, n))

    # ------------------------------------------------ command dispatch
    def command(self, op, params):
        self.trace.append(('cmd', op))
        log('command %#06x %s' % (op, params.hex()))
        if op == 0x0c03:                       # Reset
            self.cmd_complete(op, bytes([0]))
        elif op == 0x1001:                     # Read Local Version
            self.cmd_complete(op, bytes([0, 0x0c]) + struct.pack('<HBHH', 0x0001, 0x0c, 0xffff, 0x0001))
        elif op == 0x1009:                     # Read BD_ADDR
            self.cmd_complete(op, bytes([0]) + ADDR)
        elif op == 0x1005:                     # Read Buffer Size
            self.cmd_complete(op, bytes([0]) + struct.pack('<HBHH', 27, 0, 2, 0))
        elif op == 0x0c01:                     # Set Event Mask
            self.cmd_complete(op, bytes([0]))
        elif op == 0x2001:                     # LE Set Event Mask
            self.cmd_complete(op, bytes([0]))
        elif op == 0x2002:                     # LE Read Buffer Size
            # deliberately small: two buffers, so the guest's ACL
            # credit accounting is exercised rather than bypassed
            self.cmd_complete(op, bytes([0]) + struct.pack('<HB', 27, 2))
        elif op == 0x200b:                     # LE Set Scan Parameters
            self.cmd_complete(op, bytes([0]))
        elif op == 0x200c:                     # LE Set Scan Enable
            self.cmd_complete(op, bytes([0]))
            self.scanning = bool(params[0])
            if self.scanning:
                threading.Thread(target=self.advertise, daemon=True).start()
        elif op == 0x200d:                     # LE Create Connection
            atype = params[5]
            addr = params[6:12]
            if early_connect:
                self.complete(atype, addr)
                self.cmd_status(op)
                return
            self.cmd_status(op)
            if instant_connect:
                # in the same handler, so the two land back to back
                # rather than a thread's scheduling apart
                self.complete(atype, addr)
            else:
                threading.Thread(target=self.connect, args=(atype, addr),
                                 daemon=True).start()
        elif op == 0x2013:                     # LE Connection Update
            h, mn, mx, lat, to = struct.unpack('<HHHHH', params[0:10])
            self.cmd_status(op)
            self.updates.append((mn, mx, lat, to))
            log('connection update to %d-%d latency %d timeout %d'
                % (mn, mx, lat, to))
            time.sleep(0.05)
            # the interval the controller settles on, which is its
            # choice within the range asked for
            self.event(0x3e, bytes([0x03, 0x00]) + struct.pack('<H', h)
                       + struct.pack('<HHH', mx, lat, to))
        elif op == 0x200e:                     # LE Create Connection Cancel
            if self.stalled is None:
                self.cmd_complete(op, bytes([0]))
            elif orphan_connect or orphan_live:
                atype, addr = self.stalled
                self.stalled = None
                self.cmd_complete(op, bytes([0x0c]))   # command disallowed
                log('owing a completion, and not sending it yet')
                threading.Thread(target=self.orphan, args=(atype, addr),
                                 daemon=True).start()
            elif late_connect:
                # the connection won the race: the cancel is refused and
                # the completion is a real one
                atype, addr = self.stalled
                self.stalled = None
                self.cmd_complete(op, bytes([0x0c]))   # command disallowed
                log('the cancel lost the race; the connection is up')
                self.complete(atype, addr)
            else:
                atype, addr = self.stalled
                self.stalled = None
                self.cmd_complete(op, bytes([0]))
                log('the attempt is cancelled')
                self.event(0x3e, bytes([0x01, 0x02]) + struct.pack('<H', 0)
                           + bytes([0x01, atype]) + addr
                           + struct.pack('<HHH', 0, 0, 0) + bytes([0]))
        elif op == 0x0406:                     # Disconnect
            self.cmd_status(op)
            h = struct.unpack('<H', params[0:2])[0]
            time.sleep(0.05)
            self.event(0x05, bytes([0]) + struct.pack('<H', h) + bytes([0x16]))
            self.handle = None
            if self.smp.get('bonded'):
                self.rotate = self.peer
                log('the sensor starts rotating a private address')
        elif op == 0x2018:                     # LE Rand
            self.cmd_complete(op, bytes([0]) + os.urandom(8))
        elif op == 0x2017:                     # LE Encrypt
            k = params[0:16]; p = params[16:32]
            self.cmd_complete(op, bytes([0]) + aes128_encrypt_block(k, p))
        elif op == 0x2019:                     # LE Start Encryption
            self.cmd_status(op)
            threading.Thread(target=self.encrypt_up, daemon=True).start()
        else:
            log('unknown command %#06x' % op)
            self.cmd_complete(op, bytes([0x01]))     # unknown HCI command

    def advertise(self):
        while self.scanning:
            for addr, atype, name in PEERS:
                if not self.scanning:
                    break
                if one_goes_quiet and self.rounds > 4:
                    # after a few rounds nothing advertises at all, so
                    # what stays in the name space stays for a reason
                    # other than having been heard from
                    if self.rounds == 5:
                        log('everything stops advertising')
                    continue
                if bonded and atype == 1 and addr == PEERS[1][0] \
                   and self.rounds >= 3 and self.rotate is None:
                    self.rotate = (atype, addr)
                    log('the sensor starts rotating a private address')
                if self.rotate is not None and (atype, addr) == self.rotate:
                    # a new one every round, so what is being tested is
                    # resolution against a changing address rather than
                    # one lucky comparison
                    addr, atype = rpa(IRK), 1
                    self.rotations += 1
                ad = bytes([2, 0x01, 0x06])
                nm = name.encode()
                ad += bytes([len(nm) + 1, 0x09]) + nm
                rep = bytes([1, 0x00, atype]) + addr + bytes([len(ad)]) + ad + bytes([256 - 60])
                self.event(0x3e, bytes([0x02]) + rep)
            self.rounds += 1
            time.sleep(0.3)

    def connect(self, atype, addr):
      try:
        if (stall_connect or late_connect or orphan_connect or orphan_live) \
           and self.stalls == 0:
            self.stalls += 1
            self.stalled = (atype, addr)
            log('leaving the first connection unanswered')
            return
        if not instant_connect:
            time.sleep(0.1)
        self.complete(atype, addr)
      except Exception as ex:
        print('bthci: connect thread: %r' % (ex,), flush=True)

    def orphan(self, atype, addr):
        # long after the guest has stopped waiting for it
        time.sleep(6)
        if orphan_live:
            log('sending the connection nobody is waiting for')
            self.complete(atype, addr, 0x0041)
            return
        log('sending the completion nobody is waiting for')
        self.event(0x3e, bytes([0x01, 0x02]) + struct.pack('<H', 0)
                   + bytes([0x01, atype]) + addr
                   + struct.pack('<HHH', 0, 0, 0) + bytes([0]))

    def scostream(self):
        # three of them, interleaved with nothing, on the connection's
        # own handle
        for i in range(3):
            time.sleep(0.3)
            if self.handle is None:
                return
            body = bytes([i]) * 10
            self.send(bytes([3]) + struct.pack('<H', self.handle)
                      + bytes([len(body)]) + body)
        log('sent 3 SCO packets')

    def complete(self, atype, addr, handle=0x0040):
        # the orphan gets a handle of its own, so which link a
        # Disconnect refers to is never in doubt
        self.handle = handle
        self.peer = (atype, addr)
        self.event(0x3e, bytes([0x01, 0x00]) + struct.pack('<H', handle)
                   + bytes([0x01, atype]) + addr
                   + struct.pack('<HHH', 0x0028, 0, 0x002a) + bytes([0]))
        if sco:
            threading.Thread(target=self.scostream, daemon=True).start()
        if ask_params:
            threading.Thread(target=self.askparams, daemon=True).start()

    def encrypt_up(self):
        time.sleep(0.05)
        self.event(0x08, bytes([0]) + struct.pack('<H', self.handle) + bytes([1]))
        # then distribute the keys the pairing response promised
        time.sleep(0.05)
        self.l2 = None
        ltk = bytes(range(16))
        self.smp_send(bytes([0x06]) + ltk)
        self.smp_send(bytes([0x07]) + struct.pack('<H', 0x1234) + bytes(range(8)))
        self.smp_send(bytes([0x08]) + IRK)
        self.smp['bonded'] = True
        self.smp_send(bytes([0x09]) + bytes([self.peer[0]]) + self.peer[1])
        self.smp_send(bytes([0x0a]) + bytes(range(32, 48)))

    def smp_send(self, p):
        self.acl(6, p)

    # ------------------------------------------------ ACL up from the guest
    def acldata(self, pkt):
        h = struct.unpack('<H', pkt[0:2])[0]
        pb = (h >> 12) & 3
        dlen = struct.unpack('<H', pkt[2:4])[0]
        d = pkt[4:4+dlen]
        if pb == 0x2:
            self.acl_in = d
        elif pb == 0x1:
            self.acl_in += d
        self.credits(1)
        if len(self.acl_in) < 4:
            return
        flen, cid = struct.unpack('<HH', self.acl_in[0:4])
        if len(self.acl_in) < 4 + flen:
            return
        payload = self.acl_in[4:4+flen]
        self.acl_in = b''
        if cid == 4:
            self.att(payload)
        elif cid == 6:
            self.smp_in(payload)
        elif cid == 5:
            log('signalling %s' % payload.hex())
            if len(payload) >= 6 and payload[0] == 0x13:   # parameter response
                r = struct.unpack('<H', payload[4:6])[0]
                self.paramresults.append(r)
                log('the central said %s' % ('yes' if r == 0 else 'no'))

    # ------------------------------------------------ ATT
    def att_err(self, op, handle, err):
        self.acl(4, bytes([0x01, op]) + struct.pack('<H', handle) + bytes([err]))

    def att(self, p):
        op = p[0]
        self.trace.append(('att', op))
        log('att %#04x %s' % (op, p.hex()))
        if op == 0x02:                                    # Exchange MTU
            self.mtu = min(struct.unpack('<H', p[1:3])[0], 100)
            self.acl(4, bytes([0x03]) + struct.pack('<H', 100))
        elif op == 0x10:                                  # Read By Group Type
            start, end, = struct.unpack('<HH', p[1:5])
            typ = struct.unpack('<H', p[5:7])[0]
            if typ != 0x2800:
                return self.att_err(op, start, 0x10)
            out = b''
            for s, e_, u in SVC:
                if start <= s <= end:
                    out += struct.pack('<HHH', s, e_, u)
            if not out:
                return self.att_err(op, start, 0x0a)
            self.acl(4, bytes([0x11, 6]) + out)
        elif op == 0x08:                                  # Read By Type
            start, end = struct.unpack('<HH', p[1:5])
            typ = struct.unpack('<H', p[5:7])[0]
            if typ != 0x2803:
                return self.att_err(op, start, 0x0a)
            out = b''
            for dh, props, vh, u in CHARS:
                if start <= dh <= end:
                    out += struct.pack('<HBHH', dh, props, vh, u)
            if not out:
                return self.att_err(op, start, 0x0a)
            self.acl(4, bytes([0x09, 7]) + out)
        elif op == 0x04:                                  # Find Information
            start, end = struct.unpack('<HH', p[1:5])
            out = b''
            for h, u in DESCS:
                if start <= h <= end:
                    out += struct.pack('<HH', h, u)
            if not out:
                return self.att_err(op, start, 0x0a)
            self.acl(4, bytes([0x05, 1]) + out)
        elif op == 0x0a:                                  # Read
            h = struct.unpack('<H', p[1:3])[0]
            if h in CCCD:
                return self.acl(4, bytes([0x0b]) + struct.pack('<H', CCCD[h]))
            if h not in VALUES:
                return self.att_err(op, h, 0x01)
            self.acl(4, bytes([0x0b]) + VALUES[h][:self.mtu-1])
        elif op == 0x0c:                                  # Read Blob
            h, off = struct.unpack('<HH', p[1:5])
            v = VALUES.get(h, b'')
            if off >= len(v):
                return self.acl(4, bytes([0x0d]))
            self.acl(4, bytes([0x0d]) + v[off:off+self.mtu-1])
        elif op == 0x16:                                  # Prepare Write
            h, off = struct.unpack('<HH', p[1:5])
            v = p[5:]
            if h not in VALUES:
                return self.att_err(op, h, 0x01)
            if len(p) > self.mtu:
                return self.att_err(op, h, 0x0d)          # invalid attribute length
            self.prepared.append((h, off, v))
            if corrupt_prepare and v:
                v = bytes([v[0] ^ 0xff]) + v[1:]
                log('echoing a byte that was not sent')
            # the response echoes exactly what was queued, so the
            # client can see the server understood it
            self.acl(4, bytes([0x17]) + struct.pack('<HH', h, off) + v)
        elif op == 0x18:                                  # Execute Write
            flags = p[1]
            q, self.prepared = self.prepared, []
            if refuse_execute and flags != 0:
                log('refusing to commit %d parts' % len(q))
                return self.att_err(op, 0, 0x08)          # insufficient authorisation
            if flags == 0:
                log('write queue cancelled, %d parts dropped' % len(q))
                return self.acl(4, bytes([0x19]))
            for h, off, v in q:
                cur = VALUES.get(h, b'')
                if off > len(cur):
                    cur = cur + bytes(off - len(cur))
                VALUES[h] = cur[:off] + v + cur[off+len(v):]
            if q:
                log('committed %d parts, %s is now %d bytes'
                    % (len(q), hex(q[0][0]), len(VALUES[q[0][0]])))
            self.acl(4, bytes([0x19]))
        elif op == 0x12:                                  # Write
            h = struct.unpack('<H', p[1:3])[0]
            v = p[3:]
            if h in CCCD:
                CCCD[h] = struct.unpack('<H', v[:2])[0]
                self.acl(4, bytes([0x13]))
                if h == 0x0013:
                    if CCCD[h] & 1:
                        threading.Thread(target=self.notify, daemon=True).start()
                elif h == 0x0033 and service_changed and CCCD[h] & 2:
                    threading.Thread(target=self.move_database,
                                     daemon=True).start()
                return
            if h in VALUES:
                VALUES[h] = v
                return self.acl(4, bytes([0x13]))
            self.att_err(op, h, 0x03)
        elif op == 0x1e:                                  # Handle Value Confirmation
            # the answer to an indication, not a request: answering it
            # would put an error response in front of the client's next
            # request
            log('indication confirmed')
        else:
            self.att_err(op, 0, 0x06)                     # request not supported

    def askparams(self):
        # once the link is up and the guest has settled
        time.sleep(2)
        # one a controller will take, then one it will not: the
        # supervision timeout is far too short for that latency, which
        # is the rule that keeps a link from dropping every time the
        # peripheral uses its latency
        for mn, mx, lat, to in ((0x0018, 0x0028, 4, 0x0100),
                                (0x0018, 0x0028, 400, 0x000a)):
            self.sigid = getattr(self, 'sigid', 0) + 1
            body = struct.pack('<HHHH', mn, mx, lat, to)
            self.acl(5, bytes([0x12, self.sigid, len(body), 0]) + body)
            log('asked for %d-%d latency %d timeout %d' % (mn, mx, lat, to))
            time.sleep(3)

    def move_database(self):
        for svc, char, vh, val in LATER:
            # after the guest has finished walking what is there now
            time.sleep(4)
            if svc in SVC:
                continue
            SVC.append(svc)
            CHARS.append(char)
            VALUES[vh] = val
            log('the database moved: %s appeared' % hex(svc[2]))
            # the affected range, which is the new service and not the
            # whole database -- a client that reads the range rather
            # than rediscovering wholesale has something honest to read
            self.acl(4, bytes([0x1d]) + struct.pack('<H', 0x0032)
                     + struct.pack('<HH', svc[0], svc[1]))

    def notify(self):
        level = 90
        while CCCD[0x0013] & 1 and self.handle is not None:
            time.sleep(0.5)
            level = level - 1 if level > 0 else 100
            VALUES[0x0012] = bytes([level])
            if CCCD[0x0013] & 1:
                self.acl(4, bytes([0x1b]) + struct.pack('<H', 0x0012) + bytes([level]))
                self.notified += 1

    # ------------------------------------------------ SMP
    def smp_in(self, p):
        code = p[0]
        self.trace.append(('smp', code))
        log('smp %#04x %s' % (code, p.hex()))
        if code == 0x01:                                  # Pairing Request
            self.smp['preq'] = p
            if p[3] & 0x08:
                # the initiator asked for Secure Connections; this
                # model only does legacy, and says so properly
                return self.smp_send(bytes([0x05, 0x03]))
            pres = bytes([0x02, 0x03, 0x00, 0x01, 16, 0x00, 0x07])
            self.smp['pres'] = pres
            self.smp_send(pres)
        elif code == 0x03:                                # Pairing Confirm
            self.smp['mconfirm'] = p[1:17]
            srand = os.urandom(16)
            self.smp['srand'] = srand
            tk = bytes(16)
            iat, ia = 0, ADDR
            rat, ra = self.peer[0], self.peer[1]
            # from this side, the initiator is the guest: ia is the
            # guest's own address, which is the one it connected from
            ia = self.smp.get('ia', bytes.fromhex('554433221100'))
            sc = c1(tk, srand, self.smp['preq'][:7], self.smp['pres'][:7],
                    iat, rat, ia, ra)
            self.smp_send(bytes([0x03]) + sc)
        elif code == 0x04:                                # Pairing Random
            mrand = p[1:17]
            tk = bytes(16)
            iat, rat = 0, self.peer[0]
            ia = self.smp.get('ia', bytes.fromhex('554433221100'))
            ra = self.peer[1]
            want = c1(tk, mrand, self.smp['preq'][:7], self.smp['pres'][:7],
                      iat, rat, ia, ra)
            if want != self.smp['mconfirm']:
                log('initiator confirm mismatch: %s vs %s'
                    % (want.hex(), self.smp['mconfirm'].hex()))
                return self.smp_send(bytes([0x05, 0x04]))
            self.smp['ok'] = True
            self.smp_send(bytes([0x04]) + self.smp['srand'])
        elif code == 0x05:
            log('the initiator gave up: %s' % p.hex())

    # ------------------------------------------------ H4 parser
    def run(self):
        while not self.stop:
            d = self.c.recv(4096)
            if not d:
                print('bthci: the guest closed the connection', flush=True)
                return
            self.buf += d
            while True:
                if len(self.buf) < 1:
                    break
                t = self.buf[0]
                if t == 1:
                    if len(self.buf) < 4:
                        break
                    plen = self.buf[3]
                    if len(self.buf) < 4 + plen:
                        break
                    op = struct.unpack('<H', self.buf[1:3])[0]
                    params = self.buf[4:4+plen]
                    self.buf = self.buf[4+plen:]
                    self.command(op, params)
                elif t == 2:
                    if len(self.buf) < 5:
                        break
                    dlen = struct.unpack('<H', self.buf[3:5])[0]
                    if len(self.buf) < 5 + dlen:
                        break
                    pkt = self.buf[1:5+dlen]
                    self.buf = self.buf[5+dlen:]
                    self.acldata(pkt)
                else:
                    print('bthci: bad H4 indicator %#04x, giving up' % t,
                          file=sys.stderr, flush=True)
                    self.stop = True
                    return


def main():
    where = sys.argv[1]
    if where.isdigit():
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(('127.0.0.1', int(where)))
    else:
        try:
            os.unlink(where)
        except OSError:
            pass
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.bind(where)
    s.listen(1)
    print('bthci: listening on %s' % where, flush=True)
    c, _ = s.accept()
    print('bthci: guest connected', flush=True)
    m = Model(c)
    try:
        m.run()
    except (BrokenPipeError, ConnectionResetError, OSError) as ex:
        print('bthci: %s' % ex, flush=True)
    print('bthci: %d notifications sent' % m.notified, flush=True)
    print('bthci: done', flush=True)

if __name__ == '__main__':
    main()
