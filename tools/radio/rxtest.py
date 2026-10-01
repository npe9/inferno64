#!/usr/bin/env python3
#
# Characterise a CC1120 receiver against a controlled stimulus.
#
# WHY.  Every negative this bench has recorded about the receive path was
# taken with nothing known to be transmitting, or with a transmitter
# whose output was never measured.  A receiver that hears nothing when
# nothing is sent cannot be told from a deaf one, and a receiver that
# hears nothing from a transmitter later found to be silent has not been
# tested at all -- both of which happened here today.
#
# A signal generator fixes that.  An FM carrier swinging between two
# frequencies at a fixed rate is, to a 2-FSK demodulator, exactly an
# alternating symbol at a known rate -- which is a preamble.  So the
# receiver is configured for that deviation and rate, told to hunt the
# alternating word 0xaaaa, and watched with the generator on and off in
# the same minutes at the same settings.
#
# THE SYNC WORD IS 0xaaaa HERE ON PURPOSE, and it is wrong for a
# board-to-board link.  A real CC1120 sends 0xAA as its preamble and
# then a distinct sync word; hunting 0xaaaa inside that run gives the
# detector no bit boundary.  But a generator sends nothing BUT the
# alternating pattern, so 0xaaaa is the only word there is to find.
# Using it against another board is the mistake; using it here is the
# point.
#
# OFF IS HALF THE MEASUREMENT.  At a loose carrier-sense threshold the
# detector fires on noise -- this bench has a recv with a garbage payload
# at the noise floor to prove it -- so "it asserted with the generator
# on" means nothing without "and stayed quiet with it off".
#
#	rxtest.py <screen-session> [--levels -50,-40,-30,-20]
#
import os, re, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "tinysa"))
import tinysa

TONE = 4800                     # modulating frequency
DEV = 6000                      # FM deviation, the generator's maximum
RATE = 2 * TONE                 # two symbols per cycle


def stuff(sess, line):
    for ch in line:
        subprocess.run(["screen", "-S", sess, "-X", "stuff", ch])
        time.sleep(0.02)
    subprocess.run(["screen", "-S", sess, "-X", "stuff", "\n"])


def screentext(sess, scratch):
    p = os.path.join(scratch, "rx-%s.txt" % sess.split(".")[0])
    subprocess.run(["screen", "-S", sess, "-X", "hardcopy", "-h", p])
    time.sleep(0.6)
    return open(p, "rb").read().decode("utf-8", "replace")


def alive(sess, scratch, wait=10.0):
    mark = "RX%d" % (int(time.time() * 1000) % 1000000)
    stuff(sess, "echo " + mark)
    end = time.time() + wait
    while time.time() < end:
        time.sleep(0.5)
        if screentext(sess, scratch).count(mark) >= 2:
            return True
    return False


def run(sess, scratch, line, settle=3.0):
    stuff(sess, line)
    time.sleep(settle)
    return screentext(sess, scratch)


def pin(sess, scratch, sel, ms=1000):
    """Percent of a window the chosen pin is high."""
    t = run(sess, scratch, "echo gread %d %s >/dev/radio0/ctl" % (ms, sel),
            settle=ms / 1000.0 + 4)
    m = re.findall(r"iocfg3 %s us \d+ samples (\d+) high (\d+) pct (\d+)"
                   % sel, t)
    return int(m[-1][2]) if m else None


def main():
    a = sys.argv[1:]
    if not a:
        sys.exit("usage: rxtest.py <screen-session> [--levels a,b,c]")
    sess = a[0]
    levels = [-50, -40, -30, -20]
    if "--levels" in a:
        levels = [int(x) for x in a[a.index("--levels") + 1].split(",")]
    scratch = os.environ.get("CLAUDE_JOB_DIR", "/tmp") + "/tmp"
    os.makedirs(scratch, exist_ok=True)

    if not alive(sess, scratch):
        sys.exit("rxtest: %s is not running commands" % sess)
    print("board answers")

    # The receiver, matched to what the generator will produce.
    for line in ("freq 915000000", "rate %d" % RATE, "deviation %d" % DEV,
                 "bw 50000", "csthr -104", "sync 0xaaaa 16",
                 # SYNC_CFG1: mode 2 from SYNC15_0, threshold 11 as the
                 # driver's table leaves it.  Swept separately below.
                 "reg 0x08 0x4b"):
        run(sess, scratch, "echo %s >/dev/radio0/ctl" % line)
    print("receiver set: 915MHz, rate %d, deviation %d, bw 50000, "
          "sync 0xaaaa/16" % (RATE, DEV))

    fd = tinysa.open_port(wait=20)
    for q in ("mode low output", "sweep 915000000 915000000",
              "modulation fm", "modulation deviation %d" % DEV,
              "modulation freq %d" % TONE, "output normal"):
        tinysa.cmd(fd, q)
    print("generator: %s" % (tinysa.cmd(fd, "sweep") or "").replace("\r", " ")[:60])

    print()
    print("  %-8s %-18s %-18s" % ("level", "PQT off / on", "SYNC off / on"))
    try:
        for lv in levels:
            tinysa.cmd(fd, "level %d" % lv)
            tinysa.cmd(fd, "output off")
            time.sleep(1.5)
            pq_off = pin(sess, scratch, "0x0b")
            sy_off = pin(sess, scratch, "0x06")
            tinysa.cmd(fd, "output on")
            time.sleep(1.5)
            pq_on = pin(sess, scratch, "0x0b")
            sy_on = pin(sess, scratch, "0x06")
            print("  %-8s %-18s %-18s" % (
                "%d dBm" % lv,
                "%s%% / %s%%" % (pq_off, pq_on),
                "%s%% / %s%%" % (sy_off, sy_on)))
            sys.stdout.flush()
    finally:
        tinysa.cmd(fd, "output off")
        tinysa.cmd(fd, "mode low input")
        print("\ngenerator off, instrument back to input")


if __name__ == "__main__":
    main()
