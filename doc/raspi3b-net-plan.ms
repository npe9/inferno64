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
.NH 2
Correction, and the actual fix
.PP
.B "Retracted: delprog is not the problem."
The section above says a process tears down while holding the VM and
blocks on a clunk.
.CW delprog
already does exactly the right thing:
.P1
o = p->osenv;
release();
closepgrp(o->pgrp);
closefgrp(o->fgrp);
closeegrp(o->egrp);
closesigs(o->sigs);
acquire();
.P2
It drops the VM around the blocking closes.  The stack that seemed to
show otherwise occupied 173 samples of a 1775-sample window \(em about a
tenth, a thread passing through \(em and was read as if it were stuck.
Twice now a sampling profile has been turned into a root cause by
looking at one stack and not at its count.
.PP
.B "The instrument was wrong too."
The stall detector counted handoffs only in
.CW acquire() ,
and the VM is also handed on by
.CW iyield()
and by the idlevmq path in
.CW release() ,
neither of which goes through it.  A busy server could therefore show
the counter frozen and be reported as stalled.  Handoffs are now counted
wherever a thread resumes the VM.  Its
.CW holder
field is still racy \(em it is cleared only if it still names the caller,
so a stale pointer survives a close handoff \(em and should be read as a
hint, not as evidence.
.PP
.B "The fix:" \f(CWacquire()\fP "woke the idle VM thread only when it was the first to queue."
.P1
if(empty)
	Wakeup(&isched.irend);
.P2
That encodes "if somebody else is already on vmq, the VM thread has
already been told", and
.CW iyield()
breaks it: iyield takes a waiter off vmq and hands it the VM directly,
then parks itself on idlevmq, so the VM thread is no longer the one
asleep on irend.  A process queueing after that finds vmq non-empty,
skips the wakeup, and waits for a nudge that never comes.  A Wakeup on a
Rendez with nobody sleeping on it does nothing, so the condition bought
nothing and cost the hang.  It is unconditional now.
.PP
.B "Measured, same driver either side:"
.P1
before   rounds 3, 7 and 8 of ten timed out at 15s; stall reported
after    30 rounds, 0 timeouts, all under 1.05s, most under 0.2s
         100 abrupt disconnects survived, worst health 0.54s
.P2
One stall was still reported during the thirty, with no timeout beside
it and the racy holder field naming a process that had already handed
the VM on \(em so it is most likely the detector, not the VM.  Said here
rather than left out.
.PP
The latencies are better but not good: seconds still appear.  That is
the remaining work, and it is now a performance question rather than a
hang.
.NH 2
One shared server made every client queue behind the busiest
.PP
.B "The shape."
.CW styxlisten
runs its command ONCE and gives every connection a mount of that one
pipe, so every byte any client reads crosses a single styx hop that all
of them share:
.P1
board -> TCP -> its exportfs -> mount -> ONE pipe -> ONE `export /'
.P2
A new client's mount is a handful of small messages, and it queues
behind megabytes of somebody else's.  Measured with the board reading a
kernel in the background, twelve handshakes each:
.P1
shared            0.01 0.06 0.11 0.31 0.11 0.41 0.99 1.23 ... worst 1.23s
per connection    0.00 0.01 0.02 0.00 0.03 0.01 0.03 0.02 ... worst 0.03s
.P2
Forty times better at the worst, and the spread is gone.
.PP
.CW "styxlisten -P"
starts the command once per connection instead.  It is a flag rather
than the default because it only means the same thing for a command that
serves a namespace, as
.CW "export /"
does; for a command holding state that clients are meant to share, one
per connection is a different program.
.CW styxd.sh
passes it by default, where the command is always
.CW "export /" .
.PP
.B "It does NOT make the board faster, and the first measurement said it did."
One 1MB read came back in 4s against the usual 23s, which looked like a
result.  Repeated: 4s, 30s, 30s.  The 4s was an outlier and throughput is
unchanged.  What changed is isolation between connections, which is a
different and smaller claim than the one the first sample invited \(em the
third time in this document that a single measurement has had to be
withdrawn.
.PP
Board throughput remains about 30s for 1MB, which the frame-count
measurements already explain: 6.4ms for a round trip carrying one
Ethernet frame and 4.6ms for each frame after it.  That is the board's
network path, not the server, and it is still the open item.
.NH 2
A connection pool, and why it does not help here
.PP
The obvious middle ground between one shared server (everyone queues)
and one per connection (nothing is ever reclaimed) is a bounded pool,
made once and handed out round robin \(em which is what
.CW "styxlisten -P n"
now does.  It is bounded, as intended:
.P1
threads at start, pool of 4        21
threads after 12 connections       22
handshakes, idle                   all under 0.01s
.P2
against 139 threads and climbing for one-per-connection.  And under the
board's load it is the worst of the three:
.P1
shared             worst 1.23s
per connection     worst 0.03s   (but leaks a server per connection)
pool of 4          two TIMEOUTS, several at 13-14s
.P2
.B "Because the VM is serialised."
This branch has no
.CW parallelvm ,
so
.CW acquire / release
in dis.c pass a single token and one Dis process runs at a time.  Four
server processes therefore do not serve four clients at once; they add
scheduler churn \(em more processes, more handoffs, each syscall a
release and an acquire \(em without adding any concurrency to pay for it.
A pool is the right structure for this problem and the wrong one for
this interpreter.
.PP
That is also the honest answer to "would parallelvm help": not for the
wedge, which was measured and is fixed, but THIS is where it would \(em
a pool needs real concurrency to be worth its overhead.  The default
stays one shared server, and
.CW "-P n"
stays as a flag with this measurement written next to it.
.NH 2
Phase 1 is NOT answered, and nearly was
.PP
A styx read is one frame out and six in; a write is the reverse, so
comparing them should say which direction costs.  The first four samples
looked decisive \(em 512KB read in 2s and 82s against writes of 164s and
149s \(em and "transmit is the expensive direction" was written down.
Then the rest of the run arrived:
.P1
1MB read     70s  214s   78s
1MB write   364s  208s    6s
512KB read    2s   82s
512KB write 164s  149s
.P2
A six second write and a two second read sit in the same data as a 364
second write.  Both directions span two orders of magnitude, the
distributions overlap completely, and nothing can be concluded from
them.  They were also taken while the server design was being changed
underneath them, which on its own disqualifies the lot.
.PP
So phase 1 stands open, and the reason to write its answer down before
taking it \(em which the plan says to do \(em is exactly this: four samples
in, the wrong answer was already on the page.
.PP
What is needed is phase 2: counters in the driver, sampled from outside
across a fixed workload, counting transfers and bytes in each direction.
No timing in the path, nothing printed during the run, and the frames
per transfer computed rather than inferred.  Nothing in the transmit
path should be touched until that exists.
.NH 2
The pool on parallelvm: it works, and it turns out to be unnecessary
.PP
No merge was needed to try it.  The emu binary and the root are
independent, and
.CW styxlisten.dis
comes from the root \(em so the multicore branch's emu serving this
worktree is already running the pooled styxlisten.
.CW styxd.sh
takes
.CW EMU
now for exactly this.
.PP
.B "First, the two scheduler fixes had to go over."
multicore had both of them unchanged: the
.CW "if(empty)"
guard on the irend wakeup, and
.CW trapUSR1
returning without clearing
.CW intwait .
Testing anything there without them measures those.  Its own comment
above
.CW acquire()
already asserts the invariant the first fix restores \(em "every writer of
vmq calls Wakeup(&isched.irend) after dropping isched.l" \(em so the
reasoning on that branch was right and only the code disagreed, which is
independent confirmation of the fix.  Committed there as 54cce5c9.
.PP
.B "Then the measurement, with the board reading in the background:"
.P1
serial VM,   shared            worst 1.23s
serial VM,   per connection    worst 0.03s, and 139 threads climbing
serial VM,   pool of 4         two TIMEOUTS, several 13-14s
parallelvm unfixed, pool of 4  five TIMEOUTS
parallelvm + fixes, pool of 4  worst 0.01s, 21 threads, bounded
parallelvm + fixes, SHARED     worst 0.01s
.P2
.B "The last line is the point."
Shared is just as good as pooled once the VM is parallel and the two
bugs are gone, so the pool contributes nothing on top and should stay a
flag, off by default, on both branches.  What fixes the queueing is
parallelvm plus those fixes \(em not the pool.  The pool was the right
idea for a real bottleneck; the bottleneck was somewhere else.
.PP
.B "One caveat, stated rather than buried."
The multicore server wedged later in the same session \(em handshake
timing out, 0% CPU \(em so those numbers come from a window before it
did.  That branch still lacks this one's exportfs work: the flushed
request answered twice, the fs->work registration moved back into the
reader, and mntfree retiring the tag of an abandoned rpc.  The isolation
result is solid; "multicore is stable" is not claimed and is not true
yet.
.PP
Board throughput did not move: 1MB still takes tens of seconds whichever
emu serves it.  That was never a server problem, and the frame-count
measurements say why.
.NH 1
The server still wedges, and now it does so in twenty seconds
.PP
Five fixes in \(em the flushed request answered twice, the fs->work
registration, mntfree retiring an abandoned tag, trapUSR1 clearing
intwait, the unconditional irend wakeup \(em and it still stops
answering.  The one gain that matters for finding the rest is that it
now reproduces in twenty seconds of board traffic rather than hours.
.PP
.B "The state, captured whole."
.P1
listener            in accept(), Sys_open -> ipopen -> so_accept
LISTEN socket       accept queue EMPTY (rq 0)
one exportfs        blocked in exreadn on a connection whose
                    descriptor emu does not hold
board's connection  ESTABLISHED on 6666, 19 bytes unread, NO owning fd
emu's descriptors   fd 3, the listener, and nothing else
cpu                 0.0%
vmwatch             did not fire, correctly: nothing queued for the VM
devip               no exhaustion, no "CLOSE UNDER ACCEPT", no errors
.P2
.B "Two things there cannot both be true."
A connection is ESTABLISHED on the port with data waiting and no process
owning it, while the listening socket's accept queue is empty and the
listener sits in accept().  Either it was accepted \(em and then its
descriptor went without the socket being closed, which does not happen
\(em or it was never accepted, and the kernel should be showing it queued.
.PP
.B "And an exportfs is reading a descriptor that is gone."
That read cannot return.  Whatever closed the connection's fd left its
server blocked on the chan, which is a second, independent way for a
connection to be accepted and never served.
.PP
.B "What was ruled out here, with the evidence:"
.IP \(bu
not VM starvation \(em 0% CPU, and the stall detector is silent because
nothing is queued;
.IP \(bu
not the flush desync \(em zero mismatches in the log;
.IP \(bu
not intwait \(em zero threads in the osleave spin;
.IP \(bu
not conversation exhaustion \(em protoclone prints that unconditionally
and did not;
.IP \(bu
not parallelvm \(em the multicore emu does the same thing, measured.
.PP
.B "Next, and only with the instrument first."
.CW "styxlisten -T"
prints a line for every connection that reaches
.CW sys->export ,
and in the run that wedged, five connections did and all set up in under
11ms.  So they are built correctly and then lost.  What is missing is a
line where a connection's server EXITS, and why: the next step is to say
so in
.CW exportproc ,
and to record which chan an exportfs is reading so that "reading a
descriptor emu does not hold" can be turned from an inference into a
name.
