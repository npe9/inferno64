#!/usr/bin/env python3
#
# Drive an stm32f407 board's console over its USB UART.
#
# The same termios-raw-and-a-read-loop as tools/tinysa/tinysa.py, for
# the same reason: the port is a tty and the tree gains no dependency.
#
# Two things about this console are not negotiable and both are
# recorded in os/inferno/stm32f407/NOTE.  A typed line longer than
# about fifty characters loses its tail, so every command sent here is
# checked against that and refused rather than truncated silently.  And
# the board can spawn one process for a redirection and no more, so a
# session that needs many writes to one file opens it once with
# "cat >file" and sends a line per write.
#
#	console.py cmd 'ls /dis'
#	console.py ctl /dev/radio0/ctl 'reg 0x28' 'txtest 4'
#
import os, sys, termios, select, time

PORT = "/dev/cu.usbserial-AQ02DK34"
MAXLINE = 50            # what the console carries; see NOTE


def open_port(path=PORT):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    a = termios.tcgetattr(fd)
    a[0] = a[1] = a[3] = 0
    a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    a[4] = a[5] = termios.B115200
    a[6][termios.VMIN] = 0
    a[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, a)
    return fd


def drain(fd, secs):
    buf = b""
    end = time.time() + secs
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                d = os.read(fd, 65536)
            except BlockingIOError:
                continue
            if d:
                buf += d
    return buf.decode("utf-8", "replace")


def send(fd, line, wait=2.0):
    if len(line) > MAXLINE:
        raise SystemExit("console: %d characters is past the %d this "
                         "console carries: %r" % (len(line), MAXLINE, line))
    os.write(fd, (line + "\n").encode())
    return drain(fd, wait)


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: console.py cmd <line>... | ctl <file> <line>...")
    fd = open_port()
    print(drain(fd, 0.5), end="")
    os.write(fd, b"\n")
    print(drain(fd, 1.0), end="")
    if sys.argv[1] == "ctl":
        print(send(fd, "cat >" + sys.argv[2], 2.0), end="")
        for line in sys.argv[3:]:
            print(send(fd, line, 3.0), end="")
        os.write(fd, b"\004")           # end the cat
        print(drain(fd, 2.0), end="")
    else:
        for line in sys.argv[2:]:
            print(send(fd, line, 3.0), end="")
    os.close(fd)


if __name__ == "__main__":
    main()
