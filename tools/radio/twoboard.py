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

    def live(self, wait=10.0):
        """Two copies of a fresh marker, or it is not running commands."""
        mark = "LV%d" % (int(time.time() * 1000) % 1000000)
        self._stuff("echo " + mark)
        end = time.time() + wait
        while time.time() < end:
            time.sleep(0.5)
            if self.text().count(mark) >= 2:
                return True
        return False

    def read(self, line, settle=4.0):
        """Send one line, bracketed by liveness marks."""
        if not self.live():
            raise Dead("%s: not running commands BEFORE %r" % (self.name, line))
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


def sessions():
    out = subprocess.run(["screen", "-ls"], capture_output=True,
                         text=True).stdout
    return re.findall(r"(\d+\.ttys\d+\.\S+)", out)


if __name__ == "__main__":
    for s in sessions():
        b = Board(s)
        print("%-30s %s" % (s, "alive" if b.live() else "NOT RUNNING COMMANDS"))
