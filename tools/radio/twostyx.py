#!/usr/bin/env python3
#
# Watch both ends of the Styx-over-the-radio run and report the verdict
# with the counters beside it.
#
# The question this exists for is the two-byte short read: #P/arch is
# 273 bytes and came back 273 then 271.  appl/cmd/styxseg.b has since
# shown the chopping and the reassembly do not lose data, so the bytes
# are in devax25 or on the air -- and os/inferno/radio/cc1120.c now
# counts rxpartial, a packet whose payload the FIFO did not hold when
# the length byte was read.  If that climbs, the diagnosis is confirmed;
# if it stays at zero, the fault is elsewhere.
#
import re, subprocess, sys, time
sys.path.insert(0, "/Users/npe/src/inferno64-branches/xip/tools/radio")
import twoboard

SAT = sys.argv[1]
GND = sys.argv[2]
SECS = float(sys.argv[3]) if len(sys.argv) > 3 else 420.0

# Board wants the SCREEN SESSION, not the device path.  Passing the
# path made every screen command a silent no-op and text() kept
# returning a hardcopy file frozen at whatever time it last worked --
# see twoboard.session_for().
ends = [("sat", twoboard.Board(twoboard.session_for(SAT), name="sat")),
        ("gnd", twoboard.Board(twoboard.session_for(GND), name="gnd"))]

# CLEAR THE WINDOW, THEN RESET BOTH, SATELLITE FIRST, so that
# everything in the scrollback belongs to this run.
#
# This dedupes by line text, which is sound WITHIN a run because the
# relay prints a running total and so no two of its lines are alike --
# and was unsound across runs: the satellite had hours of its previous
# session in the window, and every new line matching an old one was
# suppressed.  The byte accounting then read as if frames had gone
# missing, which is exactly the fault being hunted.  An instrument that
# invents the symptom it is looking for is worse than none.
#
# The satellite first because it announces and waits, and the ground
# calls on boot: the answerer has to be listening before the caller
# calls.
for name, b in ends:
    # Resetting the BOARD does not clear the TERMINAL, and that is the
    # same mistake twice: the first version of this deduped against the
    # satellite's previous session and suppressed matching new lines,
    # and resetting the board did not fix it because screen's scrollback
    # survives a board reset.  The relay's lines carry a running total
    # so they are unique per run and came through; bigread's are
    # identical every time -- "273 bytes over the radio, twice" -- and
    # were suppressed, which is exactly the measurement being chased.
    #
    # "scrollback 0" discards the buffer and the second call puts it
    # back, which is the only way screen offers to empty it.
    # A clear that PROVES it cleared -- see Board.clear().  Issued as
    # three bare "screen -X" commands with no delay this silently did
    # nothing, and two runs in a row were then read out of the previous
    # session's text.
    b.clear()
    b.reset()
    time.sleep(6 if name == "sat" else 1)
time.sleep(10)
seen = {k: set() for k, _ in ends}
KEY = re.compile(
    r"ARMV7M-STYX|styx:|rxpartial|fifoerr|rxoverflow|crcerr|status \d+ crcbad"
    r"|sent \d+ recv|state 0x|fifo rx \d+|intr high \d+|notidle \d+|idlepoll|said 0x|txskip \d+|rxkilled \d+ pendat|styx: far"
    # The received RSSI, which is what calibrates a transmit-power sweep:
    # without it ramptrial(1) reports the link budget it SET and not the
    # one the far end actually heard.
    r"|rssi -?\d+ offset|styx: core |pool (main|heap|image): live|chunks \d+ span "
    r"|no procs|smalloc|no free Blocks|panic|exceeded"
    # AND THE WORDS THE BOARD ACTUALLY USES WHEN IT RUNS OUT.  The ssl
    # arm was read for an afternoon as a kernel wedge because the one
    # message that explained it -- "exportproc 7: waiting for memory
    # (406) for request", printed in an unbounded loop beside "arena
    # too large" -- matched none of the patterns above.  A watcher that
    # filters for the failures you expect cannot report the one you do
    # not.
    r"|waiting for memory|arena too large|kstack high water"
    r"|^ *in [0-9]|^ *[0-9]+ bytes|unattributed|^pool |^  ")

t0 = time.time()
while time.time() - t0 < SECS:
    for name, b in ends:
        for ln in b.text().splitlines():
            ln = ln.strip()
            if not ln or ln in seen[name]:
                continue
            if KEY.search(ln):
                seen[name].add(ln)
                print("%6.0fs %s | %s" % (time.time()-t0, name, ln),
                      flush=True)
    time.sleep(4)

print("---")
for name, b in ends:
    t = b.text()
    for pat, label in ((r"ARMV7M-STYX-BIGREAD-(\S+)", "bigread"),
                       (r"rxpartial (\d+)", "rxpartial"),
                       (r"fifoerr (\d+)", "fifoerr"),
                       (r"sent (\d+) recv (\d+)", "sent/recv")):
        m = re.findall(pat, t)
        if m:
            print("%s %s: %s" % (name, label, m[-1]))
