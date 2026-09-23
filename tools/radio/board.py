#!/usr/bin/env python3
#
# Talk to the stm32f407's console, whether or not a screen(1) session
# is sitting on the port.
#
# The port is a tty and only one thing may have it.  During a bench
# session there is usually a screen attached so a person can watch,
# and a tool that opens /dev/cu.usbserial-... itself either fails or
# steals it.  screen has the two operations needed to share: "stuff"
# to type and "hardcopy" to read the window back, so this drives that
# when a session exists and the port directly when one does not.
#
# Typing goes a character at a time whichever way it goes.  This
# console echoes from its interrupt handler through a spin that waits
# on the transmit register, so a host writing a line in one go
# overruns the one-byte receive register and the board runs a
# different command than the one that was sent; see
# tools/f407/console.py, which found that the expensive way.
#
import os, re, subprocess, sys, time

CHARDELAY = 0.006


PORT = "/dev/cu.usbserial-AQ02DK34"


def session(port=PORT):
    """The screen session holding the console, or None.

    Found by asking which process has the tty open and matching that
    against the session names, rather than by taking the first one
    screen(1) lists.  A bench has more than one screen going -- one on
    the board, one on whatever else -- and the first is not the right
    one, which this learned by typing a board's commands into somebody
    else's window.
    """
    try:
        out = subprocess.run(["screen", "-ls"], capture_output=True,
                             text=True).stdout
    except FileNotFoundError:
        return None
    names = re.findall(r"^\s*(\d+)\.(\S+)", out, re.M)
    if not names:
        return None
    try:
        held = subprocess.run(["lsof", "-t", port], capture_output=True,
                              text=True).stdout.split()
    except FileNotFoundError:
        held = []
    for pid, rest in names:
        if pid in held:
            return "%s.%s" % (pid, rest)
    return None


class Console:
    def __init__(self, scratch):
        self.sess = session()
        self.scratch = scratch
        self.fd = None
        if self.sess is None:
            sys.path.insert(0, os.path.join(
                os.path.dirname(os.path.abspath(__file__)), "..", "f407"))
            import console
            self.console = console
            self.fd = console.open_port()

    def send(self, line):
        if self.sess:
            for c in line:
                subprocess.run(["screen", "-S", self.sess, "-X", "stuff", c])
                time.sleep(CHARDELAY)
            subprocess.run(["screen", "-S", self.sess, "-X", "stuff", "\n"])
        else:
            self.console.send(self.fd, line, wait=0.5, check=False)

    def eof(self):
        if self.sess:
            subprocess.run(["screen", "-S", self.sess, "-X", "stuff", "\004"])
        else:
            os.write(self.fd, b"\004")

    def text(self):
        """Everything the console has shown, most recent last."""
        if self.sess:
            out = os.path.join(self.scratch, "console.txt")
            subprocess.run(["screen", "-S", self.sess, "-X", "hardcopy",
                            "-h", out])
            time.sleep(0.4)
            with open(out, "rb") as f:
                return f.read().decode("utf-8", "replace")
        return self.console.drain(self.fd, 0.5)

    def ask(self, line, match, wait=6.0):
        """Send a line and give back the last reply match() accepts.

        match() has to be narrow enough to tell a reply from the echo
        of the command that asked for it.  This console echoes what is
        typed at it, so "the last line beginning probe" is the command
        every time, and a tool that takes it reports the question as
        the answer -- which this did, printing "873291759 300" as what
        the radio made of 873.2918 MHz.
        """
        def hits():
            return [l.rstrip() for l in self.text().split("\n") if match(l)]
        before = len(hits())
        self.send(line)
        end = time.time() + wait
        while time.time() < end:
            time.sleep(0.8)
            got = hits()
            if len(got) > before:
                return got[-1]
        return None
