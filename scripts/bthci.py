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
]
# characteristic declarations: (decl handle, props, value handle, uuid)
CHARS = [
    (0x0002, 0x02, 0x0003, 0x2a00),
    (0x0004, 0x02, 0x0005, 0x2a01),
    (0x0011, 0x12, 0x0012, 0x2a19),
]
VALUES = {
    0x0003: b'inferno-bench',
    0x0005: bytes([0x00, 0x00]),
    0x0012: bytes([90]),
}
DESCS = [(0x0013, 0x2902)]

class Model:
    def __init__(self, conn):
        self.c = conn
        self.lock = threading.Lock()
        self.buf = b''
        self.scanning = False
        self.handle = None
        self.peer = None
        self.mtu = 100
        self.cccd = 0
        self.acl_in = b''
        self.pending_acl = 0
        self.smp = {}
        self.notified = 0
        self.stop = False
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
            self.cmd_status(op)
            atype = params[5]
            addr = params[6:12]
            threading.Thread(target=self.connect, args=(atype, addr), daemon=True).start()
        elif op == 0x200e:                     # LE Create Connection Cancel
            self.cmd_complete(op, bytes([0]))
        elif op == 0x0406:                     # Disconnect
            self.cmd_status(op)
            h = struct.unpack('<H', params[0:2])[0]
            time.sleep(0.05)
            self.event(0x05, bytes([0]) + struct.pack('<H', h) + bytes([0x16]))
            self.handle = None
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
                ad = bytes([2, 0x01, 0x06])
                nm = name.encode()
                ad += bytes([len(nm) + 1, 0x09]) + nm
                rep = bytes([1, 0x00, atype]) + addr + bytes([len(ad)]) + ad + bytes([256 - 60])
                self.event(0x3e, bytes([0x02]) + rep)
            time.sleep(0.3)

    def connect(self, atype, addr):
      try:
        time.sleep(0.1)
        self.handle = 0x0040
        self.peer = (atype, addr)
        self.event(0x3e, bytes([0x01, 0x00]) + struct.pack('<H', self.handle)
                   + bytes([0x01, atype]) + addr
                   + struct.pack('<HHH', 0x0028, 0, 0x002a) + bytes([0]))
      except Exception as ex:
        print('bthci: connect thread: %r' % (ex,), flush=True)

    def encrypt_up(self):
        time.sleep(0.05)
        self.event(0x08, bytes([0]) + struct.pack('<H', self.handle) + bytes([1]))
        # then distribute the keys the pairing response promised
        time.sleep(0.05)
        self.l2 = None
        ltk = bytes(range(16))
        self.smp_send(bytes([0x06]) + ltk)
        self.smp_send(bytes([0x07]) + struct.pack('<H', 0x1234) + bytes(range(8)))
        self.smp_send(bytes([0x08]) + bytes(range(16, 32)))
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
            if h == 0x0013:
                return self.acl(4, bytes([0x0b]) + struct.pack('<H', self.cccd))
            if h not in VALUES:
                return self.att_err(op, h, 0x01)
            self.acl(4, bytes([0x0b]) + VALUES[h][:self.mtu-1])
        elif op == 0x0c:                                  # Read Blob
            h, off = struct.unpack('<HH', p[1:5])
            v = VALUES.get(h, b'')
            if off >= len(v):
                return self.acl(4, bytes([0x0d]))
            self.acl(4, bytes([0x0d]) + v[off:off+self.mtu-1])
        elif op == 0x12:                                  # Write
            h = struct.unpack('<H', p[1:3])[0]
            v = p[3:]
            if h == 0x0013:
                self.cccd = struct.unpack('<H', v[:2])[0]
                self.acl(4, bytes([0x13]))
                if self.cccd & 1:
                    threading.Thread(target=self.notify, daemon=True).start()
                return
            if h in VALUES:
                VALUES[h] = v
                return self.acl(4, bytes([0x13]))
            self.att_err(op, h, 0x03)
        else:
            self.att_err(op, 0, 0x06)                     # request not supported

    def notify(self):
        level = 90
        while self.cccd & 1 and self.handle is not None:
            time.sleep(0.5)
            level = level - 1 if level > 0 else 100
            VALUES[0x0012] = bytes([level])
            if self.cccd & 1:
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
