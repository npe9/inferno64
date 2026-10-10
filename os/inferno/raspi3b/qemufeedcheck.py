#!/usr/bin/env python3
# Judge a qemufeed run.  See qemufeed.sh for why this is a SEQUENCING
# check and not a text-integrity one.
#
# After every command qemufeed feeds `echo QF'-'STEP-n', whose output is
# QF-STEP-n.  The marker is SPLIT in the command so the console echo of
# the command cannot satisfy the search -- otherwise every step would
# "pass" the moment it was typed rather than when it ran.
#
# The shell consumes its input in order, so QF-STEP-n in the log proves
# the shell reached step n.  The first missing marker is where the run
# stopped, and that is the failure that matters: a run that dies early
# produces a log full of plausible output and answers nothing.  It is
# how a V3D question was once reported as "timed out on the V3D read"
# when it had died during attach, before its first control.
#
# WHAT THIS DOES NOT CHECK: that each command's TEXT arrived intact.
# The console interleaves kernel output into the echo, mid-line and
# without a newline, so the echo cannot be compared character for
# character; and a subsequence test over a whole log is satisfied by
# almost any short string, so it cannot stand in either.  When text
# integrity matters, put the commands in board.cmd as a file, where
# nothing retypes them.
import sys

cmds, logf = sys.argv[1], sys.argv[2]
log = open(logf, errors='replace').read()
want = int(sys.argv[3]) if len(sys.argv) > 3 else 0

reached = 0
missing = []
for n in range(1, want + 1):
    if ("QF-STEP-%d" % n) in log:
        reached += 1
    else:
        missing.append(n)
print("qemufeed: %d of %d steps reached" % (reached, want))
if missing:
    print("qemufeed: first step not reached: %d (of %d)"
          % (missing[0], want), file=sys.stderr)
    sys.exit(1)
sys.exit(0)
