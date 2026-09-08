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

# --peripheral: the model plays the central for once.  It waits for the
# guest to enable advertising, checks that what is advertised is what
# the guest was told to advertise, opens a link to it -- an LE
# Connection Complete with role 0x01, meaning the guest is the
# peripheral -- and later closes it.  This is the half of Bluetooth the
# stack could not do at all: being found, and being connected to.
peripheral = '--peripheral' in sys.argv

# --loopback: the model is a wire and nothing else.  The guest opens a
# link out to it and it opens a link in to the guest, and every ACL
# packet on one is delivered on the other.  So the guest's own GATT
# client, which twenty phases already trust, walks the guest's own GATT
# server, and nothing in this file has to understand ATT.  A model that
# spoke ATT here would be a second implementation written from the same
# reading as the first, and a mistake they shared would agree with
# itself; a wire cannot.
loopback = '--loopback' in sys.argv

# --badwrite: with --loopback, the model stops being only a wire for
# one frame and behaves as a peer that does not play by the rules: it
# writes an attribute the server said was read-only.  A well behaved
# client never tries -- btfs gives that file mode 0444, so the write is
# refused before it leaves the guest -- so the server's own permission
# check is reachable from nowhere else.  The answer is intercepted
# rather than relayed, because it is this model's answer and not
# anything the guest's client asked for.
badwrite = '--badwrite' in sys.argv

# --pairin: with --peripheral, the model does not stop at opening a
# link to the guest: it initiates pairing over it, so what is exercised
# is the guest's SMP *responder* -- the half a peripheral needs and
# which nothing else in this bench reaches.  The model already has c1
# and s1, written here and validated in the other direction by the
# pair phase, where the guest initiates and this model responds; using
# them the other way round tests the new half against an implementation
# that already agrees with the old one.
pairin = '--pairin' in sys.argv

# --rebond: with --pairin, the peer does not stop at pairing.  It
# closes the link, opens it again, and starts encryption naming the
# long term key the guest distributed -- which is what a bonded device
# does every time afterwards, and which only works if the guest can
# find that key again from its diversifier.  The guest must not be
# asked to pair a second time.
rebond = '--rebond' in sys.argv

# --hid: the peripheral is a keyboard and a mouse over GATT.  A HID
# service is added with the two boot reports and the protocol mode
# characteristic in it, and once the guest has selected the boot
# protocol and subscribed, a few keystrokes and a movement are sent as
# notifications.  Nothing here parses a report map: the boot protocol
# is a fixed layout, which is the whole reason it exists.
hid = '--hid' in sys.argv

# --hidreport: the peripheral is a keyboard and a mouse over GATT
# again, but in the report protocol.  There is no Protocol Mode
# characteristic and there are no boot reports -- a HOGP device only
# has to have Protocol Mode if it supports boot -- so the host cannot
# ask for the fixed layout and has to read the report map and work out
# where the fields are.  The mouse report is deliberately four bytes
# rather than the boot protocol's three, with a wheel on the end, so a
# host that assumed the boot layout would be reading the wrong bytes
# and could not be told from one that had parsed the map.
hidreport = '--hidreport' in sys.argv

# --hidswap: with --hidreport, tell the two Report Reference
# descriptors the wrong way round -- the mouse characteristic says
# report 2 and the keyboard says report 1 -- while sending exactly
# what --hidreport sends.  A host that reads the descriptors then has
# the keyboard and the pointer swapped and produces nothing; a host
# that ignored them and guessed by order would not notice, which is
# what makes this the control for reading them at all.
hidswap = '--hidswap' in sys.argv

# --hidnomap: with --hidreport, serve an empty Report Map.  There is
# then nothing to say what any report contains, and a host that had
# quietly assumed a layout would carry on regardless.
hidnomap = '--hidnomap' in sys.argv

# --classic: answer a Classic inquiry.  Two devices: one that sends an
# extended inquiry response with its name in it, and one that sends the
# plain Inquiry Result with RSSI and has to be asked its name over a
# Remote Name Request.  Both shapes are real and a stack that only
# handles the first finds half the room.
#
# This is the only Classic thing the model does.  There is no BR/EDR
# connection, no link key and no L2CAP over one: inquiry and the name
# behind it stand alone, which is why they can be modelled without any
# of that.
classic = '--classic' in sys.argv

# --brconnect: with --classic, the second device also answers a page,
# so a BR/EDR link can be opened to it and taken down again.  Nothing
# runs over the link: L2CAP's signalling channel is a different CID on
# Classic and there is no Classic L2CAP here, so what is modelled is
# the connection and nothing above it.
brconnect = '--brconnect' in sys.argv

# --brincoming: with --brconnect, the device pages this side once the
# inquiry is over, so the guest gets a Connection Request it has to
# accept.  The completion that follows is the same event an outgoing
# attempt gets, and telling them apart is the guest's problem: the
# event does not say which side opened the link.
brincoming = '--brincoming' in sys.argv

# --brfail: with --brconnect, the page fails with a page timeout.  A
# connection that fails has to fail, and the one after it has to work.
brfail = '--brfail' in sys.argv

# --noeir: with --classic, neither device sends an extended inquiry
# response, so both names have to be paged for.  It is the control for
# the name request: a stack that read the name out of the inquiry
# result and never asked would find one name here and should find two.
noeir = '--noeir' in sys.argv

# --h5: frame everything in H5, the three-wire transport, instead of
# H4.  SLIP delimiters and escapes, a four byte header with sequence
# and acknowledgement numbers, and the sync/configure handshake before
# anything else may pass.  Above the framing nothing changes -- the
# same commands and the same events -- which is the point of a
# transport.
h5 = '--h5' in sys.argv

# --h5-drop-ack N: swallow the Nth acknowledgement this side would
# send, so the guest gets none for that packet and has to send it
# again.  Retransmission is the whole reason H5 exists and it is
# invisible when nothing is ever lost.
h5_drop_ack = 0
if '--h5-drop-ack' in sys.argv:
    h5_drop_ack = int(sys.argv[sys.argv.index('--h5-drop-ack') + 1])

# --h5-dup N: send the Nth packet from this side twice with the same
# sequence number, as a controller does when it did not see an
# acknowledgement.  The guest must act on it once.
h5_dup = 0
if '--h5-dup' in sys.argv:
    h5_dup = int(sys.argv[sys.argv.index('--h5-dup') + 1])

SLIP_DELIM = 0xc0
SLIP_ESC = 0xdb
SLIP_ESC_DELIM = 0xdc
SLIP_ESC_ESC = 0xdd

# --addr XXXXXXXXXXXX: this controller's own BD_ADDR, most significant
# byte first, so two models in one bench are two radios and not the
# same one twice.  A bond records the controller it was made on, and
# with one address between them that record would be worthless.
def _argaddr():
    if '--addr' in sys.argv:
        h = sys.argv[sys.argv.index('--addr') + 1]
        return bytes(reversed(bytes.fromhex(h)))
    return None

# --coc-overrun: on an LE credit-based channel the peripheral sends one
# segment more than the credits it was given.  The guest must treat
# that as the protocol violation it is and take the channel down,
# rather than quietly absorbing it: credits are the only thing keeping
# a receiver's buffer bounded, and a receiver that accepts a segment it
# did not pay for has no bound at all.
coc_overrun = '--coc-overrun' in sys.argv

# --coc-stingy: the peripheral grants one credit at a time and takes
# its time about the rest, so the guest's writer has to wait rather
# than drop.  With this off the peer grants enough to keep going.
coc_stingy = '--coc-stingy' in sys.argv

# --coc-bigsdu: the peripheral announces an SDU longer than the MTU the
# guest asked for.  The guest must refuse it.
coc_bigsdu = '--coc-bigsdu' in sys.argv

# The PSM the model's echo service answers on.  Anything else is
# refused with "PSM not supported", which is what a real peripheral
# does and what the guest has to report rather than swallow.
COCPSM = 0x0080
COCMTU = 512
COCMPS = 40

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

ADDR = _argaddr() or bytes.fromhex('554433221100')   # 001122334455 written down
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
    # a primary service that includes a secondary one
    (0x0060, 0x0064, 0xfff2),
]

# Secondary services.  These are deliberately NOT in SVC: a secondary
# service does not appear in primary service discovery, so a client
# that ignores include declarations cannot reach it at all -- which is
# what makes ignoring them lose attributes and not merely a cross
# reference.
SECONDARY = [
    (0x0070, 0x0072, 0xfffa),
]

#
# Human Interface Device, boot protocol.  Protocol Mode is written to
# select boot; the two input reports notify.
#
HIDSVC = (0x0080, 0x0089, 0x1812)
HIDCHARS = [
    (0x0081, 0x06, 0x0082, 0x2a4e),   # protocol mode: read, write without response
    (0x0083, 0x12, 0x0084, 0x2a22),   # boot keyboard input report: read, notify
    (0x0086, 0x12, 0x0087, 0x2a33),   # boot mouse input report: read, notify
]
HIDVALUES = {
    0x0082: bytes([0x01]),            # report protocol until told otherwise
    0x0084: bytes(8),
    0x0087: bytes(3),
}
HIDDESCS = [(0x0085, 0x2902), (0x0088, 0x2902)]

#
# Human Interface Device, report protocol.  A report map, two Report
# characteristics, and the Report Reference descriptor on each that
# says which report id it carries and that it is an input report.
#
# The map is a real HID report descriptor and is written out item by
# item, because what it says is the whole of what the host has to work
# from.  It is also longer than this bench's ATT MTU, so reading it
# takes a Read Blob as it does on a real device.
#
REPORTMAP = bytes([
    # a mouse, report id 1: three button bits, five of padding, and
    # three signed bytes -- x, y and a wheel the boot protocol has no
    # room for
    0x05, 0x01,             # Usage Page (Generic Desktop)
    0x09, 0x02,             # Usage (Mouse)
    0xa1, 0x01,             # Collection (Application)
    0x85, 0x01,             #   Report ID (1)
    0x09, 0x01,             #   Usage (Pointer)
    0xa1, 0x00,             #   Collection (Physical)
    0x05, 0x09,             #     Usage Page (Button)
    0x19, 0x01,             #     Usage Minimum (1)
    0x29, 0x03,             #     Usage Maximum (3)
    0x15, 0x00,             #     Logical Minimum (0)
    0x25, 0x01,             #     Logical Maximum (1)
    0x75, 0x01,             #     Report Size (1)
    0x95, 0x03,             #     Report Count (3)
    0x81, 0x02,             #     Input (Data, Variable, Absolute)
    0x95, 0x01,             #     Report Count (1)
    0x75, 0x05,             #     Report Size (5)
    0x81, 0x01,             #     Input (Constant)
    0x05, 0x01,             #     Usage Page (Generic Desktop)
    0x09, 0x30,             #     Usage (X)
    0x09, 0x31,             #     Usage (Y)
    0x09, 0x38,             #     Usage (Wheel)
    0x15, 0x81,             #     Logical Minimum (-127)
    0x25, 0x7f,             #     Logical Maximum (127)
    0x75, 0x08,             #     Report Size (8)
    0x95, 0x03,             #     Report Count (3)
    0x81, 0x06,             #     Input (Data, Variable, Relative)
    0xc0,                   #   End Collection
    0xc0,                   # End Collection
    # a keyboard, report id 2: eight modifier bits, a reserved byte,
    # and six key codes.  The mouse is first and has the lower id on
    # purpose: nothing but the map and the Report Reference
    # descriptors says which of the two Report characteristics is
    # which, so a host that assumed the first one was the keyboard
    # would have them exactly the wrong way round.
    0x05, 0x01,             # Usage Page (Generic Desktop)
    0x09, 0x06,             # Usage (Keyboard)
    0xa1, 0x01,             # Collection (Application)
    0x85, 0x02,             #   Report ID (2)
    0x05, 0x07,             #   Usage Page (Keyboard/Keypad)
    0x19, 0xe0,             #   Usage Minimum (Left Control)
    0x29, 0xe7,             #   Usage Maximum (Right GUI)
    0x15, 0x00,             #   Logical Minimum (0)
    0x25, 0x01,             #   Logical Maximum (1)
    0x75, 0x01,             #   Report Size (1)
    0x95, 0x08,             #   Report Count (8)
    0x81, 0x02,             #   Input (Data, Variable, Absolute)
    0x95, 0x01,             #   Report Count (1)
    0x75, 0x08,             #   Report Size (8)
    0x81, 0x01,             #   Input (Constant)
    0x05, 0x07,             #   Usage Page (Keyboard/Keypad)
    0x19, 0x00,             #   Usage Minimum (0)
    0x29, 0xff,             #   Usage Maximum (255)
    0x15, 0x00,             #   Logical Minimum (0)
    0x26, 0xff, 0x00,       #   Logical Maximum (255)
    0x75, 0x08,             #   Report Size (8)
    0x95, 0x06,             #   Report Count (6)
    0x81, 0x00,             #   Input (Data, Array)
    0xc0,                   # End Collection
])

HIDRSVC = (0x0080, 0x008c, 0x1812)
HIDRCHARS = [
    (0x0081, 0x02, 0x0082, 0x2a4b),   # report map: read
    (0x0083, 0x12, 0x0084, 0x2a4d),   # input report: read, notify
    (0x0087, 0x12, 0x0088, 0x2a4d),   # input report: read, notify
    (0x008b, 0x02, 0x008c, 0x2a4a),   # HID information: read
]
HIDRDESCS = [(0x0085, 0x2902), (0x0086, 0x2908),
             (0x0089, 0x2902), (0x008a, 0x2908)]
HIDRVALUES = {
    0x0082: REPORTMAP,
    0x0084: bytes(4),                 # the mouse, four bytes
    0x0086: bytes([0x01, 0x01]),      # report id 1, input
    0x0088: bytes(8),                 # the keyboard, eight
    0x008a: bytes([0x02, 0x01]),      # report id 2, input
    0x008c: bytes([0x11, 0x01, 0x00, 0x02]),   # HID 1.11, no country
}

# include declarations: (handle, included start, included end, uuid or
# None for a 128 bit one the declaration may not carry)
INCLUDES = [
    (0x0061, 0x0070, 0x0072, 0xfffa),
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
    (0x0062, 0x02, 0x0063, 0xfff3),
    (0x0071, 0x02, 0x0072, 0xfffb),
]
VALUES = {
    0x0003: b'inferno-bench',
    0x0005: bytes([0x00, 0x00]),
    0x0012: bytes([90]),
    0x0022: b'',
    0x0032: b'',
    0x0063: b'in the including service',
    0x0072: b'only reachable through the include',
}

# client characteristic configuration, per descriptor handle
CCCD = {0x0013: 0, 0x0033: 0}
DESCS = [(0x0013, 0x2902), (0x0033, 0x2902)]

if hid:
    SVC.append(HIDSVC)
    CHARS.extend(HIDCHARS)
    VALUES.update(HIDVALUES)
    DESCS.extend(HIDDESCS)
    for h, nil in HIDDESCS:
        CCCD[h] = 0

if hidswap:
    HIDRVALUES[0x0086] = bytes([0x02, 0x01])
    HIDRVALUES[0x008a] = bytes([0x01, 0x01])
if hidnomap:
    HIDRVALUES[0x0082] = b''
if hidreport:
    SVC.append(HIDRSVC)
    CHARS.extend(HIDRCHARS)
    VALUES.update(HIDRVALUES)
    DESCS.extend(HIDRDESCS)
    # only the two client configurations are CCCDs; the Report
    # Reference descriptors are read like any other value
    CCCD[0x0085] = 0
    CCCD[0x0089] = 0

#
# The two Classic devices an inquiry finds: BD_ADDR, class of device,
# page scan repetition mode, clock offset, and the name each answers
# with.  A BD_ADDR goes on the wire least significant byte first, the
# same way an LE address does.
#
CLASSICDEVS = [
    (bytes.fromhex('665544332211')[::-1], 0x2c0104, 0x01, 0x1234, 'classic-keyboard', True),
    (bytes.fromhex('ccbbaa998877')[::-1], 0x200404, 0x02, 0x4321, 'classic-headset', False),
]


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
        # LE credit-based channels, keyed by the CID the guest sends to
        self.h5_txseq = 0         # H5: the sequence number of the next packet out
        self.h5_txack = 0         # what to acknowledge
        self.h5_sent = 0          # reliable packets sent, for --h5-dup
        self.h5_acks = 0          # acknowledgements sent, for --h5-drop-ack
        self.h5_dupwatch = None   # an ack number only a duplicate would produce
        self.h5_state = 'uninit'
        self.h5_buf = bytearray()
        self.h5_inframe = False
        self.h5_esc = False
        self.smp2 = {}            # this model's own pairing, as the initiator
        self.negative = False     # the peripheral said it has no such key
        self.ltkgiven = None      # what the peripheral answered a key request with
        self.badpending = False   # an injected write is waiting for its answer
        self.inhandle = None      # the link the model opened to the guest
        self.outhandle = None     # the link the guest opened to the model
        self.acl_in2 = b''        # reassembly for the second link
        self.advertising = False
        self.advdata = b''
        self.advparams = None
        self.coc = {}
        self.cocsigid = 0x40
        self.cocsdus = []         # whole SDUs this side reassembled

    # ------------------------------------------------ wire
    def send(self, data):
        if h5:
            return self.h5_send(data[0], data[1:])
        with self.lock:
            log('-> %s' % data[:32].hex())
            self.c.sendall(data)

    #
    # H5 out.  A packet type this side sends reliably carries a
    # sequence number and expects an acknowledgement; an ack packet
    # and a link message carry neither.
    #
    def h5_send(self, ptype, payload, reliable=None):
        if reliable is None:
            reliable = ptype in (0x01, 0x02, 0x04, 0x05)
        with self.lock:
            hdr = bytearray(4)
            if reliable:
                hdr[0] |= self.h5_txseq & 0x07
                hdr[0] |= 0x80
            hdr[0] |= (self.h5_txack & 0x07) << 3
            hdr[1] = (ptype & 0x0f) | ((len(payload) & 0x0f) << 4)
            hdr[2] = (len(payload) >> 4) & 0xff
            hdr[3] = 0xff - ((hdr[0] + hdr[1] + hdr[2]) & 0xff)
            frame = bytes(hdr) + bytes(payload)
            out = bytearray([SLIP_DELIM])
            for b in frame:
                if b == SLIP_DELIM:
                    out += bytes([SLIP_ESC, SLIP_ESC_DELIM])
                elif b == SLIP_ESC:
                    out += bytes([SLIP_ESC, SLIP_ESC_ESC])
                else:
                    out.append(b)
            out.append(SLIP_DELIM)
            log('h5 -> seq %d ack %d type %d len %d'
                % (hdr[0] & 7, (hdr[0] >> 3) & 7, ptype, len(payload)))
            self.c.sendall(bytes(out))
            if reliable:
                self.h5_sent += 1
                if h5_dup and self.h5_sent == h5_dup:
                    print('bthci: sending packet %d again, same sequence'
                          % self.h5_txseq, flush=True)
                    self.c.sendall(bytes(out))
                    #
                    # What a guest that counted the duplicate would do
                    # next: acknowledge two packets where one was
                    # sent.  Watched for until this side actually
                    # sends that next packet, after which the same
                    # number is legitimate.
                    #
                    self.h5_dupwatch = (self.h5_txseq + 2) & 7
                elif self.h5_dupwatch is not None:
                    self.h5_dupwatch = None
                self.h5_txseq = (self.h5_txseq + 1) & 7

    def event(self, code, params):
        self.send(bytes([4, code, len(params)]) + params)

    def cmd_complete(self, op, params):
        self.event(0x0e, bytes([1]) + struct.pack('<H', op) + params)

    def cmd_status(self, op, status=0):
        self.event(0x0f, bytes([status, 1]) + struct.pack('<H', op))

    def acl(self, cid, payload):
        #
        # A link that has gone takes its handle with it, and a thread
        # that was sending on it -- the notification loop, say -- is
        # still between its check and its send.  Answer that here
        # rather than in every caller: an exception in a daemon thread
        # is a thread that quietly stops, which is a bench that hangs
        # somewhere else entirely.
        #
        if self.handle is None:
            return
        # one ACL packet per L2CAP frame; the guest's own fragmentation
        # is exercised on the way down, not up
        frame = struct.pack('<HH', len(payload), cid) + payload
        pkt = struct.pack('<HH', self.handle & 0x0fff | (0x2 << 12), len(frame)) + frame
        self.send(bytes([2]) + pkt)

    def credits(self, n=1, handle=None):
        # the handle matters: in loopback there are two links and no
        # single "current" one, and a Number Of Completed Packets for
        # a handle that is None is not a packet count at all
        if handle is None:
            handle = self.handle
        if handle is None:
            return
        self.event(0x13, bytes([1]) + struct.pack('<HH', handle, n))

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
        elif op == 0x2006:                     # LE Set Advertising Parameters
            if len(params) != 15:
                print('bthci: adv params are %d bytes, want 15' % len(params), flush=True)
                self.cmd_complete(op, bytes([0x12]))   # invalid parameters
            else:
                mn, mx, ty, own = struct.unpack('<HHBB', params[0:6])
                self.advparams = (mn, mx, ty, own)
                print('bthci: adv params %d-%d type %#04x own %d'
                      % (mn, mx, ty, own), flush=True)
                self.cmd_complete(op, bytes([0]))
        elif op == 0x2008 or op == 0x2009:     # LE Set Advertising / Scan Response Data
            if len(params) != 32:
                # a controller refuses anything but the fixed block
                print('bthci: adv data is %d bytes, want 32' % len(params), flush=True)
                self.cmd_complete(op, bytes([0x12]))
            else:
                n = params[0]
                d = params[1:1+n]
                if op == 0x2008:
                    self.advdata = d
                    print('bthci: adv data %s' % d.hex(), flush=True)
                else:
                    print('bthci: scan response %s' % d.hex(), flush=True)
                self.cmd_complete(op, bytes([0]))
        elif op == 0x200a:                     # LE Set Advertise Enable
            self.advertising = params[0] != 0
            print('bthci: advertising %s' % ('on' if self.advertising else 'off'), flush=True)
            self.cmd_complete(op, bytes([0]))
            if self.advertising and (peripheral or loopback):
                threading.Thread(target=self.connect_in, daemon=True).start()
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
            # only the link that went: a BR/EDR handle going away is
            # not the LE one going away, and forgetting the wrong one
            # silently stops every notification on it
            if h == self.handle:
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
            if loopback:
                # the central started encryption on one link; the
                # controller's job is to ask the peripheral on the
                # other for the key and compare the two
                threading.Thread(target=self.encrypt_across,
                                 args=(params,), daemon=True).start()
            else:
                threading.Thread(target=self.encrypt_up, daemon=True).start()
        elif op == 0x201a:                     # LE Long Term Key Request Reply
            handle = struct.unpack('<H', params[0:2])[0]
            self.ltkgiven = params[2:18]
            self.cmd_complete(op, bytes([0]) + struct.pack('<H', handle))
        elif op == 0x201b:                     # LE Long Term Key Request Negative Reply
            handle = struct.unpack('<H', params[0:2])[0]
            self.ltkgiven = None
            self.negative = True
            print('bthci: the peripheral has no key for that request', flush=True)
            self.cmd_complete(op, bytes([0]) + struct.pack('<H', handle))
        elif op == 0x0401 and classic:            # Inquiry
            lap = params[0] | (params[1] << 8) | (params[2] << 16)
            if lap != 0x9e8b33:
                print('bthci: inquiry on LAP %#08x, not the GIAC' % lap, flush=True)
            print('bthci: inquiry, %d units' % params[3], flush=True)
            # a command status, not a complete: the answers are events
            self.cmd_status(op)
            self.inquiring = True
            threading.Thread(target=self.inquire, daemon=True).start()
        elif op == 0x0402 and classic:            # Inquiry Cancel
            print('bthci: inquiry cancelled', flush=True)
            self.inquiring = False
            self.cmd_complete(op, bytes([0]))
        elif op == 0x0405 and brconnect:          # Create Connection
            addr = params[0:6]
            self.cmd_status(op)
            if brfail and not getattr(self, 'brtried', False):
                self.brtried = True
                print('bthci: page fails', flush=True)
                # 0x04 page timeout: the device did not answer
                self.event(0x03, bytes([0x04]) + struct.pack('<H', 0)
                           + addr + bytes([1, 0]))
                return
            self.brhandle = 0x0080
            print('bthci: br/edr link to %s' % addr[::-1].hex(), flush=True)
            self.event(0x03, bytes([0]) + struct.pack('<H', self.brhandle)
                       + addr + bytes([1, 0]))
        elif op == 0x0409 and brconnect:          # Accept Connection Request
            addr = params[0:6]
            print('bthci: the host accepted a page, role %d' % params[6],
                  flush=True)
            self.cmd_status(op)
            self.brhandle = 0x0081
            self.event(0x03, bytes([0]) + struct.pack('<H', self.brhandle)
                       + addr + bytes([1, 0]))
        elif op == 0x0419 and classic:            # Remote Name Request
            addr = params[0:6]
            self.cmd_status(op)
            name = None
            for a, cls, psrm, clk, nm, eir in CLASSICDEVS:
                if a == addr:
                    name = nm
            if name is None:
                # page timeout: a device that is not there
                self.event(0x07, bytes([0x04]) + addr + bytes(248))
                return
            print('bthci: name asked for %s' % addr[::-1].hex(), flush=True)
            n = name.encode()[:248]
            self.event(0x07, bytes([0]) + addr + n + bytes(248 - len(n)))
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
        self.outhandle = handle
        self.peer = (atype, addr)
        # Role 0x00: the guest asked for this link, so the guest is the
        # central.  It said 0x01 for years because nothing above looked
        # at the field; the peripheral role is what made it matter, and
        # a guest that believes a link it opened was opened to it hands
        # the connection to the wrong half of itself.
        self.event(0x3e, bytes([0x01, 0x00]) + struct.pack('<H', handle)
                   + bytes([0x00, atype]) + addr
                   + struct.pack('<HHH', 0x0028, 0, 0x002a) + bytes([0]))
        if sco:
            threading.Thread(target=self.scostream, daemon=True).start()
        if ask_params:
            threading.Thread(target=self.askparams, daemon=True).start()

    #
    # Two links, one wire, and the controller in the middle.  The
    # central hands the key it derived to its own controller; the
    # peripheral is asked for the key it derived and hands that over.
    # A real controller compares them and encrypts only if they agree,
    # which is the whole of what encryption proves about pairing --
    # and it is a comparison, not an implementation of SMP, so the
    # model can make it without becoming a second implementation of
    # the thing under test.
    #
    def encrypt_across(self, params):
        rand = params[2:10]
        ediv = struct.unpack('<H', params[10:12])[0]
        want = params[12:28]
        self.ltkgiven = None
        if self.inhandle is None:
            print('bthci: encryption asked for with no second link', flush=True)
            return
        self.event(0x3e, bytes([0x05]) + struct.pack('<H', self.inhandle)
                   + rand + struct.pack('<H', ediv))
        for _ in range(100):
            if self.ltkgiven is not None:
                break
            time.sleep(0.05)
        if self.ltkgiven is None:
            print('bthci: the peripheral never answered the key request', flush=True)
            self.event(0x08, bytes([0x05]) + struct.pack('<H', self.outhandle) + bytes([0]))
            return
        if self.ltkgiven != want:
            print('bthci: the two sides derived different keys, so no encryption',
                  flush=True)
            self.event(0x08, bytes([0x06]) + struct.pack('<H', self.outhandle) + bytes([0]))
            self.event(0x08, bytes([0x06]) + struct.pack('<H', self.inhandle) + bytes([0]))
            return
        print('bthci: both sides derived the same key; the link is encrypted', flush=True)
        self.event(0x08, bytes([0]) + struct.pack('<H', self.inhandle) + bytes([1]))
        self.event(0x08, bytes([0]) + struct.pack('<H', self.outhandle) + bytes([1]))

    #
    # The model as the initiator.  The guest is the peripheral on this
    # link, so it is the responder, and the addresses go into c1 in the
    # order the specification names them: the initiator's first, which
    # here is this model's.
    #
    def pair_out(self, myaddr):
        self.smp2 = {'ia': myaddr, 'iat': 0, 'ra': ADDR, 'rat': 0}
        preq = bytes([0x01, 0x03, 0x00, 0x01, 16, 0x00, 0x00])
        self.smp2['preq'] = preq
        self.smp2['mrand'] = os.urandom(16)
        print('bthci: pairing with the guest', flush=True)
        self.acl(6, preq)

    def smp_initiator(self, p):
        code = p[0]
        d = self.smp2
        if code == 0x02:                                  # Pairing Response
            d['pres'] = p
            tk = bytes(16)
            mc = c1(tk, d['mrand'], d['preq'][:7], d['pres'][:7],
                    d['iat'], d['rat'], d['ia'], d['ra'])
            self.acl(6, bytes([0x03]) + mc)
        elif code == 0x03:                                # Pairing Confirm
            d['sconfirm'] = p[1:17]
            self.acl(6, bytes([0x04]) + d['mrand'])
        elif code == 0x04:                                # Pairing Random
            srand = p[1:17]
            tk = bytes(16)
            want = c1(tk, srand, d['preq'][:7], d['pres'][:7],
                      d['iat'], d['rat'], d['ia'], d['ra'])
            if want != d['sconfirm']:
                print('bthci: the responder confirm does not match', flush=True)
                self.acl(6, bytes([0x05, 0x04]))
                return
            d['stk'] = s1(tk, srand, d['mrand'])
            print('bthci: the responder confirm matches', flush=True)
            threading.Thread(target=self.ask_for_key, daemon=True).start()
        elif code == 0x06:                                # Encryption Information
            d['ltk'] = p[1:17]
            print('bthci: the guest distributed a long term key', flush=True)
        elif code == 0x07:                                # Central Identification
            d['ediv'] = struct.unpack('<H', p[1:3])[0]
            d['rand'] = p[3:11]
            print('bthci: and the numbers that name it: ediv %#06x'
                  % d['ediv'], flush=True)
            if rebond:
                threading.Thread(target=self.come_back, daemon=True).start()
        elif code == 0x05:
            print('bthci: the guest refused to pair: %s' % p.hex(), flush=True)

    #
    # As the controller: the central has started encryption, so ask the
    # peripheral for the key and see whether it is the one this side
    # derived.  That comparison is the whole of what encryption proves
    # about a pairing, and it is a comparison rather than a second
    # implementation of the derivation.
    #
    def ask_for_key(self):
        time.sleep(0.1)
        self.ltkgiven = None
        self.event(0x3e, bytes([0x05]) + struct.pack('<H', self.inhandle)
                   + bytes(8) + bytes(2))
        for _ in range(100):
            if self.ltkgiven is not None:
                break
            time.sleep(0.05)
        if self.ltkgiven is None:
            print('bthci: the guest never answered the key request', flush=True)
            return
        if self.ltkgiven != self.smp2['stk']:
            print('bthci: the guest derived a different key, so no encryption',
                  flush=True)
            self.event(0x08, bytes([0x06]) + struct.pack('<H', self.inhandle) + bytes([0]))
            return
        print('bthci: the guest derived the same short term key', flush=True)
        self.event(0x08, bytes([0]) + struct.pack('<H', self.inhandle) + bytes([1]))

    #
    # A bonded peer coming back: close the link, open it again, and
    # start encryption naming the key that was distributed.  The guest
    # has to find it from the diversifier and answer with it; if it
    # cannot, the honest answer is the negative reply and the peer
    # would have to pair again, which is exactly what this checks does
    # not happen.
    #
    def come_back(self):
        d = self.smp2
        time.sleep(2)
        print('bthci: closing the link and coming back', flush=True)
        self.event(0x05, bytes([0x00]) + struct.pack('<H', self.inhandle) + bytes([0x13]))
        time.sleep(2)
        addr = bytes.fromhex('efbeadde0000')
        self.inhandle = 0x0042
        rep = struct.pack('<BHBB', 0x00, self.inhandle, 0x01, 0x00) + addr \
              + struct.pack('<HHHB', 0x0028, 0, 0x002a, 0)
        self.event(0x3e, bytes([0x01]) + rep)
        time.sleep(1)
        self.ltkgiven = None
        self.negative = False
        self.event(0x3e, bytes([0x05]) + struct.pack('<H', self.inhandle)
                   + d['rand'] + struct.pack('<H', d['ediv']))
        for _ in range(100):
            if self.ltkgiven is not None or self.negative:
                break
            time.sleep(0.05)
        if self.negative:
            print('bthci: the guest has no key for the bond it made', flush=True)
            return
        if self.ltkgiven is None:
            print('bthci: the guest never answered the second key request', flush=True)
            return
        if self.ltkgiven != d['ltk']:
            print('bthci: the guest answered with a different key', flush=True)
            return
        print('bthci: the guest came back on the bond, without pairing again',
              flush=True)
        self.event(0x08, bytes([0]) + struct.pack('<H', self.inhandle) + bytes([1]))

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
        handle = h & 0x0fff
        pb = (h >> 12) & 3
        dlen = struct.unpack('<H', pkt[2:4])[0]
        d = pkt[4:4+dlen]
        if loopback:
            self.acldata_relay(handle, pb, d)
            return
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
            if pairin:
                self.smp_initiator(payload)
            else:
                self.smp_in(payload)
        elif cid == 5:
            log('signalling %s' % payload.hex())
            if len(payload) >= 6 and payload[0] == 0x13:   # parameter response
                r = struct.unpack('<H', payload[4:6])[0]
                self.paramresults.append(r)
                log('the central said %s' % ('yes' if r == 0 else 'no'))
            else:
                self.coc_signal(payload)
        elif cid in self.coc:
            self.coc_kframe(self.coc[cid], payload)

    #
    # Reassemble on whichever link it came in on, and put the whole
    # frame out on the other.  Which handle is which matters: the two
    # links are the two ends of one wire and a frame sent back down the
    # link it arrived on would be this side talking to itself.
    #
    def acldata_relay(self, handle, pb, d):
        # one credit back per packet taken, on the link it came in on
        self.credits(1, handle)
        if handle == self.outhandle:
            if pb == 0x2:
                self.acl_in = d
            else:
                self.acl_in += d
            buf = self.acl_in
            out = self.inhandle
        elif handle == self.inhandle:
            if pb == 0x2:
                self.acl_in2 = d
            else:
                self.acl_in2 += d
            buf = self.acl_in2
            out = self.outhandle
        else:
            return
        if len(buf) < 4:
            return
        flen = struct.unpack('<H', buf[0:2])[0]
        if len(buf) < 4 + flen:
            return
        frame = buf[0:4+flen]
        if handle == self.outhandle:
            self.acl_in = b''
        else:
            self.acl_in2 = b''
        if handle == self.inhandle and self.badpending:
            # our own answer, not the client's: take it and say what
            # the server said rather than passing it on
            self.badpending = False
            cid = struct.unpack('<H', frame[2:4])[0]
            p = frame[4:]
            if cid == 4 and len(p) >= 5 and p[0] == 0x01:
                print('bthci: the read-only write was refused, error %#04x'
                      % p[4], flush=True)
            else:
                print('bthci: the read-only write got %s' % p[:8].hex(), flush=True)
            return
        if out is None:
            return
        self.relay(out, frame)

    # --------------------------------------- LE credit-based channels
    #
    # The peripheral half of an LE connection-oriented channel: a PSM
    # it answers on, an echo service behind it, and the credit
    # accounting both ways.  Segmentation here uses a different MPS
    # from the guest's on purpose, so neither side's arithmetic can
    # pass by agreeing with the other's.
    #
    def coc_signal(self, p):
        if len(p) < 4:
            return
        code, ident = p[0], p[1]
        dlen = struct.unpack('<H', p[2:4])[0]
        body = p[4:4+dlen]
        if code == 0x14:                    # LE Credit Based Connection Request
            if len(body) < 10:
                return
            psm, scid, mtu, mps, credits = struct.unpack('<HHHHH', body[0:10])
            log('connection request psm %#06x scid %#06x mtu %d mps %d credits %d'
                % (psm, scid, mtu, mps, credits))
            if psm != COCPSM:
                self.acl(5, bytes([0x15, ident]) + struct.pack('<H', 10)
                         + struct.pack('<HHHHH', 0, 0, 0, 0, 0x0002))
                log('refused: PSM not supported')
                return
            dcid = 0x0040 + len(self.coc)
            ch = {'dcid': dcid, 'scid': scid, 'mtu': COCMTU, 'mps': COCMPS,
                  'dmtu': mtu, 'dmps': mps, 'tx': credits, 'rx': 0,
                  'sdu': None, 'have': 0, 'wake': threading.Event()}
            # grant one credit at a time when asked to be stingy, and
            # otherwise enough for a whole SDU of the guest's
            ch['rx'] = 1 if coc_stingy else (COCMTU + 2 + COCMPS - 1) // COCMPS
            self.coc[dcid] = ch
            self.acl(5, bytes([0x15, ident]) + struct.pack('<H', 10)
                     + struct.pack('<HHHHH', dcid, ch['mtu'], ch['mps'], ch['rx'], 0))
            log('accepted on cid %#06x, %d credits granted' % (dcid, ch['rx']))
        elif code == 0x16:                  # LE Flow Control Credit
            if len(body) < 4:
                return
            cid, n = struct.unpack('<HH', body[0:4])
            for ch in self.coc.values():
                if ch['scid'] == cid:
                    ch['tx'] += n
                    log('the guest granted %d credits, now %d' % (n, ch['tx']))
                    ch['wake'].set()
        elif code == 0x06:                  # Disconnection Request
            if len(body) < 4:
                return
            dcid, scid = struct.unpack('<HH', body[0:4])
            log('the guest closed cid %#06x' % dcid)
            ch = self.coc.pop(dcid, None)
            if ch is not None:
                ch['wake'].set()
            self.acl(5, bytes([0x07, ident]) + struct.pack('<H', 4)
                     + struct.pack('<HH', dcid, scid))

    def coc_kframe(self, ch, p):
        if len(p) > ch['mps']:
            # the peer's own check, so a guest that forgot the two byte
            # SDU length counts toward the MPS is caught here and not
            # only by the arithmetic agreeing with itself
            print('bthci: coc oversize segment %d bytes, mps %d'
                  % (len(p), ch['mps']), flush=True)
            return
        if ch['rx'] <= 0:
            log('the guest sent a segment with no credit left')
            return
        ch['rx'] -= 1
        if ch['sdu'] is None:
            if len(p) < 2:
                return
            n = struct.unpack('<H', p[0:2])[0]
            ch['sdu'] = bytearray()
            ch['want'] = n
            p = p[2:]
        ch['sdu'] += p
        # a credit back for the segment, as soon as it is absorbed: a
        # different policy from the guest's, which waits for its reader
        self.coc_credit(ch, 1)
        if len(ch['sdu']) >= ch['want']:
            sdu = bytes(ch['sdu'])
            ch['sdu'] = None
            self.cocsdus.append(sdu)
            log('reassembled an SDU of %d bytes' % len(sdu))
            print('bthci: coc sdu %d bytes %s' % (len(sdu), sdu[:16].hex()), flush=True)
            threading.Thread(target=self.coc_echo, args=(ch, sdu), daemon=True).start()

    def coc_credit(self, ch, n):
        ch['rx'] += n
        self.cocsigid = (self.cocsigid + 1) & 0xff or 1
        self.acl(5, bytes([0x16, self.cocsigid]) + struct.pack('<H', 4)
                 + struct.pack('<HH', ch['scid'], n))

    def coc_echo(self, ch, sdu):
        # send it back whole, segmented at the guest's MPS and paying a
        # credit per segment
        if coc_bigsdu:
            self.coc_send_raw(ch, len(sdu), sdu, claim=ch['dmtu'] + 1)
            return
        if coc_overrun:
            #
            # spend every credit the guest granted, on one byte SDUs
            # so each costs exactly one, and then send one more.  It
            # has to be exactly this: a segment sent while credits
            # remain is a segment the guest is entitled to take, and a
            # test that sends one proves nothing about the credit
            # check.  The count comes from what the guest granted, not
            # from a number written here.
            #
            n = ch['tx']
            log('spending all %d credits, then sending one more' % n)
            for i in range(n):
                ch['tx'] -= 1
                self.acl(ch['scid'], struct.pack('<H', 1) + bytes([i & 0xff]))
            self.acl(ch['scid'], struct.pack('<H', 1) + b'\xff')
            return
        self.coc_send_raw(ch, len(sdu), sdu)

    def coc_send_raw(self, ch, n, sdu, claim=None):
        off = 0
        first = True
        while True:
            while ch['tx'] <= 0:
                ch['wake'].clear()
                if not ch['wake'].wait(10):
                    log('the guest never granted a credit')
                    return
                if ch['dcid'] not in self.coc:
                    return
            ch['tx'] -= 1
            hdr = struct.pack('<H', claim if (first and claim is not None) else n) if first else b''
            take = min(len(sdu) - off, ch['dmps'] - len(hdr))
            self.acl(ch['scid'], hdr + sdu[off:off+take])
            off += take
            first = False
            if off >= len(sdu):
                break

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
            if typ == 0x2802:                             # Include
                out = b''
                for h, istart, iend, u in INCLUDES:
                    if start <= h <= end:
                        out += struct.pack('<HHHH', h, istart, iend, u)
                if not out:
                    return self.att_err(op, start, 0x0a)
                return self.acl(4, bytes([0x09, 8]) + out)
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
                elif hid and h in (0x0085, 0x0088):
                    self.hid_maybe_start()
                elif hidreport and h in (0x0085, 0x0089):
                    self.hidr_maybe_start()
                return
            if h in VALUES:
                VALUES[h] = v
                if hid and h == 0x0082:
                    print('bthci: the host selected %s protocol'
                          % ('boot' if v == bytes([0]) else 'report'), flush=True)
                return self.acl(4, bytes([0x13]))
            self.att_err(op, h, 0x03)
        elif op == 0x52:                                  # Write Command
            h = struct.unpack('<H', p[1:3])[0]
            v = p[3:]
            if h in VALUES:
                VALUES[h] = v
                if hid and h == 0x0082:
                    print('bthci: the host selected %s protocol'
                          % ('boot' if v == bytes([0]) else 'report'), flush=True)
            # a command gets no answer, not even an error
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
        # the third is exactly the boundary: timeout * 4 == (1 +
        # latency) * max, which the specification refuses.  A
        # peripheral minding its battery asks for precisely this.
        for mn, mx, lat, to in ((0x0018, 0x0028, 4, 0x0100),
                                (0x0018, 0x0028, 400, 0x000a),
                                (0x0028, 0x0028, 0, 10)):
            self.sigid = getattr(self, 'sigid', 0) + 1
            body = struct.pack('<HHHH', mn, mx, lat, to)
            self.acl(5, bytes([0x12, self.sigid, len(body), 0]) + body)
            log('asked for %d-%d latency %d timeout %d' % (mn, mx, lat, to))
            time.sleep(3)

    #
    # The central half: open a link to the guest and then close it.
    # The handle is a different one from the outgoing side's, so a
    # phase that has both cannot confuse them.
    #
    def connect_in(self):
        time.sleep(2)
        if not self.advertising:
            return
        addr = bytes.fromhex('efbeadde0000')     # 0000 DEAD BEEF written down
        self.inhandle = 0x0041
        if not loopback:
            self.handle = self.inhandle
            self.peer = (0, addr)
        rep = struct.pack('<BHBB', 0x00, self.inhandle, 0x01, 0x00) + addr \
              + struct.pack('<HHHB', 0x0028, 0, 0x002a, 0)
        self.event(0x3e, bytes([0x01]) + rep)
        print('bthci: connected to the guest, handle %#06x' % self.inhandle, flush=True)
        if pairin:
            time.sleep(1)
            self.pair_out(addr)
            return
        if loopback:
            if badwrite:
                time.sleep(1)
                # handle 1 is the first service declaration: readable,
                # and never writable by a peer
                req = bytes([0x12]) + struct.pack('<H', 0x0001) + b'x'
                frame = struct.pack('<HH', len(req), 4) + req
                self.badpending = True
                print('bthci: writing a read-only attribute, on purpose', flush=True)
                self.relay(self.inhandle, frame)
            return          # the phase closes it when it is done
        time.sleep(6)
        print('bthci: closing the link to the guest', flush=True)
        self.event(0x05, bytes([0x00]) + struct.pack('<H', self.inhandle) + bytes([0x13]))
        self.handle = None
        self.inhandle = None

    #
    # A wire.  Whole L2CAP frames arriving on one link go out on the
    # other, refragmented to the ACL size the guest was told.  Frames
    # rather than packets, because the two directions may fragment
    # differently and half a frame delivered on the other link would be
    # a frame the far side never completes.
    #
    def relay(self, out, frame):
        n = 27
        off = 0
        first = True
        while off < len(frame) or first:
            take = min(len(frame) - off, n)
            pb = 0x2 if first else 0x1
            pkt = struct.pack('<HH', (out & 0x0fff) | (pb << 12), take) \
                  + frame[off:off+take]
            self.send(bytes([2]) + pkt)
            off += take
            first = False

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

    #
    # A keyboard and a mouse.  Nothing is sent until the host has both
    # selected the boot protocol and subscribed: a device that reported
    # before either would be reporting in a format the host has not
    # agreed to, and to nobody.
    #
    def hid_maybe_start(self):
        if VALUES.get(0x0082) != bytes([0]):
            return
        if not (CCCD.get(0x0085, 0) & 1) or not (CCCD.get(0x0088, 0) & 1):
            return
        if getattr(self, 'hidgoing', False):
            return
        self.hidgoing = True
        threading.Thread(target=self.hid_type, daemon=True).start()

    def hid_type(self):
        time.sleep(0.5)
        # usage codes for b, t, h: a word the phase can look for, and
        # each one pressed and then released, because a boot report is
        # the state of the keyboard and not an event
        for k in (0x05, 0x17, 0x0b):
            self.acl(4, bytes([0x1b]) + struct.pack('<H', 0x0084)
                     + bytes([0, 0, k, 0, 0, 0, 0, 0]))
            time.sleep(0.2)
            self.acl(4, bytes([0x1b]) + struct.pack('<H', 0x0084) + bytes(8))
            time.sleep(0.2)
        #
        # A shifted one, to show the modifier byte is read: left shift
        # with the usage code for a gives A.  Sent three times, because
        # a real keyboard reports the state of its keys at its own rate
        # and a key that is held appears in every report until it is
        # let go.  A host that read a report as an event rather than as
        # a state would type it three times.
        #
        for _ in range(3):
            self.acl(4, bytes([0x1b]) + struct.pack('<H', 0x0084)
                     + bytes([0x02, 0, 0x04, 0, 0, 0, 0, 0]))
            time.sleep(0.2)
        self.acl(4, bytes([0x1b]) + struct.pack('<H', 0x0084) + bytes(8))
        time.sleep(0.3)
        # and the mouse: right and down, with the left button held.
        # Two reports, because /dev/pointer wants a position and the
        # device reports movement, so the second only lands where it
        # should if the first was added to.
        for dx, dy, b in ((5, 7, 0x01), (3, 2, 0x00)):
            self.acl(4, bytes([0x1b]) + struct.pack('<H', 0x0087)
                     + bytes([b, dx & 0xff, dy & 0xff]))
            time.sleep(0.2)
        print('bthci: the keyboard and the mouse have reported', flush=True)

    #
    # the same keystrokes and the same movement, in the report
    # protocol.  Nothing waits for a protocol mode here: there is no
    # Protocol Mode characteristic, so subscribing to both reports is
    # the whole of what the host has to do before a device starts
    # sending.
    #
    def hidr_maybe_start(self):
        if not (CCCD.get(0x0085, 0) & 1) or not (CCCD.get(0x0089, 0) & 1):
            return
        if getattr(self, 'hidrgoing', False):
            return
        self.hidrgoing = True
        threading.Thread(target=self.hidr_type, daemon=True).start()

    def hidr_type(self):
        time.sleep(0.5)
        kbd = 0x0088
        mouse = 0x0084
        for k in (0x05, 0x17, 0x0b):          # b, t, h
            self.acl(4, bytes([0x1b]) + struct.pack('<H', kbd)
                     + bytes([0, 0, k, 0, 0, 0, 0, 0]))
            time.sleep(0.2)
            self.acl(4, bytes([0x1b]) + struct.pack('<H', kbd) + bytes(8))
            time.sleep(0.2)
        # left shift with a, held for three reports, as in the boot phase
        for _ in range(3):
            self.acl(4, bytes([0x1b]) + struct.pack('<H', kbd)
                     + bytes([0x02, 0, 0x04, 0, 0, 0, 0, 0]))
            time.sleep(0.2)
        self.acl(4, bytes([0x1b]) + struct.pack('<H', kbd) + bytes(8))
        time.sleep(0.3)
        # and the mouse, four bytes: buttons, x, y, wheel
        for dx, dy, b in ((5, 7, 0x01), (3, 2, 0x00)):
            self.acl(4, bytes([0x1b]) + struct.pack('<H', mouse)
                     + bytes([b, dx & 0xff, dy & 0xff, 0]))
            time.sleep(0.2)
        print('bthci: the keyboard and the mouse have reported', flush=True)

    #
    # An inquiry runs for a while and then says it is over.  The
    # results come first and spread out, because a device answers only
    # in the windows its own inquiry scan opens and they do not all
    # answer at once; the completion is what ends it.
    #
    def inquire(self):
        for addr, cls, psrm, clk, name, eir in CLASSICDEVS:
            time.sleep(0.4)
            if not self.inquiring:
                return
            if eir and not noeir:
                # Extended Inquiry Result: one device, and 240 bytes
                # of advertising-shaped data with the name in it
                n = name.encode()
                data = bytes([len(n) + 1, 0x09]) + n
                data += bytes(240 - len(data))
                self.event(0x2f, bytes([1]) + addr + bytes([psrm, 0])
                           + struct.pack('<I', cls)[:3]
                           + struct.pack('<H', clk) + bytes([0xc0]) + data)
            else:
                # Inquiry Result with RSSI: no name, so the host has
                # to ask for it.  One reserved byte after the page
                # scan repetition mode here and two in the plain
                # Inquiry Result, so the class, the clock and the
                # RSSI do not sit where they do there -- but a record
                # is fourteen bytes either way.
                self.event(0x22, bytes([1]) + addr + bytes([psrm, 0])
                           + struct.pack('<I', cls)[:3]
                           + struct.pack('<H', clk) + bytes([0xc0]))
        time.sleep(0.6)
        if self.inquiring:
            self.inquiring = False
            self.event(0x01, bytes([0]))
            print('bthci: inquiry complete', flush=True)
        if brincoming:
            # the peer pages this side: class of device, link type ACL
            time.sleep(0.5)
            addr, cls, psrm, clk, name, eir = CLASSICDEVS[1]
            print('bthci: the peer pages', flush=True)
            self.event(0x04, addr + struct.pack('<I', cls)[:3] + bytes([1]))

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

    # ------------------------------------------------ H5 parser
    #
    # The mirror of the guest's: unframe, check the header, answer the
    # link protocol, acknowledge what is reliable, and hand the packet
    # to the same dispatch H4 uses.  Nothing above this knows which
    # transport is underneath.
    #
    def h5_in(self, data):
        for b in data:
            if b == SLIP_DELIM:
                if self.h5_inframe and self.h5_buf:
                    self.h5_frame(bytes(self.h5_buf))
                self.h5_buf = bytearray()
                self.h5_esc = False
                self.h5_inframe = True
                continue
            if not self.h5_inframe:
                continue
            if self.h5_esc:
                self.h5_esc = False
                if b == SLIP_ESC_DELIM:
                    b = SLIP_DELIM
                elif b == SLIP_ESC_ESC:
                    b = SLIP_ESC
                else:
                    print('bthci: bad escape %#04x' % b, flush=True)
                    self.h5_buf = bytearray()
                    self.h5_inframe = False
                    continue
            elif b == SLIP_ESC:
                self.h5_esc = True
                continue
            self.h5_buf.append(b)

    def h5_frame(self, p):
        if len(p) < 4:
            return
        if p[3] != 0xff - ((p[0] + p[1] + p[2]) & 0xff):
            print('bthci: h5 header checksum wrong', flush=True)
            return
        seq = p[0] & 7
        ack = (p[0] >> 3) & 7
        rel = (p[0] >> 7) & 1
        ptype = p[1] & 0x0f
        if self.h5_dupwatch is not None and ack == self.h5_dupwatch:
            print('bthci: the guest acknowledged a packet that was never sent',
                  flush=True)
            self.h5_dupwatch = None
        dlen = ((p[1] >> 4) & 0x0f) | (p[2] << 4)
        if len(p) < 4 + dlen:
            print('bthci: h5 short payload', flush=True)
            return
        body = p[4:4+dlen]
        log('h5 <- seq %d type %d len %d' % (seq, ptype, dlen))
        if ptype == 0x0f:
            return self.h5_link(body)
        if rel:
            if seq != self.h5_txack:
                # the guest sent it again because our ack was lost
                self.h5_ack()
                return
            self.h5_txack = (self.h5_txack + 1) & 7
            self.h5_ack()
        if ptype == 0x00:
            return
        if self.h5_state != 'active':
            return
        if ptype == 1:
            op = struct.unpack('<H', body[0:2])[0]
            self.command(op, body[3:3+body[2]])
        elif ptype == 2:
            self.acldata(body)

    def h5_ack(self):
        self.h5_acks += 1
        if h5_drop_ack and self.h5_acks == h5_drop_ack:
            print('bthci: swallowing acknowledgement %d' % self.h5_acks, flush=True)
            return
        self.h5_send(0x00, b'', reliable=False)

    def h5_link(self, p):
        if p[:2] == bytes([0x01, 0x7e]):            # sync request
            self.h5_send(0x0f, bytes([0x02, 0x7d]), reliable=False)
        elif p[:2] == bytes([0x03, 0xfc]):          # configuration request
            self.h5_send(0x0f, bytes([0x04, 0x7b]), reliable=False)
            if self.h5_state != 'active':
                self.h5_state = 'active'
                self.h5_txseq = 0
                self.h5_txack = 0
                print('bthci: the H5 link is up', flush=True)

    # ------------------------------------------------ H4 parser
    def run(self):
        while not self.stop:
            d = self.c.recv(4096)
            if not d:
                print('bthci: the guest closed the connection', flush=True)
                return
            if h5:
                self.h5_in(d)
                continue
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
