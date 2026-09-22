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

# Seconds between characters.
#
# This console echoes from the interrupt handler and the echo goes out
# through a spin that waits for the transmit register, about 87us a
# byte at 115200.  A character arriving every 87us -- which is what
# 115200 means -- therefore lands while the last one is still being
# echoed, and the one-byte receive register overruns.  A host writing a
# line in one go does exactly that: "cat >/dev/radio0/ctl" arrived as
# "cat >/dev/radio0/l", losing two characters from the middle of
# twenty, and the shell dutifully opened the wrong file.
#
# So type like a person.  Five milliseconds a character is fifty times
# the echo and costs a tenth of a second for a twenty-character line,
# which is nothing next to rerunning an experiment that quietly ran the
# wrong command.  This is the same fault as the lost characters
# doc/radio-evidence-howto.ms records; the difference here is that the
# host controls the rate and can simply not do it.
CHARDELAY = 0.005


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


def send(fd, line, wait=2.0, check=True):
    """Type a line and give back what the board said.

    The echo is checked against what was sent.  This console drops
    characters when typed at faster than it echoes, and a dropped
    character does not produce an error -- it produces a different
    command.  "cat >/dev/radio0/ctl" arrived here as
    "cat >/dev/radio0/l" and the shell opened that instead, wedged
    itself, and cost a boot.  A line that did not arrive whole is
    worth stopping for.
    """
    if len(line) > MAXLINE:
        raise SystemExit("console: %d characters is past the %d this "
                         "console carries: %r" % (len(line), MAXLINE, line))
    for c in (line + "\n").encode():
        os.write(fd, bytes([c]))
        time.sleep(CHARDELAY)
    out = drain(fd, wait)
    if check and line and line not in out:
        raise SystemExit("console: sent %r, board echoed %r -- characters "
                         "were lost; nothing further sent" % (line, out))
    return out


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
            # "!sleep N" waits without typing, so one ctl session can
            # hold a state while something else measures it.  This
            # board spawns one process per boot for a redirection, so
            # a session that has to be left open is the only way to
            # change a setting, look at it, and change it again
            # without a reset between each.
            if line.startswith("!sleep "):
                time.sleep(float(line.split()[1]))
                continue
            print(send(fd, line, 3.0), end="")
        os.write(fd, b"\004")           # end the cat
        time.sleep(CHARDELAY)
        print(drain(fd, 2.0), end="")
    else:
        for line in sys.argv[2:]:
            print(send(fd, line, 3.0), end="")
    os.close(fd)


if __name__ == "__main__":
    main()
