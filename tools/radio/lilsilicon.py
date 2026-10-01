#!/usr/bin/env python3
"""lil(1) on silicon: the part of plan item 6 that qemu cannot answer.

tools/radio/lilvsh.sh measures the shell against lil under qemu, on a
model whose memory is not the board's and whose console is not the
board's uart.  This runs the same shape of thing on an stm32f407 with
the Dis pool it really has: enter lil, hold a ctl file open across
forty writes with a marker printed between each -- the pattern a
shell's "cat >file" structurally cannot do -- and read /dev/memory off
the board before and after.

	lilsilicon.py [port]

The board is left inside lil, because lil has no exit; a reset is how
it leaves.
"""
import re, sys, time
sys.path.insert(0, __import__("os").path.dirname(
    __import__("os").path.abspath(__file__)))
from twoboard import open_board, Lil, Dead

PORT = sys.argv[1] if len(sys.argv) > 1 else "/dev/cu.usbserial-AQ02DK34"
N = 40


def heap(t):
    """The main pool's line out of /dev/memory.

    Columns four and five are allocations made and frees made, not
    objects alive; the live figure is their difference.  Reading column
    four as "live" is what produced the withdrawn claim that no Dis
    allocation in this tree is ever reclaimed.
    """
    for ln in t.splitlines():
        f = ln.split()
        # the pool's name is the LAST field, not the first:
        #   53440 79850 53952 1075 616 23 26394 main
        if len(f) >= 6 and f[-1] == "heap":
            try:
                return (int(f[0]), int(f[3]), int(f[4]))
            except ValueError:
                pass
    return None


b = open_board(PORT, "board")
l = Lil(b)

print("entering lil ...")
sys.stdout.flush()
if not l.enter():
    print("LILSILICON-FAILED lil did not answer its own marker (seen %d "
          "times; the shell may still be at the prompt)" % l.lastcount)
    raise SystemExit(1)
print("  lil is running statements on the board")
sys.stdout.flush()

t = l.run('ctl := open("/dev/radio0/ctl", "w")')
if "cannot open" in t[-400:]:
    print("LILSILICON-FAILED lil cannot open the ctl file")
    raise SystemExit(1)
print("  ctl held open in a variable")

t = l.run('print(slurp("/dev/memory"))', settle=4.0)
h0 = heap(t)
print("  /dev/memory before: %s" % (h0,))
sys.stdout.flush()

print("writing %d ctl lines through the one descriptor, with a marker "
      "printed between each ..." % N)
sys.stdout.flush()
ok = 0
for i in range(N):
    l._type('write(ctl, "rssioffset -90")')
    time.sleep(0.4)
    l._type('print("W%d")' % i)
    time.sleep(0.6)
    if b.text().count("W%d" % i) >= 2:
        ok += 1
print("  %d of %d markers came back twice while the file stayed open" %
      (ok, N))
sys.stdout.flush()

if not l.live():
    print("LILSILICON-FAILED lil stopped running statements after the writes")
    raise SystemExit(1)

t = l.run('print(slurp("/dev/memory"))', settle=4.0)
h1 = heap(t)
print("  /dev/memory after:  %s" % (h1,))
if h0 and h1:
    print("  cursize %+d  allocations %+d  frees %+d  live %+d"
          % (h1[0] - h0[0], h1[1] - h0[1], h1[2] - h0[2],
             (h1[1] - h1[2]) - (h0[1] - h0[2])))

t = l.run('print(slurp("/dev/radio0/stats"))', settle=5.0)
m = re.search(r"rssi (-?\d+)\S* offset (-?\d+)", t)
print("  the radio, read through lil: rssi %s offset %s" %
      (m.group(1), m.group(2)) if m else "  no stat block came back")

# The known ceiling, and what distinguishes lil from the shell: the
# shell dies here and takes the console with it.
t = l.run('print(dir("/dis"))', settle=6.0)
oom = "out of memory" in t or "no memory" in t
print("  dir(\"/dis\"): %s" % ("reported out of memory" if oom
                               else "returned"))
if not l.live():
    print("LILSILICON-FAILED lil did not keep its prompt after dir(/dis)")
    raise SystemExit(1)
print("  and lil still has its prompt afterwards")
print("LILSILICON-OK %d of %d" % (ok, N))
