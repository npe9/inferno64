.TL
The Pi 3B's network latency: a plan to evaluate, then fix
.AU
.PP
The board pings in 6.4ms and reads a file over styx at about 50KB/s.
This machine reads the same file from the same server in under half a
second.  Four attempts to fix it in one afternoon all made it worse and
were all reverted.  This is what to do instead, and \(em because the four
failures were as much a failure of measurement as of engineering \(em the
measuring comes first.
.NH 1
What is actually known
.PP
Only two things survive repetition.  A round trip carrying one Ethernet
frame costs 6.4ms, and each additional frame costs about 4.6ms:
.P1
             round 1   round 2   round 3
1400B  (1 frame)  6.32ms    6.43ms    6.55ms
8000B  (6 frames) 28.8ms    29.9ms    29.3ms
.P2
Those minima are stable to a tenth of a millisecond across separate
rounds.  Nothing else is.  The AVERAGES of the same measurements ranged
from 15ms to 87ms across one afternoon, and a single measurement of
"100% loss at eleven frames" \(em which an entire argument was built on
\(em did not reproduce even once when it was finally repeated.
.PP
Everything else in this area is currently belief, including the belief
that the receive path is where the time goes.  All four failed fixes
assumed that.
.NH 1
Phase 0: an instrument that can be trusted
.PP
Nothing else in this plan is worth doing first.  Four changes were
evaluated against single samples and one of them (four posted receive
transfers) was declared "the worst" on a measurement that also happened
to lose eleven of twelve pings \(em which may have been the change or may
have been the board having a bad minute, and there is no way to tell
now.
.PP
.B "Build" \f(CWtools/jtag/netbench\fP.
It must:
.IP \(bu
report a DISTRIBUTION \(em min, median, p90, max, and the count \(em never
a bare average, because the average is the statistic that misled this
work all afternoon;
.IP \(bu
repeat every point N times and report the spread BETWEEN repeats as
well as within them, so that "this changed" can be distinguished from
"this is noisy";
.IP \(bu
refuse to report at all if a precondition fails: the host's styx
handshake must answer in under a second (\f(CWstyxd.sh\fP already tests
this), the board must answer a one-frame ping, and the traces must be
off \(em a server with \f(CWINFERNO_MNTDEBUG\fP set is thirty times slower
and looks exactly like the fault being hunted;
.IP \(bu
record the kernel build stamp it measured, so a number can never be
attributed to the wrong build.
.PP
.B "Acceptance for phase 0:"
the same build, measured twice with a reboot in between, produces
medians within 10% of each other.  Until that holds, no change should
be evaluated at all.
.NH 1
Phase 1: is it receive or transmit?
.PP
This is the question that makes the difference, and it has never been
asked.  An ICMP echo of 8000 bytes is six frames IN and six frames OUT,
so the 4.6ms per frame covers both directions and says nothing about
which one it is.  Every fix so far has been in
.CW rxproc .
.PP
.B "The experiment."
A styx read is a small request and a large reply \(em one frame out, six
in.  A styx write is the reverse.  So read 1MB from
.CW /n/remote
and write 1MB to it, same size, same connection, and compare bytes per
second.
.P1
read  much faster than write  ->  the cost is TRANSMIT
write much faster than read   ->  the cost is RECEIVE
neither                       ->  it is per-frame on both paths
.P2
.B "Why transmit is the better first guess."
The SMSC chip packs many frames into one USB transfer on receive:
Burstcap is 37 512-byte packets, so 18.9KB, and six frames should
arrive in ONE transfer.  If the cost were receive-side and per-transfer,
it would not scale with the frame count \(em and it does, linearly.  The
transmit path has no such packing: an IP datagram fragmented into six
frames is plausibly six writes to the bulk-out endpoint, each waiting
for its own completion.  Six times a four millisecond completion is the
entire measured cost.
.NH 1
Phase 2: locate the per-frame cost with counters, not prints
.PP
Prints cannot be used here.  The lesson is already paid for: tracing the
styx server made it thirty times slower, and any instrumentation in a
path costing 4.6ms per frame will move what it measures.
.PP
.B "Add counters, sample them from outside."
In
.CW usbdwc
and
.CW etherusb ,
accumulate and expose through an existing ctl or status file:
.IP \(bu
bulk-in transfers completed, and bytes delivered by them.
.I "Frames per transfer is the number that decides everything."
If it is about one, the chip is not bursting and that alone is the bug;
if it is six, receive is already efficient and phase 1's answer will be
"transmit".
.IP \(bu
bulk-out transfers issued, and bytes.  Same question for the reply
path: one transfer per fragment, or one per datagram?
.IP \(bu
microseconds accumulated waiting for completion, in and out separately.
That is the quantity the 4.6ms is made of, and it should be attributable
to one of the two directions.
.PP
Sample before and after a fixed workload \(em 1MB read, then 1MB written
\(em and divide.  No timing is printed during the run.
.NH 1
Phase 3: candidate fixes, each with a prediction that can fail
.PP
Not one of these should be attempted before phase 2 says which applies.
Each is written with the measurement that would falsify it.
.IP 1.
.I "If receive delivers ~1 frame per transfer:"
the chip's burst mode is not working.  Check that Bir and Burstcap are
actually set (\f(CWsmscsetup\fP writes them), that the read size posted is
at least Burstcap*512, and that the chip is not being told to terminate
early.  Falsified if frames per transfer stays at 1 with all three
confirmed correct.
.IP 2.
.I "If transmit issues one transfer per fragment:"
the reply to a six-fragment datagram costs six completions.  Either
hand the whole datagram to the endpoint in one write, or stop
fragmenting \(em the second is cheaper to try and easy to measure,
because a styx message that fits one frame needs no fragments at all.
Falsified if collapsing six writes into one does not move the 8000-byte
minimum.
.IP 3.
.I "If the time is in the completion wait itself:"
usbdwc's channel wait has a re-arm watchdog and a sleep, and a transfer
that completes on its interrupt should not be paying either.  Compare
the accumulated wait microseconds against the transfer count: if the
mean wait is milliseconds for a transfer whose wire time is
microseconds, the completion is arriving late, not the data.
.PP
.B "Do not retry these."
All four were measured worse and reverted, and the reasons are
recorded in
.CW doc/raspi3b-completion-plan.ms :
64KB Styx messages (\f(CWls\fP: "stat buffer too small"); adaptive backoff
in rxproc with a yield (ping better, real work twice as slow, the yield
starves the VM); the same with a 1ms sleep (within noise, one run in
three took 200s); and four receive transfers kept posted (worst of the
four \(em the SMSC bulk-in stream is a packed sequence of status-prefixed
frames per transfer and concurrent transfers do not survive it).
.NH 1
Phase 4: acceptance, fixed in advance
.PP
Written down before any change, so that a result cannot be graded
after the fact:
.IP \(bu
1MB read from /n/remote: median of five runs, across two separate
boots, at least 3x better than the baseline that phase 0 establishes;
.IP \(bu
the one-frame ping minimum not worse than 6.4ms \(em several of the
failed attempts traded this away;
.IP \(bu
no packet loss at any frame count from 1 to 11, measured as three runs
of fifteen;
.IP \(bu
the kernel update completes with KU-CMP and KU-VERIFY both clean, which
is the only end-to-end test that exercises the whole path;
.IP \(bu
and each change measured ALONE.  Two of the four failures were
evaluated with another change still in the tree.
