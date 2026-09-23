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


def main():
    """board.py <command>...  -- type each at the console and print the reply."""
    import sys
    c = Console(os.environ.get("SCRATCH", "/tmp"))
    for line in sys.argv[1:]:
        out = c.run(line)
        print(out if out else "(no reply to %r)" % line)


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
    seq = 0

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

    def run(self, line, wait=20.0):
        """Type a line and give back only what the board said after it.

        Every read of this console is a screen(1) hardcopy, which
        writes out the window as it stands.  There is nothing in that
        to say whether the text is from this command or the last one,
        and twice in one session that cost a wrong answer: a board
        that had finished a sweep and was sitting at its prompt was
        read as hung, and a sweep that never ran was reported with the
        previous sweep's numbers, identical to the decibel.

        So a marker goes first.  The board echoes it, this waits until
        it appears, and only the text after it is returned.  A capture
        that has not moved on is then an empty result rather than a
        plausible one.
        """
        Console.seq += 1
        mark = "M%d" % Console.seq
        self.send("echo " + mark)
        end = time.time() + 8.0
        while time.time() < end:
            time.sleep(0.5)
            t = self.text()
            # the echo of the command, then the board's own reply
            if t.count(mark) >= 2:
                break
        else:
            return None
        self.send(line)
        end = time.time() + wait
        last = ""
        while time.time() < end:
            time.sleep(1.0)
            t = self.text()
            i = t.rfind(mark)
            after = t[i:] if i >= 0 else ""
            if after == last and line in after:
                return after
            last = after
        return last or None

    def ctl(self, lines, wait=60.0, file="/dev/radio0/ctl"):
        """Run ctl commands with the file held open, and read back fresh.

        Two constraints meet here.  The board's console loses the tail
        of a line longer than about fifty characters, so a ctl command
        cannot be sent as "echo <verb and its arguments> >file" once
        the verb has more than a couple of arguments; it has to go
        into a held-open cat, where the verb alone is short.  And the
        reply has to be told from whatever the window held before,
        which needs a marker -- but a marker typed inside the cat
        would be written to the ctl file rather than echoed.

        So the marker goes first, at the prompt, and the cat is opened
        after it.  Everything the window gains from that point is this
        call's.
        """
        Console.seq += 1
        # Unique across runs as well as within one: the window keeps
        # its scrollback, so a marker that restarts at M1 every time
        # the tool runs has several matches in it.
        mark = "M%d.%d" % (int(time.time()) % 100000, Console.seq)
        self.send("echo " + mark)
        end = time.time() + 8.0
        while time.time() < end:
            time.sleep(0.5)
            if self.text().count(mark) >= 2:
                break
        else:
            return None
        self.send("cat >" + file)
        time.sleep(1.5)
        for l in lines:
            self.send(l)
            time.sleep(1.0)
        # Sliced at the marker every time, not at a byte offset taken
        # once: the window scrolls as output arrives, so an offset
        # captured before the command names a different place after
        # it, and this returned nothing while the board was plainly
        # printing.
        def since():
            t = self.text()
            i = t.rfind(mark)
            return t[i:] if i >= 0 else ""

        # Wait for output to start before waiting for it to stop.
        # A sweep prints nothing at all until it has finished, so "two
        # reads the same" is true from the first moment and a loop
        # that breaks on it gives up before the board has begun.
        end = time.time() + wait
        last = since()
        started = False
        while time.time() < end:
            time.sleep(2.0)
            t = since()
            if t != last:
                started = True
                last = t
                continue
            if started:
                break
        self.eof()
        time.sleep(1.0)
        return since()

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


if __name__ == "__main__":
    main()
