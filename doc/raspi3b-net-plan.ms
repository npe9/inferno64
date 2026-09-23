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
.NH 1
Would parallelvm fix the server wedging?
.PP
It might, and the evidence to say so does not exist yet.  The one
snapshot taken of a wedged server shows several threads in
.CW acquire
\(em the Dis VM lock \(em with one in
.CW xec
running, which is what VM starvation looks like and is also what a
serialised VM looks like at any instant under any load.  Concluding
from it would be the exact mistake this document exists to stop.
.PP
.B "One measurement decides it, and it is free."
The next time the server stops answering, before restarting it:
.P1
ps -o %cpu -p `pgrep -f styxlisten`
.P2
.IP \(bu
.B "100% :"
a Dis process is spinning and holding the VM lock, everything else is
starved, and parallelvm \(em which lets executors run concurrently \(em is
exactly the right answer.
.IP \(bu
.B "0% :"
nothing is running at all, everything is asleep waiting for something
that never arrives, and parallelvm is irrelevant to it.
.PP
The one reading taken during an earlier wedge was
.B "0%, with a total of 1.03 seconds of CPU"
after hours of serving \(em which argues against starvation and so
against parallelvm being the fix.  But that was a different wedge, before
the flush bug was found, so it does not settle this one.
.PP
.B "And the cost is not small."
parallelvm lives on the
.CW multicore
branch and is 40 files and some 2700 lines across
.CW emu
and
.CW libinterp ,
including reference-counting changes in every compiler back end \(em it is
not a cherry-pick.  Adopting it to fix a diagnosis that rests on one
snapshot is the shape of the four failures already recorded here.  Take
the CPU reading first.
.NH 2
Answered: parallelvm does not fix it
.PP
It did not need a merge.  The server is only
.CW "emu -r <root>" ,
so the
.CW multicore
branch's binary can serve THIS worktree unchanged:
.P1
nohup .../multicore/MacOSX/arm64/bin/emu -r $PWD \\
	sh -c "styxlisten -A 'tcp!*!6666' export / ; sleep 2000000"
.P2
It served immediately, Rversion in 0.002s.  And it wedges in exactly the
same way: connections accepted, Tversion unread at 19 bytes, CLOSE_WAIT.
.PP
.B "The discriminator reads 0.0%,"
with 0.70 seconds of CPU total.  Nothing is spinning, so nothing is
being starved of the VM lock, so parallelvm \(em whose whole purpose is to
let executors run concurrently \(em cannot be the answer.  The theory is
retired, and the reading that retires it took one command rather than
2700 lines of merge.
.PP
.B "What the stacks show, identically on both binaries:"
.P1
exslave                       blocked
exslave                       blocked
exslave                       blocked
exreply -> ipwrite -> so_send -> osleave
rmcall  -> acquire            blocked
.P2
Every exportfs slave asleep; one that has finished a socket write and is
waiting to re-enter the VM; one waiting on the VM lock \(em and nobody
running to hold it.  A process waiting on a lock nobody holds is a lost
wakeup, but not the one this tree already knows about:
.CW emu/port/lock.c
has the release-barrier fix, byte for byte the same as inferno-rio's.
.PP
.B "One thing worth keeping from the experiment."
The multicore emu survived 60 abrupt disconnects with zero mismatches
\(em although it does NOT have the flush fix made today, and its
exportfs.c still carries the double reply
.CW "(q->flush == nil || err == nil)" .
It survives because it registers work on
.CW fs->work
in the READER, not in the worker, so the race that makes the double
reply reachable cannot happen.  That is precisely the property the
per-request-worker rewrite broke and today's change restored.  The
double reply is latent in both and should be fixed on multicore too.
.NH 1
Root cause: a process tears down while holding the VM, and blocks
.PP
.B "The detector earned itself immediately."
On the first stall after it went in:
.P1
dis: SCHEDULER STALLED: idle 0 creating 0 runhd nil handoffs 261,
     and these are waiting for the vm:
dis:    acquire 0 in acquire
.P2
.CW "idle 0"
says the VM is held.
.CW "runhd nil"
says no Dis process is on the run queue.  Those two together are
impossible in a healthy system \(em if somebody held the VM to run Dis,
their prog would be on that queue \(em so the holder is not running Dis
at all.  It is blocked.
.PP
.B "And the stack says where."
.P1
progexit -> delprog -> closepgrp -> cclose -> mntclunk
    -> mountrpc -> mountio -> Sleep -> osblock
.P2
A Dis process is exiting.
.CW progexit
takes the VM (it calls
.CW acquire
if it had released), then runs
.CW delprog ,
which closes the process group, which closes its channels, which sends a
Tclunk over a styx mount \(em and waits for the reply, holding the VM the
whole time.  Everything else in the emu then queues behind it: 0% CPU,
every exportfs slave asleep, connections accepted with their first
message unread.  It is the same outage that has been read as "the
board's network is slow" all day.
.PP
.B "This is a structural fault, not a slow peer."
Everywhere else in the VM, an operation that can block releases first
\(em that is what
.CW release()
and
.CW acquire()
are for, and dis.c calls them around exactly such paths.  Process
teardown does not, and teardown is precisely when a mount gets clunked.
Any mount whose far end is slow, busy or gone therefore stops the whole
interpreter.
.PP
.B "Not fixed here, deliberately."
The repair is to let go of the VM around the blocking part of teardown,
and
.CW delprog
also manipulates the scheduler's own lists and runs under
.CW gclock \(em
so a
.CW release()
dropped into the middle of it is not a one-line change and is not
something to attempt at the end of a long session.  It is the next
piece of work, and it now has a stack rather than a theory.
.PP
.B "What was fixed."
.CW trapUSR1
left
.CW intwait
set for any process that is not an Interp, so a kproc interrupted out of
a host syscall spun in
.CW osleave
for ever.  exportfs slaves are kprocs.  That failure mode is gone \(em
zero threads in that loop across every sample since \(em and it was a
second, independent cause of the same symptom.
