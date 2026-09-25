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


# A console somewhere other than the usb serial adapter: a qemu pty, or a
# second adapter.  Setting it also stops session() looking for a screen,
# because the two must not disagree -- a test aimed at a qemu pty that
# found the bench's screen instead would type its commands at the
# physical board.
ALTPORT = os.environ.get("INFERNO_BOARD_PORT")


def session(port=PORT):
    """The screen session holding the console, or None.

    Found by asking which process has the tty open and matching that
    against the session names, rather than by taking the first one
    screen(1) lists.  A bench has more than one screen going -- one on
    the board, one on whatever else -- and the first is not the right
    one, which this learned by typing a board's commands into somebody
    else's window.
    """
    if ALTPORT:
        return None
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
        # How many markers in a row have gone unanswered.
        #
        # A wedged board still echoes what is typed at it -- the echo
        # comes from the uart interrupt handler and the shell is not
        # involved -- so "the characters come back" does not mean
        # anything is running them.  Without a count of that, a tool
        # loops: zwatch.py typed markers into a dead shell for several
        # minutes, each one echoed, none run, and reported nothing.
        # Three in a row is enough; the board answers the first one in
        # under a second when it is alive.
        self.dead = 0

        # What the port has said so far, for the no-screen path.
        #
        # text() has to mean the same thing both ways.  Through screen
        # it is a hardcopy, which is the whole window every time; on the
        # port it is a drain, which is only what has arrived since the
        # last one -- so run() and ctl(), which wait for their marker to
        # appear twice, never saw it twice and every call returned None
        # the moment nobody had a screen attached.
        self.buf = ""
        if self.sess is None:
            sys.path.insert(0, os.path.join(
                os.path.dirname(os.path.abspath(__file__)), "..", "f407"))
            import console
            self.console = console
            self.fd = console.open_port(ALTPORT or console.PORT)

    def send(self, line):
        if self.sess:
            for c in line:
                subprocess.run(["screen", "-S", self.sess, "-X", "stuff", c])
                time.sleep(CHARDELAY)
            subprocess.run(["screen", "-S", self.sess, "-X", "stuff", "\n"])
        else:
            # Keep what it read.  console.send() drains the port and
            # returns the echo, and throwing that away meant the bytes
            # were gone before text() could see them -- so the marker
            # never appeared twice and every run() and ctl() on the
            # no-screen path returned None while the board was answering
            # perfectly.
            self.buf += self.console.send(self.fd, line, wait=0.5,
                                          check=False)

    def eof(self):
        if self.sess:
            subprocess.run(["screen", "-S", self.sess, "-X", "stuff", "\004"])
        else:
            os.write(self.fd, b"\004")
            self.buf += self.console.drain(self.fd, 0.5)

    def text(self):
        """Everything the console has shown, most recent last."""
        if self.sess:
            out = os.path.join(self.scratch, "console.txt")
            subprocess.run(["screen", "-S", self.sess, "-X", "hardcopy",
                            "-h", out])
            time.sleep(0.4)
            with open(out, "rb") as f:
                return f.read().decode("utf-8", "replace")
        self.buf += self.console.drain(self.fd, 0.5)
        # Bounded, because a session can run for hours and a marker is
        # always near the end.
        if len(self.buf) > 65536:
            self.buf = self.buf[-32768:]
        return self.buf

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

        Two constraints meet here, and the first one is not what it
        was thought to be.  It was recorded as "the console loses the
        tail of a line longer than about fifty characters", which is
        why a ctl command goes into a held-open cat where the verb
        alone is short rather than being sent as "echo <verb and its
        arguments> >file".  Measured since, with a digit ruler at 30,
        40, 50, 60, 80 and 100 characters: nothing is lost in either
        direction, and a 105-character command line carrying a
        100-character argument was parsed and printed back whole.  The
        one observation behind the claim was a command that arrived as
        "/dev/radioecho", and whatever that was it was not a length
        limit.

        The held-open cat stays, because the second constraint is
        real: the reply has to be told from whatever the window held
        before, which needs a marker -- and a marker typed inside the
        cat would be written to the ctl file rather than echoed.

        So the marker goes first, at the prompt, and the cat is opened
        after it.  Everything the window gains from that point is this
        call's.
        """
        Console.seq += 1
        # Unique across runs as well as within one: the window keeps
        # its scrollback, so a marker that restarts at M1 every time
        # the tool runs has several matches in it.
        mark = "M%d.%d" % (int(time.time()) % 100000, Console.seq)
        if not self.mark(mark):
            # No echo, which has two causes and only one of them is
            # fixed by an end-of-file.
            #
            # A previous run may have left the board inside a held-open
            # cat, where the marker is written to the ctl file rather
            # than run; the console shows "cat: write error" or the cat
            # command with no prompt after it, and ending the cat is
            # right.  Or the board may simply not be answering, and
            # then an end-of-file is end of input to the shell, which
            # exits and leaves a console with nothing behind it.
            #
            # So this looks before it acts.  An earlier version fired
            # the end-of-file whenever the marker did not come back,
            # with a comment saying to do it second and never first --
            # and that was not enough, because a bug elsewhere made the
            # marker never come back at all, so it fired six times and
            # killed the shell.  Evidence, or nothing.
            if not self.incat():
                return None
            self.eof()
            time.sleep(1.0)
            Console.seq += 1
            mark = "M%d.%d" % (int(time.time()) % 100000, Console.seq)
            if not self.mark(mark):
                return None
        self.send("cat >" + file)
        time.sleep(1.5)
        for l in lines:
            self.send(l)
            time.sleep(1.0)
            # A rejected ctl line kills the cat, and then every line
            # after it is typed at a shell prompt instead of into the
            # file.  That is how "pktlen fixed" -- which is spelt
            # "txmode fixed" -- turned the six lines behind it into six
            # shell commands, one of which the shell reported as a
            # missing file and none of which reached the radio.  Worse
            # than useless: it looks like the radio refusing eight
            # things rather than one.
            t = self.text()
            i = t.rfind(mark)
            if i >= 0 and "write error" in t[i:]:
                return "ctl: the part refused %r; stopped there\n%s" % (
                    l, t[i:])
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
        quiet = 0
        while time.time() < end:
            time.sleep(2.0)
            t = since()
            if t != last:
                started = True
                quiet = 0
                last = t
                continue
            if started:
                break
            # Nothing has printed yet, and for most ctl verbs nothing
            # ever will: freq, rate, bw and the rest say nothing when
            # they work.  Waiting out the whole timeout for those made
            # every tuning step cost its full wait -- a packet-rate
            # comparison with a 40s dwell was taking 200s a
            # measurement, nearly all of it this loop waiting for
            # silence to become louder.  Ten seconds of quiet after
            # the command has been typed is a silent success.
            quiet += 1
            if quiet >= 5:
                break
        self.eof()
        time.sleep(1.0)
        return since()

    def incat(self):
        """Does the board look like it is inside a held-open cat?

        Two signs, either of which is enough: the part refusing a write,
        which only a cat into a ctl file produces, or a "cat >" as the
        last thing typed with no prompt printed after it.
        """
        t = self.text()
        if "write error" in t[-2000:]:
            return True
        i = t.rfind("cat >")
        return i >= 0 and ";" not in t[i:]

    def alive(self):
        """False once the board has stopped running what is typed at it.

        Checked before typing rather than after, so a caller in a loop
        stops at the first opportunity instead of at the last.
        """
        return self.dead < 3

    def stream(self, file="/dev/radio0/ctl"):
        """One held-open cat for many commands, instead of one each.

        ctl() opens a cat, writes, and ends it, which is right for a
        handful of lines and wrong for a loop.  Every call forks twice
        on a board with five processes and 163840 bytes, and nothing
        gives the heap back fast enough: a monitor running one probe
        every two seconds killed the shell in a few minutes, after
        which it typed markers into a dead console for several more.

        The echo is the marker here and no separate one is needed.
        This console prints back what is typed at it, so the reply to a
        command is whatever follows the last copy of that command in
        the window -- which survives the window scrolling, where a byte
        offset taken once does not.
        """
        return Stream(self, file)

    def lilstream(self, file="/dev/radio0/ctl", var="ctl"):
        """The same file held open by lil(1) instead of by a cat.

        See LilStream.  The difference that matters is that a marker can
        still be sent while the file is open, so a tool need not infer
        from a reply what it could simply ask.
        """
        return LilStream(self, file, var)

    def mark(self, mark, wait=8.0):
        """Type a marker and wait for the board to run it, not echo it.

        Two copies, not one: the first is the uart interrupt handler
        echoing what was typed, which happens whether or not anything is
        alive behind it, and the second is the shell running the echo.
        Counting one would call a wedged board healthy.
        """
        if not self.alive():
            return False
        self.send("echo " + mark)
        end = time.time() + wait
        while time.time() < end:
            time.sleep(0.5)
            if self.text().count(mark) >= 2:
                self.dead = 0
                return True
        self.dead += 1
        if self.dead == 3:
            sys.stderr.write(
                "board: three markers echoed and none run -- the shell is "
                "gone; reset the board (^R^R, or the button if the console "
                "has stopped echoing too)\n")
        return False

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


class Stream:
    """A ctl file held open across many commands.  See Console.stream()."""

    def __init__(self, c, file):
        self.c = c
        self.file = file
        Console.seq += 1
        mark = "S%d.%d" % (int(time.time()) % 100000, Console.seq)
        self.silent = 0
        self.ok = c.mark(mark)
        if self.ok:
            c.send("cat >" + file)
            time.sleep(1.5)

    def send(self, line, wait=25.0, expect=False):
        """Write one line and give back what the board said about it.

        expect says this command always prints something, so an empty
        reply from it means the shell is not running what is typed.
        That case cannot be seen any other way from inside a held-open
        cat: the echo comes from the uart interrupt handler and keeps
        coming back long after the shell is gone, and a marker cannot
        be used because inside a cat it would be written to the ctl
        file rather than run.

        It matters more than a stalled tool.  Nothing drains the
        console queue once the shell dies, so every character typed
        after that allocates a block nobody frees, and the board ends
        at "allocb: no memory 4788/40960" -- hard enough that ^R^R
        cannot reach it and the reset button is the only way back.
        The tool typing into a corpse is what exhausts it.
        """
        if not self.ok or not self.c.alive():
            return None
        if self.silent >= 3:
            self.ok = False
            sys.stderr.write("board: three commands in a row echoed but "
                             "not answered -- the shell is gone; stopping "
                             "before the console queue fills\n")
            return None
        self.c.send(line)
        end = time.time() + wait
        last = None
        seen = False
        while time.time() < end:
            time.sleep(1.0)
            t = self.c.text()
            i = t.rfind(line)
            if i < 0:
                continue            # the echo has not come back yet
            seen = True
            after = t[i + len(line):]
            # A write the part refused ends the cat, and everything
            # after it would go to the shell instead; stop rather than
            # type commands at a shell that is about to run them.
            if "write error" in after:
                self.ok = False
                return after
            # A command that is expected to print is not finished
            # just because it has printed nothing twice in a row.
            # gtrig waits up to five seconds for a carrier and says
            # nothing at all meanwhile, so a stability test that
            # accepts empty returned instantly -- and the caller typed
            # the next command into a board still running the last
            # one.  Nine of those queued hundreds of characters in a
            # console nobody was reading, one block per character, and
            # took the kernel to "allocb: no memory".  So when output
            # is expected, silence is not stability.
            if after == last and (after.strip() or not expect):
                self.silent = 0
                return after
            last = after
        # Two different silences, and telling them apart is the whole
        # job.  Most ctl verbs -- freq, rate, bw -- print nothing when
        # they work, so an empty reply is success and returning None
        # for it made a sweep give up on its first line.  An echo that
        # never comes back is the board not listening, and that is the
        # one worth counting.
        if not seen:
            self.silent += 1
            return None
        reply = last if last is not None else ""
        if expect and not reply.strip():
            self.silent += 1
        else:
            self.silent = 0
        return reply

    def close(self):
        if self.ok:
            self.c.eof()
            time.sleep(1.0)
            self.ok = False



class LilStream:
    """A ctl file held open by lil(1) rather than by a shell's cat.

    Stream above holds the file open with "cat >file", which stops the
    forking but costs the thing Stream's own docstring explains at
    length: inside that cat a liveness marker cannot be sent, because it
    would be written to the ctl file instead of run.  So the only way to
    stop forking was to give up asking whether the board was still
    alive, and everything downstream -- the "expect" argument, the
    three-silences rule, counting echoes that come back from the uart
    interrupt handler after the shell is dead -- is built to infer from
    the reply what a marker would have said outright.

    In lil(1) the file lives in a variable and writing to it is an
    ordinary statement, so nothing is swallowed and a marker is just
    another statement:

    	ctl := open("/dev/radio0/ctl", "w")
    	write(ctl, "freq 915000000")
    	print("M17")

    This class is beside Stream and not instead of it.  The board's init
    still loads sh, so lil is entered by typing its name, and a tool
    opts in by asking for c.lilstream() where it asked for c.stream().
    """

    def __init__(self, c, file="/dev/radio0/ctl", var="ctl"):
        self.c = c
        self.var = var
        self.silent = 0
        Console.seq += 1
        mark = "L%d.%d" % (int(time.time()) % 100000, Console.seq)
        # The shell is still what is running, so the first marker is a
        # shell marker: there is no point entering lil on a dead console.
        self.ok = c.mark(mark)
        if not self.ok:
            return
        c.send("lil")
        time.sleep(2.0)
        # And now one in lil's own language, which is the check Stream
        # cannot make at all.  If this does not come back, lil did not
        # start and nothing after it means anything.
        if not self.alive():
            self.ok = False
            sys.stderr.write("board: lil did not answer its own marker; "
                             "the shell may still be at the prompt\n")
            return
        self.c.send('%s := open("%s", "w")' % (var, file))
        time.sleep(1.5)
        # An open that failed says so, and saying so is the point: with
        # a cat the failure arrives later, as writes that go nowhere.
        t = self.c.text()[-400:]
        if "cannot open" in t:
            self.ok = False
            sys.stderr.write("board: lil cannot open %s\n" % file)

    def alive(self, wait=8.0):
        """Ask lil, in lil, whether it is running.  Two copies again:
        the first is the uart interrupt handler's echo, which keeps
        coming back after the interpreter is gone, and the second is
        print() actually running."""
        Console.seq += 1
        mark = "K%d.%d" % (int(time.time()) % 100000, Console.seq)
        self.c.send('print("%s")' % mark)
        end = time.time() + wait
        while time.time() < end:
            time.sleep(0.5)
            if self.c.text().count(mark) >= 2:
                return True
        return False

    def send(self, line, wait=25.0, expect=False):
        """Write one ctl line.  Same contract as Stream.send()."""
        if not self.ok or not self.c.alive():
            return None
        if self.silent >= 3:
            self.ok = False
            sys.stderr.write("board: three lil statements echoed and not "
                             "answered; stopping before the console queue "
                             "fills\n")
            return None
        stmt = '%s(%s, "%s")' % ("write", self.var, line)
        self.c.send(stmt)
        end = time.time() + wait
        last = None
        seen = False
        while time.time() < end:
            time.sleep(1.0)
            t = self.c.text()
            i = t.rfind(stmt)
            if i < 0:
                continue                # the echo has not come back yet
            seen = True
            after = t[i + len(stmt):]
            # lil reports a failed statement in its own voice and keeps
            # its prompt, where a cat that hits a write error quietly
            # hands the rest of the session to the shell.
            if "lil:" in after:
                self.ok = False
                return after
            if after == last and (after.strip() or not expect):
                self.silent = 0
                return after
            last = after
        if not seen:
            self.silent += 1
            return None
        reply = last if last is not None else ""
        if expect and not reply.strip():
            self.silent += 1
        else:
            self.silent = 0
        return reply

    def stmt(self, line, wait=25.0):
        """Run one lil statement that is not a ctl write -- a print, a
        slurp, a loop.  There is no equivalent in Stream: inside a cat
        every line is data."""
        if not self.ok:
            return None
        self.c.send(line)
        end = time.time() + wait
        last = None
        while time.time() < end:
            time.sleep(1.0)
            t = self.c.text()
            i = t.rfind(line)
            if i < 0:
                continue
            after = t[i + len(line):]
            if after == last:
                return after
            last = after
        return last

    def close(self):
        if self.ok:
            self.c.send("close(%s)" % self.var)
            time.sleep(1.0)
            self.c.eof()            # leave lil, back to the shell
            time.sleep(1.0)
            self.ok = False
