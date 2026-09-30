#!/usr/bin/env python3
#
# Two REAL boards, one packet over the air.  Plan item 3, at last.
#
# twoboards.sh does this under qemu, and says plainly what that does and
# does not prove: it exercises #W's whole packet path, ending with a
# payload out of /dev/radio0/data on a different machine, and it does
# not exercise the radio -- deviation, bandwidth, symbol timing, sync
# detection against a real signal.  So a pass there with silence on the
# air localises the fault to the RF, and that is exactly where the bench
# has been stuck: every negative was taken with nothing known to be
# transmitting, and a receiver that hears nothing when nothing is sent
# cannot be told from a deaf one.
#
# This is the positive control on silicon.  One board transmits a known
# payload, the other listens for it, and the run is only believed if the
# control passes too: the same listen with the transmitter idle must
# come back empty.  Without that half, one spurious packet or one stale
# buffer reads as success.
#
# WHY THIS NEEDED board.py TO CHANGE.  It had one hardcoded port and
# found its console by asking which screen(1) session held that tty, so
# it could only ever address one board.  INFERNO_BOARD_PORT now aims it
# at a named port and suppresses the screen lookup, which is what makes
# two Consoles in one process possible.  Two of them also must not both
# find the bench's screen, which is the other reason that variable
# turns it off.
#
# Each board is addressed by its own port:
#
#	twosilicon.py --tx /dev/cu.usbserial-AQ02DK34 \
#	              --rx /dev/cu.usbserial-224420
#
# Transmitting is inside 902-928MHz at the part's default power, which
# is what Part 15 is written for, and only for as long as the sends
# take.  See tools/radio/txpin.py for the standing argument about that.
#
import os, re, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


def console(port, scratch):
    """A board.py Console aimed at one named port.

    board.py reads INFERNO_BOARD_PORT at import time, so the variable is
    set, the module imported fresh, and the class taken out -- rather
    than imported once and re-pointed, which would silently give both
    boards the same port.
    """
    import importlib
    os.environ["INFERNO_BOARD_PORT"] = port
    import board
    importlib.reload(board)
    c = board.Console(scratch)
    if c.fd is None:
        sys.exit("twosilicon: no console on %s" % port)
    return board, c


def setup(st, hz, tag):
    """The same radio configuration on both, so neither can be blamed for
    a mismatch.  Every value is one this bench has already checked: the
    rate and deviation twoboards.sh uses, and a bandwidth of 50000
    because bw above that gave nonsense on silicon."""
    for line in ("freq %d" % hz, "rate 9600", "deviation 20000",
                 "bw 50000", "txmode var", "sync 0xaaaa 16",
                 "csthr -104"):
        r = st.send(line, wait=30)
        if r is None:
            print("  %s: no reply to %s" % (tag, line))
            return False
    return True


def main():
    a = sys.argv[1:]
    def opt(name, default=None):
        if name in a:
            return a[a.index(name) + 1]
        return default
    tx_port = opt("--tx")
    rx_port = opt("--rx")
    hz = int(opt("--hz", "915000000"))
    msg = opt("--msg", "silicon-carried-this")
    if not tx_port or not rx_port:
        sys.exit(__doc__ or "usage: twosilicon.py --tx <port> --rx <port>")
    if not 902000000 <= hz <= 928000000:
        sys.exit("twosilicon: %d is outside 902-928MHz; this transmits "
                 "only inside the unlicensed band" % hz)
    if tx_port == rx_port:
        sys.exit("twosilicon: --tx and --rx are the same port")

    scratch = os.environ.get("CLAUDE_JOB_DIR", "/tmp") + "/tmp"
    os.makedirs(scratch, exist_ok=True)

    print("tx %s\nrx %s\n%.3f MHz, payload %r\n" %
          (tx_port, rx_port, hz / 1e6, msg))

    _, ctx = console(tx_port, scratch)
    _, crx = console(rx_port, scratch)
    for c, tag in ((ctx, "tx"), (crx, "rx")):
        c.run("bind -a '#W' /dev", wait=20)
        if not c.alive():
            sys.exit("twosilicon: %s board is not running commands" % tag)
    print("  both boards answer")

    stx = ctx.lilstream()
    srx = crx.lilstream()
    if not (stx.ok and srx.ok):
        sys.exit("twosilicon: could not open a ctl file on both")
    if not setup(stx, hz, "tx") or not setup(srx, hz, "rx"):
        sys.exit("twosilicon: configuration did not take")
    print("  both configured")

    bad = 0
    try:
        # THE CONTROL FIRST, and first on purpose: a listen with nothing
        # transmitting.  Run afterwards it is easy to excuse, and run
        # first it decides whether the positive means anything.
        before = srx.stmt('print(slurp("/dev/radio0/stats"))', wait=30) or ""
        m = re.search(r"recv (\d+)", before)
        recv0 = int(m.group(1)) if m else -1
        print("  rx recv counter before: %d" % recv0)

        srx.send("rx", wait=30)
        time.sleep(8)
        quiet = srx.stmt('print(slurp("/dev/radio0/stats"))', wait=30) or ""
        m = re.search(r"recv (\d+)", quiet)
        recvq = int(m.group(1)) if m else -1
        if recvq != recv0:
            print("  FAILED control: recv went %d -> %d with nothing sent"
                  % (recv0, recvq))
            bad += 1
        else:
            print("  ok control: 8s listening with nothing sent, recv still %d"
                  % recvq)

        # Now the packet.  Three, because one lost to timing proves
        # nothing and three all lost is a different claim from one.
        #
        # The payload goes to .../data and the configuration went to
        # .../ctl, so two files are open on the transmitting board at
        # once, in two variables, in one lil session.  Inside a shell's
        # "cat >file" that is not expressible at all: the cat owns the
        # console and every line typed is data for the one file it
        # holds.  This is the concrete reason lil exists.
        stx.stmt('data := open("/dev/radio0/data", "w")', wait=25)
        for i in range(3):
            r = stx.stmt('print("sent ", write(data, "%s"))' % msg, wait=30)
            if r is None or "sent " not in r:
                print("  FAILED send %d: %r" % (i, r))
                bad += 1
            time.sleep(2)
        after = srx.stmt('print(slurp("/dev/radio0/stats"))', wait=30) or ""
        m = re.search(r"recv (\d+)", after)
        recva = int(m.group(1)) if m else -1
        crc = re.search(r"crcerr (\d+)", after)
        print("  rx recv counter after three sends: %d (crcerr %s)"
              % (recva, crc.group(1) if crc else "?"))
        if recva > recvq:
            print("  ok RECEIVED %d packet(s) over the air" % (recva - recvq))
        else:
            print("  FAILED nothing received")
            bad += 1
    finally:
        try:
            stx.stmt("close(data)", wait=15)
        except Exception:
            pass
        for s in (stx, srx):
            try:
                s.close()
            except Exception:
                pass
    print()
    print("TWOSILICON-OK" if bad == 0 else "TWOSILICON-FAILED %d" % bad)
    return bad


if __name__ == "__main__":
    sys.exit(main())
