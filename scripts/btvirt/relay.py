#!/usr/bin/env python3
#
# A capturing relay between the guest and the container.
#
# btfs dials tcp!, and btvirt is behind a published port, so nothing
# here has to be in the middle -- except that being in the middle is
# how the conversation gets captured.  Everything the bench learned
# from pointing Wireshark at scripts/bthci.py applies here too, and
# here it is a capture of this stack talking to BlueZ rather than to a
# model written by the same reader.
#
# The framing is H4 both ways, which is what btvirt's server socket
# speaks and what btfs speaks, so the packets can be cut out of the
# stream and written one to a btsnoop record.
#
import socket
import struct
import sys
import threading
import time

SNOOP_EPOCH = 0x00E03AB44A676000
SNOOP_H4 = 1002


class Snoop:
    def __init__(self, path):
        self.f = open(path, 'wb')
        self.f.write(b'btsnoop\0' + (1).to_bytes(4, 'big')
                     + SNOOP_H4.to_bytes(4, 'big'))
        self.lock = threading.Lock()

    def packet(self, data, fromhost):
        if not data:
            return
        flags = 0 if fromhost else 1
        if data[0] in (1, 4):                   # a command or an event
            flags |= 2
        us = SNOOP_EPOCH + int(time.time() * 1000000)
        with self.lock:
            self.f.write(len(data).to_bytes(4, 'big')
                         + len(data).to_bytes(4, 'big')
                         + flags.to_bytes(4, 'big')
                         + (0).to_bytes(4, 'big')
                         + us.to_bytes(8, 'big')
                         + data)
            self.f.flush()


#
# How long a packet of each H4 type is: the type byte, a header, and a
# length field whose width and place depend on the type.  A stream
# gives no boundaries, so this is the only way to know where one
# packet stops.
#
def packets(buf):
    out = []
    off = 0
    while off < len(buf):
        t = buf[off]
        if t == 1:                              # command
            if len(buf) - off < 4:
                break
            n = 4 + buf[off + 3]
        elif t == 2:                            # ACL
            if len(buf) - off < 5:
                break
            n = 5 + struct.unpack('<H', buf[off + 3:off + 5])[0]
        elif t == 3:                            # SCO
            if len(buf) - off < 4:
                break
            n = 4 + buf[off + 3]
        elif t == 4:                            # event
            if len(buf) - off < 3:
                break
            n = 3 + buf[off + 2]
        else:
            raise ValueError('packet type %#04x' % t)
        if len(buf) - off < n:
            break
        out.append(buf[off:off + n])
        off += n
    return out, buf[off:]


def pump(src, dst, snoop, fromhost):
    buf = b''
    try:
        while True:
            d = src.recv(4096)
            if not d:
                break
            dst.sendall(d)
            buf += d
            pkts, buf = packets(buf)
            for p in pkts:
                snoop.packet(p, fromhost)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def main():
    if len(sys.argv) != 5:
        print('usage: relay.py listenport upstreamhost upstreamport capture',
              file=sys.stderr)
        return 2
    port, uphost, upport, cap = (int(sys.argv[1]), sys.argv[2],
                                 int(sys.argv[3]), sys.argv[4])
    snoop = Snoop(cap)
    ln = socket.socket()
    ln.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ln.bind(('127.0.0.1', port))
    ln.listen(5)
    print('relay: %d -> %s:%d, capturing to %s' % (port, uphost, upport, cap),
          flush=True)
    while True:
        c, nil = ln.accept()
        u = socket.create_connection((uphost, upport))
        c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        u.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        threading.Thread(target=pump, args=(c, u, snoop, True),
                         daemon=True).start()
        threading.Thread(target=pump, args=(u, c, snoop, False),
                         daemon=True).start()


if __name__ == '__main__':
    sys.exit(main() or 0)
