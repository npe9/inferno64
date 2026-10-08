#!/usr/bin/env python3
"""Two boards over two screen(1) sessions, where every read is checked.

WHY THIS IS A MODULE AND NOT ANOTHER SCRIPT.  This console echoes from
the uart interrupt handler, which keeps working after the Dis shell has
gone, so a dead board looks healthy if you only read the screen: the
command appears and the "reply" is scrollback from when it was alive.
boardcmd.py has refused to report under those conditions since early on.

And then I wrote four one-off scripts that skipped it, and three of them
produced results I had to throw away -- a SYNC_THR sweep whose rows 17
to 30 were one stale stats read repeated after the board died at 14, a
csthr sweep taken while the board had silently rebooted onto 868MHz, and
a saturation reading that was a cleared AGC register.  Each time the
numbers looked like data.

So the discipline lives here, where it cannot be skipped by writing
another file:

    read()  marks the board live, sends, marks again, and raises if
            either mark fails or if the watched register moved
    stats() parses the whole stat file and returns it as a dict
    expect() asserts a register still holds what it was set to, so a
            board that reboots mid-measurement voids the measurement
            instead of quietly supplying defaults

A measurement that cannot be invalidated by its own instrument is worth
more than a faster one.
"""
import os, re, subprocess, sys, time

CHARDELAY = 0.02


class Dead(Exception):
    """The board stopped running what was typed at it."""


class PortBoard:
    """A board reached by opening its tty, with no screen(1) in the way.

    Preferable to the screen path whenever nothing is attached to the
    port, and the reason is not convenience.  A screen session's handle
    is its pid, which changes every time the window is restarted, and
    three runs here ended in a Dead blaming a board whose session had
    simply been renumbered -- "No screen session found" printed once per
    character stuffed.  A port belongs to the adapter.

    The liveness rule is the same and matters as much: a marker must
    come back twice, because this console echoes from the uart interrupt
    handler long after the Dis shell is gone.  Zero copies means nothing
    typed is arriving, which is a different fault from one copy and is
    reported as such -- that distinction cost a wrong diagnosis today,
    a board called hung when its boot log was perfectly readable and
    only the host-to-board direction was dead.
    """
    def __init__(self, port, name=None, scratch=None):
        sys.path.insert(0, os.path.join(os.path.dirname(
            os.path.abspath(__file__)), "..", "f407"))
        import console
        self.console = console
        self.port = port
        self.name = name or os.path.basename(port)
        self.fd = console.open_port(port)
        self.buf = ""

    def text(self):
        self.buf += self.console.drain(self.fd, 0.6)
        if len(self.buf) > 65536:
            self.buf = self.buf[-32768:]
        return self.buf

    def _send(self, line):
        for ch in line + "\n":
            os.write(self.fd, ch.encode())
            time.sleep(CHARDELAY)


    def reset(self):
        """^R twice running, which devuart handles in its receive interrupt.

        NOT _stuff("\x12") twice: _stuff and _send both append a newline,
        so that sends ^R, newline, ^R, newline -- and any character
        between the two ^Rs disarms the sequence.  Eight reset-and-measure
        trials ran against a board that was never reset, reporting a
        delivery rate as if each trial had drawn a fresh beacon phase when
        every one of them was the same phase.  tools/f407/flashverify.sh
        has always done it with bare stuffs for this reason; this is that,
        where the boards are.
        """
        for _ in range(2):
            os.write(self.fd, b"\x12")
            time.sleep(0.2)

    def live(self, wait=10.0):
        mark = "LV%d" % (int(time.time() * 1000) % 1000000)
        self._send("echo " + mark)
        end = time.time() + wait
        best = 0
        while time.time() < end:
            time.sleep(0.5)
            n = self.text().count(mark)
            best = max(best, n)
            if n >= 2:
                return True
        self.lastcount = best
        return False

    def read(self, line, settle=4.0):
        if not self.live():
            raise Dead("%s: not running commands BEFORE %r (marker seen %d "
                       "times; 0 means nothing typed is arriving)"
                       % (self.name, line, getattr(self, "lastcount", -1)))
        self._send(line)
        time.sleep(settle)
        t = self.text()
        if not self.live():
            raise Dead("%s: died DURING %r -- its reply is scrollback"
                       % (self.name, line))
        return t

    # the rest of the interface is identical, so borrow it
    ctl = None


def session_for(port):
    """The screen session that owns this serial device.

    Board takes a SESSION name, because screen's -S wants one and the
    board's console belongs to screen -- opening the device a second
    time wedges the adapter until it is replugged, so going around
    screen is not an option.  Callers naturally have the device path,
    and handing that to Board makes every "screen -S <path> -X ..."
    fail with "Must run suid root for multiuser support." and exit 1.

    Nothing then raises.  reset() resets nothing, clear() clears
    nothing, and hardcopy writes nothing -- so text() re-reads the
    hardcopy file from whenever it last worked and returns it as the
    live console, for as long as you keep asking.  Two runs were read
    out of a file frozen half an hour earlier, and screen's error was
    printed hundreds of times into the same log while that happened.

    Resolved the way tools/f407/flashverify.sh resolves it: whoever has
    the device open, matched against screen's own session list.
    """
    pids = subprocess.run(["lsof", "-t", port],
                          capture_output=True, text=True).stdout.split()
    out = subprocess.run(["screen", "-ls"],
                         capture_output=True, text=True).stdout
    for s in re.findall(r"(\d+\.ttys\d+\.\S+)", out):
        if s.split(".")[0] in pids:
            return s
    raise Dead("no screen session has %s open; screen must own the "
               "board's console and a second opener wedges the adapter"
               % port)


class Board:
    def __init__(self, session, name=None, scratch=None):
        self.sess = session
        self.name = name or session.split(".")[0]
        self.scratch = scratch or (
            os.environ.get("CLAUDE_JOB_DIR", "/tmp") + "/tmp")
        os.makedirs(self.scratch, exist_ok=True)
        self.hc = os.path.join(self.scratch, "tb-%s.txt" % self.name)

    def _stuff(self, line):
        for ch in line:
            subprocess.run(["screen", "-S", self.sess, "-X", "stuff", ch])
            time.sleep(CHARDELAY)
        subprocess.run(["screen", "-S", self.sess, "-X", "stuff", "\n"])

    def text(self):
        subprocess.run(["screen", "-S", self.sess, "-X", "hardcopy",
                        "-h", self.hc])
        time.sleep(0.6)
        with open(self.hc, "rb") as f:
            return f.read().decode("utf-8", "replace")

    def clear(self, tries=4):
        """Empty the TERMINAL's scrollback, and prove it is empty.

        Resetting the board does not clear the terminal, and a reader
        that greps the scrollback will happily answer from the previous
        session.  The sequence is screen's only way to empty the buffer
        -- "scrollback 0" discards it and a second call puts it back --
        but the three "screen -X" commands are QUEUED to the session and
        their effects are not serialised with respect to each other.
        Issued back to back with no delay, "scrollback 10000" lands
        before "clear", and clear then pushes the whole display into a
        buffer that is live again: nothing is discarded.

        That is not a theoretical race.  Run back to back it left three
        boot sessions in the buffer and two consecutive measurements
        were read out of the OLDEST one -- including a kernel that had
        usage-faulted at startup, which read as a clean run because the
        clean run's text was still there.  The tell was two readings
        agreeing to the byte, and it was explained away once.

        So: delays between the commands, and then a hardcopy that has
        to come back blank before this returns.  A clear that cannot
        report failure is how the stale text got read as a result.
        """
        for i in range(tries):
            for cmd in (["scrollback", "0"], ["clear"],
                        ["scrollback", "10000"]):
                subprocess.run(["screen", "-S", self.sess, "-X"] + cmd)
                time.sleep(0.4)
            if not [l for l in self.text().splitlines() if l.strip()]:
                return
        raise Dead("%s: scrollback will not clear after %d tries; "
                   "every reading from it would be the previous session"
                   % (self.sess, tries))


    def reset(self):
        """^R twice running, which devuart handles in its receive interrupt.

        NOT _stuff("\x12") twice: _stuff and _send both append a newline,
        so that sends ^R, newline, ^R, newline -- and any character
        between the two ^Rs disarms the sequence.  Eight reset-and-measure
        trials ran against a board that was never reset, reporting a
        delivery rate as if each trial had drawn a fresh beacon phase when
        every one of them was the same phase.  tools/f407/flashverify.sh
        has always done it with bare stuffs for this reason; this is that,
        where the boards are.
        """
        for _ in range(2):
            subprocess.run(["screen", "-S", self.sess, "-X", "stuff",
                            "\x12"])
            time.sleep(0.2)

    def live(self, wait=10.0):
        """Two copies of a fresh marker, or it is not running commands.

        Records the count in self.lastcount, as PortBoard does, because
        the two classes differing here defeated the diagnosis they exist
        to provide: open_board had returned this one, lastcount was never
        set, and a board was reported with "marker -1" -- which says
        nothing about whether anything typed was arriving.  Zero and one
        are different faults and both paths have to be able to say which.
        """
        mark = "LV%d" % (int(time.time() * 1000) % 1000000)
        self._stuff("echo " + mark)
        end = time.time() + wait
        best = 0
        while time.time() < end:
            time.sleep(0.5)
            n = self.text().count(mark)
            best = max(best, n)
            if n >= 2:
                self.lastcount = n
                return True
        self.lastcount = best
        return False

    def read(self, line, settle=4.0):
        """Send one line, bracketed by liveness marks."""
        if not self.live():
            raise Dead("%s: not running commands BEFORE %r (marker seen %d "
                       "times; 0 means nothing typed is arriving, 1 means "
                       "the shell is gone)"
                       % (self.name, line, getattr(self, "lastcount", -1)))
        self._stuff(line)
        time.sleep(settle)
        t = self.text()
        if not self.live():
            raise Dead("%s: died DURING %r -- its reply is scrollback"
                       % (self.name, line))
        return t

    def ctl(self, verb, settle=3.0):
        return self.read("echo %s >/dev/radio0/ctl" % verb, settle)

    def stats(self):
        t = self.read("cat /dev/radio0/stats", settle=5.0)
        i = t.rfind("part CC1120")
        if i < 0:
            raise Dead("%s: no stat block in its output" % self.name)
        s = t[i:i + 640]
        def g(rx, d=None):
            m = re.search(rx, s)
            return m.group(1) if m else d
        return dict(
            freq=g(r"freq (\d+)"), rate=g(r"rate (\d+)"),
            dev=g(r"deviation (\d+)"), bw=g(r"bw (\d+)"),
            rssi=g(r"rssi (-?\d+)"), csthr=g(r"csthr (-?\d+)"),
            last=g(r"last (-?\d+)"), pktcfg0=g(r"pktcfg0 (0x[0-9a-f]+)"),
            pktlen=g(r"pktlen (\d+)"),
            sent=g(r"sent (\d+)"), recv=g(r"sent \d+ recv (\d+)"),
            crcerr=g(r"crcerr (\d+)"), rxoverflow=g(r"rxoverflow (\d+)"),
            txtrace=g(r"txtrace ([0-9 ]+) left"), raw=s)

    def expect(self, **want):
        """Void the measurement if the part no longer holds what it was set
        to -- a board that reboots mid-run supplies defaults, not data."""
        got = self.stats()
        for k, v in want.items():
            if str(got.get(k)) != str(v):
                raise Dead("%s: %s is %s, expected %s -- it has been reset "
                           "and anything measured since is void"
                           % (self.name, k, got.get(k), v))
        return got

    def lastrx(self):
        t = self.ctl("lastrx", settle=4.0)
        m = re.findall(r"lastrx ([^\n]*)", t)
        return m[-1].strip() if m else ""

    def reaches_tx(self):
        """txtrace element 4 is the state after STX: 2 is TX, 4 CALIBRATE.
        The driver counts sent either way, so this is the only honest
        check that a packet was actually put on the air."""
        tt = (self.stats().get("txtrace") or "").split()
        return len(tt) > 4 and tt[4] == "2"


# PortBoard differs from Board only in how a line is sent and the text
# read back; everything that parses a stat file is the same code.
for _m in ("ctl", "stats", "expect", "lastrx", "reaches_tx"):
    setattr(PortBoard, _m, getattr(Board, _m))


class Lil:
    """lil(1) running on a board, with the marker rule kept.

    Board.read() brackets every line with "echo <mark>", which is a
    shell statement and means nothing to an interpreter that is not a
    shell.  The rule it enforces still applies and for the same reason:
    this console echoes from the uart interrupt handler long after the
    Dis program behind it is gone, so one copy of a marker is scrollback
    and two is something running.

    In lil the marker is just another statement, which is the whole
    point of the thing -- inside a shell's "cat >file" a marker cannot
    be sent at all, because it would be written to the file instead of
    run, and board.py's Stream gave up asking whether the board was
    alive for exactly that reason.  Here:

    	ctl := open("/dev/radio0/ctl", "w")
    	write(ctl, "rssioffset -90")
    	print("M17")

    and the marker comes back from print() while the descriptor stays
    open.  enter() leaves the board inside lil; nothing puts it back,
    because lil has no exit and a reset is how a board leaves it.
    """
    def __init__(self, board):
        self.b = board
        self.n = 0

    def enter(self, wait=12.0):
        """Type lil at a shell that is running, and prove it started."""
        if not self.b.live():
            raise Dead("%s: not running commands before lil (marker seen "
                       "%d times)" % (self.b.name,
                                      getattr(self.b, "lastcount", -1)))
        self.b._send("lil") if hasattr(self.b, "_send") else self.b._stuff("lil")
        time.sleep(2.5)
        return self.live(wait)

    def _type(self, line):
        if hasattr(self.b, "_send"):
            self.b._send(line)
        else:
            self.b._stuff(line)

    def live(self, wait=12.0):
        """A marker in lil's own language, twice."""
        self.n += 1
        mark = "K%d.%d" % (int(time.time() * 1000) % 1000000, self.n)
        self._type('print("%s")' % mark)
        end = time.time() + wait
        best = 0
        while time.time() < end:
            time.sleep(0.5)
            c = self.b.text().count(mark)
            best = max(best, c)
            if c >= 2:
                self.lastcount = c
                return True
        self.lastcount = best
        return False

    def run(self, line, settle=2.5):
        """One statement, bracketed by lil markers."""
        if not self.live():
            raise Dead("%s: lil not running statements BEFORE %r (marker "
                       "seen %d times)"
                       % (self.b.name, line, getattr(self, "lastcount", -1)))
        self._type(line)
        time.sleep(settle)
        t = self.b.text()
        if not self.live():
            raise Dead("%s: lil died DURING %r -- its reply is scrollback"
                       % (self.b.name, line))
        return t


def open_board(port, name=None):
    """A board at this port, however it happens to be reachable.

    Either path works and which one applies is not under this script's
    control: a screen(1) window may or may not be attached to the tty at
    any moment, and whichever it is, the port is busy for the other
    method.  Picking by hand meant a run dying on "Resource busy" or on
    "No screen session found" depending on what the bench looked like
    minutes earlier, which is a property of the terminal and not of the
    measurement.
    """
    held = subprocess.run(["lsof", "-t", port], capture_output=True,
                          text=True).stdout.split()
    if held:
        return by_port(port)
    return PortBoard(port, name)


def sessions():
    """Every screen session, by the name screen prints for it.

    NOT just the pid.ttysNN.host ones.  That was the pattern here, and
    it makes a session created with "screen -dmS name" invisible --
    screen calls it "40033.name" -- so a board whose console is in a
    detached named session came back as "held by pid 40033, which is not
    a screen session" and the run died at its first line.  Which is
    worse than it sounds: the fallback is to open the tty directly, and
    two openers wedge the adapter.

    The pid is what the caller matches against, so anything of the form
    <pid>.<rest> will do.
    """
    out = subprocess.run(["screen", "-ls"], capture_output=True,
                         text=True).stdout
    return re.findall(r"^\s*(\d+\.\S+)", out, re.M)


def by_port(port):
    """The screen session holding this tty, as a Board.

    Named sessions are the wrong handle and this took three failures to
    accept: screen's pid changes whenever the window is restarted, so a
    hardcoded "59999.ttys023.Noethikoma" quietly becomes "No screen
    session found" printed once per character stuffed, and the run ends
    in a Dead that blames the board.  The board did not move; the
    session did.

    The port is the stable name -- it belongs to the adapter, not to the
    terminal -- so this asks which process has the tty open and matches
    that pid against the session list.  board.py's session() has done it
    this way all along, for the same reason and after the same mistake:
    its comment records typing one board's commands into another
    window.
    """
    pids = subprocess.run(["lsof", "-t", port], capture_output=True,
                          text=True).stdout.split()
    if not pids:
        raise Dead("nothing holds %s -- no screen is attached to it" % port)
    for s in sessions():
        if s.split(".")[0] in pids:
            return Board(s, os.path.basename(port))
    raise Dead("%s is held by pid %s, which is not a screen session"
               % (port, ",".join(pids)))


if __name__ == "__main__":
    import glob
    for s in sessions():
        b = Board(s)
        print("%-30s %s" % (s, "alive" if b.live() else "NOT RUNNING COMMANDS"))
    print()
    for port in sorted(glob.glob("/dev/cu.usbserial-*") +
                       glob.glob("/dev/cu.PL2303*")):
        held = subprocess.run(["lsof", "-t", port], capture_output=True,
                              text=True).stdout.split()
        print("%-40s %s" % (port, "screen " + held[0] if held else "-"))
