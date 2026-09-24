#!/usr/bin/env python3
#
# Max-hold a span with the CC1120 and say what stands above the floor.
#
# The driver's "hold" verb takes at most 64 steps, which is 1.6MHz at a
# 25kHz raster -- less than the paging allocation this was written for.
# So this splits the span, runs a hold per chunk, and puts the rows back
# together.
#
# Why max-hold and not a probe per channel.  Almost nothing in these
# bands is transmitting when you look at it: the paging carriers this
# bench found appeared in 6 sweeps out of 20, and a 2-second probe of
# each of nine of them caught none of the nine.  A probe answers "is it
# on now" and the answer is usually no, which is not the same as "there
# is nothing there".  Max-hold over many passes answers "was it ever on
# while I watched", which is the question.
#
# The verdict is against the median of the span and not against a fixed
# number, because the floor moves with the band, the antenna and the
# AGC.  Anything more than a few dB above the median of its own span is
# worth a second look; a span whose rows are all within a dB or two of
# each other has nothing in it at all, and saying so plainly is most of
# the value.
#
#	bandhold.py 928000000 932000000 [step] [ms] [passes]
#
import os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import board

MAXSTEP = 64            # the driver's Nholdstep
FXOSC = 32000000        # the part's crystal, and the reason for spur()


def spur(hz, tol=8000):
    """Is this a harmonic of the part's own crystal?

    It has to be asked of every candidate, because the three strongest
    carriers this receiver can find anywhere in its range are its own.
    896.000, 928.000 and 960.000MHz all read -86 to -88dBm against a
    -110 floor, all with the same flat-topped shape narrower than the
    8kHz filter, and they are 28, 29 and 30 times 32.000000MHz.  The
    928 one is the worst trap of the three: it sits exactly on the ISM
    band edge, where a real fixed-link allocation begins, and it is
    continuous, strong and narrowband, which is what a SCADA base
    station looks like.

    Eight kilohertz of tolerance because that is the narrowest filter
    the part will accept, so a harmonic cannot be located better than
    that.
    """
    n = (hz + FXOSC // 2) // FXOSC
    if n < 1:
        return 0
    return abs(hz - n * FXOSC) <= tol and n or 0


def holds(c, lo, hi, step, ms, passes):
    """Rows of (hz, dbm), over as many hold runs as the span needs."""
    rows = []
    n = (hi - lo) // step + 1
    per = MAXSTEP - 1
    start = lo
    while start <= hi:
        end = min(hi, start + (per - 1) * step)
        out = c.ctl(["hold %d %d %d %d %d" % (start, end, step, ms, passes)],
                    wait=60 + (end - start) // step * ms * passes // 400) or ""
        if "write error" in out or "refused" in out:
            print(out.strip()[-200:])
            return rows
        # Scan the whole window and not the marker-sliced reply.
        #
        # ctl() returns the text after its marker, which is right for a
        # verb that prints a line or two and wrong for one that prints
        # sixty-three: the window scrolls, the marker goes off the top,
        # the slice comes back empty and the chunk is silently lost.
        # That is what made a 131-channel sweep report five channels --
        # the last chunk only -- twice, without appearing to fail.
        #
        # Filtering by the range asked for is what makes this safe:
        # rows from an earlier chunk, or from an earlier run, are
        # outside it and do not get counted twice.
        seen = set()
        for l in (c.text() + "\n" + (out or "")).split("\n"):
            m = re.search(r"\bhold (\d+) (-?\d+)\s*$", l.strip())
            if m:
                hz, db = int(m.group(1)), int(m.group(2))
                if start <= hz <= end and hz not in seen:
                    seen.add(hz)
                    rows.append((hz, db))
        sys.stdout.flush()
        start = end + step
    return rows


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: bandhold.py <start Hz> <stop Hz> [step] [ms] [passes]")
    lo, hi = int(sys.argv[1]), int(sys.argv[2])
    step = int(sys.argv[3]) if len(sys.argv) > 3 else 25000
    ms = int(sys.argv[4]) if len(sys.argv) > 4 else 20
    passes = int(sys.argv[5]) if len(sys.argv) > 5 else 10
    c = board.Console(os.environ.get("CLAUDE_JOB_DIR", "/tmp") + "/tmp")
    rows = holds(c, lo, hi, step, ms, passes)
    if not rows:
        print("no rows; the board said nothing this could read")
        return
    lv = sorted(d for _, d in rows)
    med = lv[len(lv) // 2]
    print("%d channels of %dkHz, %d passes of %dms" %
          (len(rows), step // 1000, passes, ms))
    print("max-hold floor %d, median %d, ceiling %d dBm" % (lv[0], med, lv[-1]))
    hot = [(h, d) for h, d in rows if d >= med + 6]
    if hot:
        print("more than 6dB over the median:")
        for h, d in sorted(hot, key=lambda r: -r[1]):
            n = spur(h)
            note = "  <- %dx the 32MHz crystal, not on the air" % n if n else ""
            print("   %9d  %4d dBm  (+%d)%s" % (h, d, d - med, note))
        if all(spur(h) for h, _ in hot):
            print("every one of them is a crystal harmonic; nothing here")
    else:
        print("nothing more than 6dB over the median; the span is empty")
        print("as far as this receiver saw it, over %.1fs a channel" %
              (passes * ms / 1000.0))


if __name__ == "__main__":
    main()
