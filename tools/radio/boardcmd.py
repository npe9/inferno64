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
    """Two copies of a fresh marker, or the board is not running commands.

    Returns (mark, count).  The count matters and this used to throw it
    away, which cost a wrong diagnosis: the failure was reported as "the
    console echoes but runs nothing" when the marker had come back ZERO
    times, meaning nothing typed was reaching the board at all.  Those
    are different faults with different fixes --

        0   the host-to-board direction is dead.  The board may be
            perfectly healthy; its output still arrives, so its boot log
            reads normally and it looks hung when it is only deaf.  Look
            at the cable, the adapter's transmit line, the click.
        1   the uart interrupt handler is echoing and no Dis process is
            left to run what it echoes.  The board needs a reset.
        2+  healthy.
    """
    mark = "LIVE%d" % (int(time.time() * 1000) % 1000000)
    stuff(sess, "echo " + mark)
    end = time.time() + wait
    best = 0
    while time.time() < end:
        time.sleep(0.5)
        n = screentext(sess, scratch).count(mark)
        best = max(best, n)
        if n >= 2:
            return mark, n
    return None, best


def main():
    if len(sys.argv) < 4:
        sys.exit("usage: boardcmd.py <screen-session> <logfile> 'cmd' ...")
    sess, out = sys.argv[1], sys.argv[2]
    scratch = os.environ.get("CLAUDE_JOB_DIR", "/tmp") + "/tmp"
    os.makedirs(scratch, exist_ok=True)

    mark, n = alive(sess, scratch)
    if mark is None:
        if n == 0:
            print("BOARD-UNREACHABLE %s: a fresh marker came back 0 times, "
                  "so nothing typed is reaching the board.  Its output may "
                  "still be fine -- check the cable and the adapter's "
                  "transmit line before resetting anything." % sess)
        else:
            print("BOARD-DEAD %s: the marker echoed once and was not run, "
                  "so the uart handler is alive and no Dis process is left. "
                  "Everything else readable is scrollback." % sess)
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
    mark2, n2 = alive(sess, scratch)
    t = screentext(sess, scratch)
    log.write("=== screen tail ===\n")
    log.write(t[-4000:])
    log.close()
    if mark2 is None:
        print("BOARD-DIED-MIDWAY %s: it answered before the commands and not "
              "after (marker seen %d times), so the replies cannot be trusted"
              % (sess, n2))
        return 1
    print("ok, alive before and after")
    return 0


if __name__ == "__main__":
    sys.exit(main())
