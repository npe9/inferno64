#!/usr/bin/env python3
#
# Read a tinySA over its USB serial line, for checking this tree's own
# radio against something that is not this tree's own radio.
#
# Everything doc/radio-evidence.ms says about the weakest tier of
# evidence applies to a receiver reporting its own signal strength:
# os/inferno/radio/cc1120.c and the qemu model it was developed
# against were written by the same hand, and a board agreeing with
# itself is not a measurement.  A tinySA is an instrument somebody
# else built, with its own front end, its own calibration and its own
# reasons to be wrong, so where the two agree the agreement means
# something.
#
# It speaks a line protocol at a "ch> " prompt.  The commands used
# here:
#
#	version			what it is
#	rbw 100			resolution bandwidth in kHz
#	attenuate 0		input attenuator in dB
#	sweep <start> <stop>	the range, in Hz
#	resume / wait / pause	run one sweep and stop at the end of it
#	frequencies		the frequency of every point of a sweep
#	data 0			the levels, in dBm, one per line
#
# The resume/wait/pause around every trace is not decoration.  The
# tinySA stops sweeping while it serves commands on this line, and
# "data 0" hands back whatever is in the trace buffer -- which, if
# nothing has swept since, is the previous sweep, or the sweep of
# whatever span the thing was showing before the range was set.  Read
# that way it looks like a measurement and repeats perfectly: three
# consecutive reads here agreed to the last digit, r = 1.000 between
# each pair, 0 of 450 points differing.  Which is how it was caught.
# A real repeat of a real sweep of thermal noise agrees at r = 0.2 to
# 0.6 and no two points alike.
#
# No pyserial: the port is a tty, so termios raw and a read loop is
# the whole of it, and the tree gains no dependency.
#
# The line count of a trace is checked rather than trusted.  This is a
# serial line and a dropped byte turns a number into something that is
# not one -- seen, as "-:.000000e+01" in the middle of an otherwise
# good sweep.  A short or malformed read is retried rather than
# averaged in.
#
# Usage:
#	tinysa.py sweep 868000000 928000000	one sweep, as "hz dbm"
#	tinysa.py cmd 'version' 'rbw'		raw commands
#
import os, re, select, sys, termios, time

PORT = "/dev/cu.usbmodem4001"
FLOAT = re.compile(r"^-?\d+\.\d+e[+-]\d+$")
# The tinySA's own formatter, at exactly -100.0dBm.  ':' is the
# character after '9': a mantissa that rounded up to 10.0 was printed
# a digit at a time and carried off the end of the digit set, so
# -1.000000e+02 comes out as "-:.000000e+01".  Reproducible on every
# read of a trace that contains that level, and not a serial fault --
# which is worth knowing, because dropping the line silently leaves a
# hole in the sweep exactly where the quietest bins are.  Read as
# written it is -10.000000e+01, which is the value it meant.
CARRY = re.compile(r"^(-?):\.(\d+e[+-]\d+)$")
PROMPT = b"ch> "


def waitport(path=PORT, timeout=60.0, quiet=False):
    """Wait for the port to exist.

    This instrument leaves the USB bus on its own: twice in one
    session it enumerated, answered for a minute or two and vanished,
    through two different cables.  A tool that dies with a traceback
    when that happens loses whatever it was in the middle of
    measuring, and -- worse -- a tool started before the drop prints
    nothing and looks like an instrument hearing nothing.
    """
    end = time.time() + timeout
    said = False
    while time.time() < end:
        if os.path.exists(path):
            return True
        if not said and not quiet:
            sys.stderr.write("# waiting for %s\n" % path)
            said = True
        time.sleep(1.0)
    return False


def open_port(path=PORT, wait=60.0):
    if not os.path.exists(path) and not waitport(path, wait):
        raise SystemExit("tinysa: %s never appeared" % path)
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    a = termios.tcgetattr(fd)
    a[0] = a[1] = a[3] = 0              # iflag, oflag, lflag: raw
    a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    a[6][termios.VMIN] = 0
    a[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, a)
    return fd


def alive(fd, tries=3):
    """Is anything answering at the other end?

    The port existing is not the instrument working.  This one wedges:
    it keeps its USB device open, keeps /dev/cu.usbmodem4001 in place,
    and answers nothing at all -- seen after a session that changed
    its mode several times and left it in zero span.  A tool that does
    not check goes on to numbers(), which retries four times at a
    thirty second timeout, so the first symptom is two minutes of
    silence and no output, which reads as a long measurement rather
    than as a dead instrument.

    Recovering it needs its power cycled, and nothing this side of the
    cable can do that, so the only useful thing a tool can do is say
    so quickly.
    """
    for _ in range(tries):
        r = cmd(fd, "", timeout=1.5)
        # Ends with the prompt, and is short.  "contains the prompt"
        # is true of a megabyte of streamed trace, because the string
        # turns up in it somewhere -- which had this reporting a
        # wedged instrument as alive, after nine seconds of reading.
        # An empty command's reply is a few bytes.
        if len(r) < 4096 and r.rstrip().endswith(PROMPT.decode().rstrip()):
            return True
    return False


def needalive(fd):
    """Stop early, and say which way it is broken.

    Two states need the same remedy and look nothing alike.  Silent:
    the port is there, the device holds it, and nothing answers.
    Streaming: it never stops talking, so every reply is buried in the
    tail of an earlier trace and a tool reads one answer behind -- the
    symptom that put a level in dBm where a frequency in hertz should
    have been.  Seen here at about 1.7 megabytes a second, unmoved by
    a carriage return, ^C, ESC, "pause" or "abort".
    """
    if alive(fd):
        return
    if drain(fd, 0.3, 1.5) > 100000:
        raise SystemExit("tinysa: the instrument is streaming without "
                         "stopping and will not take a command -- it "
                         "needs its power cycled")
    raise SystemExit("tinysa: the port is there and nothing is "
                     "answering on it -- the instrument is wedged "
                     "and needs its power cycled")


def drain(fd, secs=0.4, cap=3.0):
    """Throw away anything already waiting, and say how much.

    Two deadlines.  The short one ends the drain once the port has
    gone quiet, and the long one ends it whatever happens: an
    instrument mid-trace sends for as long as it likes, and a drain
    that extends itself on every byte never returns.  That hung this
    tool outright the first time it was written.
    """
    n = 0
    hard = time.time() + cap
    end = time.time() + secs
    while time.time() < end and time.time() < hard:
        r, _, _ = select.select([fd], [], [], 0.05)
        if not r:
            continue
        try:
            d = os.read(fd, 65536)
        except BlockingIOError:
            continue
        if d:
            n += len(d)
            end = min(time.time() + 0.15, hard)
    return n


def cmd(fd, s, timeout=10.0):
    # Whatever is already in the port belongs to an earlier question.
    # A trace is four hundred odd lines and a read that gives up part
    # way through one leaves the rest to be delivered as the answer to
    # the next command -- after which every reply is one behind, and
    # "frequencies" comes back holding a level in dBm.  Seen: the
    # instrument answering "mode" and "sweep" with trace data, and a
    # tool parsing -9.984375e+01 as a frequency in hertz.
    drain(fd, 0.2)
    os.write(fd, (s + "\r").encode())
    buf = b""
    # A hard deadline as well as the rolling one.  "keep going while
    # it talks" never stops against an instrument that has got stuck
    # talking, and that hung every tool here outright -- the wedge
    # this was meant to report is the one it could not survive.  The
    # rolling deadline still ends a normal reply promptly.
    hard = time.time() + timeout + 5.0
    end = time.time() + timeout
    while time.time() < end and time.time() < hard:
        r, _, _ = select.select([fd], [], [], 0.02)
        if not r:
            continue
        try:
            d = os.read(fd, 65536)
        except BlockingIOError:
            continue
        if d:
            buf += d
            end = min(time.time() + 0.6, hard)
            if buf.endswith(PROMPT):
                break
    return buf.decode("utf-8", "replace")


def fixcarry(x):
    m = CARRY.match(x)
    return "%s10.%s" % (m.group(1), m.group(2)) if m else x


def numbers(fd, what, tries=4, want=None):
    for _ in range(tries):
        d = cmd(fd, what, timeout=30).replace("\r", "")
        v = [fixcarry(x.strip()) for x in d.splitlines()
             if FLOAT.match(x.strip()) or CARRY.match(x.strip())
             or x.strip().isdigit()]
        if want is None or len(v) == want:
            return v
        time.sleep(0.5)
    return None


def onesweep(fd):
    """Run exactly one sweep and stop at the end of it."""
    cmd(fd, "resume")
    cmd(fd, "wait", timeout=30)
    cmd(fd, "pause")


def sweep(fd, start, stop):
    # A tinySA ULTRA's low path stops at 800MHz and anything above it
    # needs ultra mode.  With it off the high end is not missing, it is
    # twenty-odd decibels down, which reads as a weak signal rather
    # than as an instrument that cannot see.  See the README.
    if stop > 800000000:
        cmd(fd, "ultra on")
    cmd(fd, "sweep %d %d" % (start, stop))
    onesweep(fd)
    freqs = numbers(fd, "frequencies")
    if freqs is None:
        return None
    onesweep(fd)
    levels = numbers(fd, "data 0", want=len(freqs))
    if levels is None:
        return None
    return list(zip((int(f) for f in freqs), (float(v) for v in levels)))


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__ or "usage: tinysa.py sweep <start> <stop> | cmd ...")
    fd = open_port()
    time.sleep(0.3)
    cmd(fd, "")                         # to a known prompt
    if sys.argv[1] == "sweep":
        s = sweep(fd, int(sys.argv[2]), int(sys.argv[3]))
        if s is None:
            sys.exit("tinysa: no readable sweep")
        for hz, dbm in s:
            print("%d %.2f" % (hz, dbm))
    else:
        for c in sys.argv[2:]:
            print(cmd(fd, c), end="")
    os.close(fd)


if __name__ == "__main__":
    main()
