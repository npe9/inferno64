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
#	frequencies		the frequency of every point of a sweep
#	data 0			the levels, in dBm, one per line
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
PROMPT = b"ch> "


def open_port(path=PORT):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    a = termios.tcgetattr(fd)
    a[0] = a[1] = a[3] = 0              # iflag, oflag, lflag: raw
    a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    a[6][termios.VMIN] = 0
    a[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, a)
    return fd


def cmd(fd, s, timeout=10.0):
    os.write(fd, (s + "\r").encode())
    buf = b""
    end = time.time() + timeout
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.02)
        if not r:
            continue
        try:
            d = os.read(fd, 65536)
        except BlockingIOError:
            continue
        if d:
            buf += d
            end = time.time() + 0.6     # keep going while it talks
            if buf.endswith(PROMPT):
                break
    return buf.decode("utf-8", "replace")


def numbers(fd, what, tries=4, want=None):
    for _ in range(tries):
        d = cmd(fd, what, timeout=30).replace("\r", "")
        v = [x.strip() for x in d.splitlines() if FLOAT.match(x.strip())
             or x.strip().isdigit()]
        if want is None or len(v) == want:
            return v
        time.sleep(0.5)
    return None


def sweep(fd, start, stop, settle=1.4):
    cmd(fd, "sweep %d %d" % (start, stop))
    freqs = numbers(fd, "frequencies")
    if freqs is None:
        return None
    time.sleep(settle)
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
