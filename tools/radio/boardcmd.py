#!/usr/bin/env python3
#
# Type lines at a board through its screen(1) session, and REFUSE to
# report anything unless the board is running what is typed.
#
# WHY THE REFUSAL IS THE POINT.  This console echoes every character
# from the uart interrupt handler, which keeps working long after the
# Dis shell behind it has gone.  So a wedged board looks exactly like a
# healthy one if you only read the screen: the commands appear, and the
# replies you find are scrollback from when it was alive.
#
# That is not a hypothesis.  A throwaway version of this script without
# the check reported a receiver at "rssi -8, pktcfg0 0x00, pktlen 3" and
# I built two conclusions on it -- a saturated front end, then a
# misconfigured packet engine -- before noticing the board had not run a
# command in several minutes and every figure was history.
#
# board.py's Console.mark() has had this right all along: a marker typed
# at the console comes back twice when something is running it, once
# when only the interrupt handler is.  This is that rule, applied to the
# screen-session path, because the quick scripts kept skipping it.
#
#	boardcmd.py <screen-session> <logfile> 'cmd' ['cmd' ...]
#
# Exits non-zero and prints BOARD-DEAD if the board is not running
# commands, before sending anything else.
#
import os, subprocess, sys, time

CHARDELAY = 0.02


def stuff(sess, line):
    for ch in line:
        subprocess.run(["screen", "-S", sess, "-X", "stuff", ch])
        time.sleep(CHARDELAY)
    subprocess.run(["screen", "-S", sess, "-X", "stuff", "\n"])


def screentext(sess, scratch):
    p = os.path.join(scratch, "hc-%s.txt" % sess.split(".")[0])
    subprocess.run(["screen", "-S", sess, "-X", "hardcopy", "-h", p])
    time.sleep(0.6)
    with open(p, "rb") as f:
        return f.read().decode("utf-8", "replace")


def alive(sess, scratch, wait=10.0):
    """Two copies of a fresh marker, or the board is not running commands."""
    mark = "LIVE%d" % (int(time.time() * 1000) % 1000000)
    stuff(sess, "echo " + mark)
    end = time.time() + wait
    while time.time() < end:
        time.sleep(0.5)
        if screentext(sess, scratch).count(mark) >= 2:
            return mark
    return None


def main():
    if len(sys.argv) < 4:
        sys.exit("usage: boardcmd.py <screen-session> <logfile> 'cmd' ...")
    sess, out = sys.argv[1], sys.argv[2]
    scratch = os.environ.get("CLAUDE_JOB_DIR", "/tmp") + "/tmp"
    os.makedirs(scratch, exist_ok=True)

    mark = alive(sess, scratch)
    if mark is None:
        print("BOARD-DEAD %s: the console echoes but runs nothing; "
              "everything readable from it is scrollback" % sess)
        return 1

    log = open(out, "w")
    log.write("LIVE marker %s answered twice\n" % mark)
    for line in sys.argv[3:]:
        stuff(sess, line)
        time.sleep(3.0)
        log.write("SENT %s\n" % line)
        log.flush()
    time.sleep(2)
    # A second marker after the work, so a board that died DURING it
    # cannot have its last replies believed either.
    mark2 = alive(sess, scratch)
    t = screentext(sess, scratch)
    log.write("=== screen tail ===\n")
    log.write(t[-4000:])
    log.close()
    if mark2 is None:
        print("BOARD-DIED-MIDWAY %s: it answered before the commands and "
              "not after, so the replies cannot be trusted" % sess)
        return 1
    print("ok, alive before and after")
    return 0


if __name__ == "__main__":
    sys.exit(main())
