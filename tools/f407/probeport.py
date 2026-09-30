#!/usr/bin/env python3
#
# Is anything alive on this serial port?
#
# WHY THIS EXISTS, and it is worth reading before trusting a silence.
# The obvious way to answer the question is to open the port and listen,
# and that is useless: a board sitting at a shell prompt says nothing at
# all until it is spoken to.  A passive listen can only catch output
# that happens to arrive inside its window, which means a reset, which
# means somebody pressing a button at the right moment.
#
# I wrote that passive listener first and it reported zero bytes on
# seven ports across three resets of a freshly flashed board -- and I
# was about to conclude a wiring fault from it.  Then I pointed the same
# listener at a qemu "-serial pty" carrying a kernel that was certainly
# printing, and it reported zero bytes there too.  The instrument was
# broken, or rather it was measuring the wrong thing, and every negative
# it had produced meant nothing.
#
# So this pokes the port -- a bare newline, then a command whose output
# is a token -- and says whether the token came back.  It is validated
# the same way it was found wanting: run it against a qemu pty and it
# must see the token.
#
#	probeport.py [--secs 14] /dev/cu.something ...
#
# It WRITES to every port named, so name only ports whose far end you
# mean to type at.
#
import os, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import console

TOKEN = "PROBE-ALIVE"


def probe(port, secs):
    try:
        fd = console.open_port(port)
    except OSError as e:
        return None, "cannot open: %s" % e
    try:
        buf = console.drain(fd, 1.0)            # anything already waiting
        os.write(fd, b"\r\n")                   # a prompt, if there is a shell
        buf += console.drain(fd, secs / 3)
        os.write(fd, ("echo %s\r\n" % TOKEN).encode())
        buf += console.drain(fd, 2 * secs / 3)
    finally:
        os.close(fd)
    return buf, None


def main():
    a = sys.argv[1:]
    secs = 14.0
    if "--secs" in a:
        i = a.index("--secs")
        secs = float(a[i + 1])
        del a[i:i + 2]
    if not a:
        sys.exit("usage: probeport.py [--secs N] /dev/cu.something ...")
    alive = 0
    for port in a:
        buf, err = probe(port, secs)
        if err:
            print("%-38s %s" % (port, err))
            continue
        if TOKEN in buf:
            # Twice: the echo from the uart interrupt handler, which
            # comes back whether or not anything is running commands,
            # and the shell actually running the echo.  Once is a
            # console that echoes and a dead shell behind it.
            n = buf.count(TOKEN)
            if n >= 2:
                print("%-38s ALIVE, running commands (%d chars)"
                      % (port, len(buf)))
                alive += 1
            else:
                print("%-38s echoes but does not run commands (%d chars)"
                      % (port, len(buf)))
        elif buf.strip():
            print("%-38s says something, not the token (%d chars)"
                  % (port, len(buf)))
            print("    %s" % buf[-200:].replace("\n", " | "))
        else:
            print("%-38s silent (%d chars)" % (port, len(buf)))
    return 0 if alive else 1


if __name__ == "__main__":
    sys.exit(main())
