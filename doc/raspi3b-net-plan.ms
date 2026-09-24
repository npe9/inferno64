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
.NH 2
Narrowed: the accept loop recycles one conversation and one descriptor
.PP
With
.CW INFERNO_IPDEBUG=1
the healthy cycle is exactly this, and it repeats verbatim for every
connection:
.P1
conv 0 accept returns fd 4
accepted fd 4 as conv 1, owner inferno
conv 1 data opened (inuse now 2)
conv 0 accept begins on fd 3 (inuse 1)    <- listener back in accept
conv 1 closes fd 4
so_close fd 4                             <- the OLD fd closed, after
.P2
Two things to notice.  Every connection is given the SAME conversation
(1) and the same descriptor (4), because both are freed and immediately
reused.  And the close of the old descriptor happens AFTER the next
accept has already begun \(em the listener is sitting in accept(3) while
fd 4 is still open, and only then is it closed.
.PP
.B "Then it stops."
On the third connection there is no "accept returns" line, and none ever
again.  At that moment:
.P1
listener    genuinely in so_accept -> __accept on fd 3
emu owns    fd 3 and nothing else
port 6666   two connections, 19 bytes unread each, owned by no process
cpu         0.0%
.P2
.B "The shape of it."
A descriptor and a conversation are being recycled between one accept
and the next, and the teardown of the old one overlaps the start of the
new one.  That is a recycle race, and the "CLOSE UNDER ACCEPT" guard
already in devip cannot see it: that warns when a conversation is closed
while IT is accepting, and here the closing conversation (1) is never
the accepting one (0).
.PP
.B "What would settle it,"
and what this has repeatedly shown is necessary before touching
anything: record, per accept, the descriptor number accept was CALLED
with and the one it returned, and per close, the conversation and
descriptor, with a sequence number on each so the interleaving is
visible rather than inferred from the order lines happen to appear in a
log written by several processes.  The question is precisely whether the
descriptor the listener is blocked on is still the one bound to 6666.
.PP
Five server fixes are in and each was real; this is the sixth thing and
it is not the same as any of them.  What has changed is the cost of
looking: it reproduces in thirty seconds, the trace above is one
environment variable away, and the state can be read from outside with
lsof, netstat and sample.
.NH 2
Sequenced: the listener is blocked in accept on a queue that is not empty
.PP
Step 1 of the plan was to make the interleaving readable rather than
inferred from the order several processes happened to write lines.  Every
devip accept and close now carries a sequence number taken under its own
lock, the acting process, and \(em for an accept \(em the descriptor it was
CALLED with as well as the one it returned.
.PP
.B "That refutes the recycle race."
Ordered by sequence, every cycle reads:
.P1
n+0  conv 0 accept BEGINS, called with fd 3
n+1  conv 1 CLOSES fd 4
n+2  so_close fd 4
n+3  conv 0 accept RETURNS fd 4 (was called with fd 3)
n+4  accepted fd 4 as conv 1
.P2
The LISTENING descriptor is stable at fd 3 throughout; only the accepted
descriptor is recycled.  The listener is accepting on the right
descriptor, so the previous section's conclusion \(em that a recycled
descriptor was the fault \(em is withdrawn.
.PP
.B "What is left is stranger, and it is measured three ways."
At the wedge:
.P1
lldb    frame #0 __accept
        frame #1 so_accept at ipif-posix.c:239
        frame #3 namec("/net/tcp/0/listen")
trace   that accept was called with fd 3, the announced listener
netstat -L   *.6666  qlen 1/0/128, and 2/0/128 after another connect
.P2
So a thread is genuinely blocked inside
.CW accept (2)
on the listening socket, and that socket's queue of COMPLETED connections
is not empty and is growing.  Nothing consumes them.  A blocking accept
on a socket with a completed connection queued must return.
.PP
.B "The next three things to try, cheapest first."
.IP 1.
Read the descriptor from the blocked thread's registers rather than
trusting the trace, and do it WITHOUT a timeout on lldb \(em a timeout
firing while attached kills the debuggee, which happened here and
briefly looked like the server exiting on its own.
.IP 2.
Check for a second, stale accept: record every so_accept entry and exit
in a small ring with its sequence number, and see whether the count of
entries exceeds exits by more than one.
.IP 3.
Test whether the socket is still the one bound to the port, by calling
getsockname on the descriptor from inside the watchdog rather than
reasoning about it.
.PP
Everything needed to do all three is in place and the fault reproduces in
under a minute.
.NH 2
The instruments, and four hypotheses they killed
.PP
The server that stops answering has now cost more retractions than any
other fault in this tree, and every one of them came from an instrument
that could not see what it was pointed at.  What follows is what is
established, what is refuted, and what the instruments are.
.PP
.B "Established, measured, repeatable."
.IP \(bu
It reproduces under
.CW tools/jtag/wedgewatch.sh ,
which connects, attaches, opens, sends a Tread and disconnects without
waiting for the reply \(em what the board does to the host on every
reboot.  Between 11 and 92 disconnects, varying widely run to run.
.IP \(bu
At the fault: connections are ACCEPTED and their first message sits
unread \(em both a loopback probe and the board show 19 bytes, a whole
Tversion, in the socket's receive queue.
.B "It is read eventually."
Measured: a probe that the five-second check called dead was answered
34.9 seconds later, correctly, by a process that had used no CPU at all
in between.  So this is a queue, not a stop, and every description of it
as a server that has "stopped answering" is wrong.
.IP \(bu
The listening descriptor is stable and correct, the accept queue is
empty, and the listener is blocked in accept waiting for the NEXT
connection.  Nothing is wrong below emu.
.IP \(bu
The process does not die of SIGTERM.  cleanexit runs through the Dis VM,
so whatever has stopped the VM stops the exit too.
.IP \(bu
It RECOVERS.  A server declared wedged has repeatedly answered normally
a minute later.
.PP
.B "Refuted, each after being believed."
.IP 1.
.I "A recycled listening descriptor."
Sequence-numbered accepts show the listener is always called with the
announced descriptor; only the accepted one is recycled.
.IP 2.
.I "A stopped mount multiplexer."
mntwatch has never once reported a stopped mux \(em but see below: for a
round of measurements its silence was worthless, because it printed only
on the fault and so could not be distinguished from a watcher that never
started.
.IP 3.
.I "sys->export failing silently."
It returns \-1 from two places and styxlisten ignored the result, which
would leave exactly this symptom.  Both now report; neither has fired.
.IP 4.
.I "A worker blocked writing to a client that stopped reading."
Caught red-handed in a sample:
.CW "exworker -> exdispatch -> exreply -> ipwrite -> so_send -> write" ,
blocked for a whole three-second sample.  It is real and worth fixing on
its own.  It is NOT the cause: with every instrument on at once the
fault reproduced at 92 disconnects with no write stuck for two seconds,
no mux stopped, and the reader never once serving a request inline.
.PP
.B "The instruments, and what each one is for."
.IP "\fIprogwatch\fP (INFERNO_PROGWATCH=<seconds>)"
prints what /prog would say \(em the Dis processes, their state and
module \(em for a server that cannot be asked, because reaching its
/prog needs the Styx connection that is the thing not working.
.IP "\fImntwatch\fP (INFERNO_MNTWATCH=1)"
reports a mount mux whose queue, reader and tags have not changed for
three scans, and TICKS every scan when nothing is wrong.
.IP "\fIexportfs write records\fP"
name a write that is still stuck, while it is stuck, and say whether the
far end is a socket or the pipe.
.PP
.B "Three rules this fault has taught, at cost."
.IP 1.
.I "An instrument that prints only on the fault has no positive control."
Its silence then means either "all is well" or "I never started", and
those are not the same sentence.  mntwatch ticks now.
.IP 2.
.I "A five-second probe is not a verdict."
wedgewatch now asks whether the process burns CPU, whether its CPU time
moves at all, and whether a patient sixty-second probe gets an answer,
and prints STOPPED or SLOW.
.IP 3.
.I "lldb attach kills this emu."
Twice.  The first time it looked like the server exiting on its own and
was very nearly written down as a finding.  Use
.CW sample ,
and re-parse its whole stack \(em truncating to the last three frames
threw away the one frame that tells an idle worker from a blocked one,
and an assertion was built on the difference.
.NH 2
It is not a wedge.  It is one Styx hop, shared by everybody
.PP
The five-second probe was the whole illusion.  Given a verdict instead
of a timeout, the same fault reads:
.P1
=== short probe (5s) failed after 94 abrupt disconnects
cpu 0:06.85 -> 0:06.85 over 5s, %cpu 0.0
  it is IDLE (no cpu time at all in 5s)
VERDICT: SLOW, not stopped -- answered in 34.90s
.P2
and every instrument agrees, in that one run, on a fresh binary:
.CW "mntwatch: 1 mounts"
every scan and never a stopped mux; exactly one
.CW Styxlisten
exportproc alive at a time with its pid advancing; no write stuck for
two seconds; the reader never serving a request inline; no export
failure.  Nothing is broken.  Everything is queued.
.PP
.B "This is the architecture, and it was already written down."
styxlisten runs
.CW "export /"
ONCE and gives every connection a mount of that same pipe, so every byte
every client reads crosses one Styx hop that all of them share.  The
comment in
.CW tools/jtag/styxd.sh
records the same effect measured small: with one board pulling a kernel
across, a new client's handshake went from 0.01s to 1.23s, and 0.03s
with a server per connection.  Ninety-four abrupt disconnects and a
board polling is the same mechanism with more load, and 35 seconds is
where that queue's tail landed.
.PP
So the thing to fix is not a hang.  It is that one client's traffic
delays every other client's, without bound, by design.
.NH 2
What is still worth fixing, listed honestly
.IP 1.
.I "The shared hop."
.CW "styxlisten -P n"
already builds a bounded pool of servers for exactly this and is the
measurement to run next: if serialization is the cause, four servers
should cut the tail about fourfold.  Per-connection servers are NOT the
answer \(em they are never reclaimed, and a board dialling every fifteen
seconds took the emu to 139 threads.
.IP 2.
.I "exreply's unbounded write."
Against a client that stopped reading it blocks with no timeout, holding
a worker \(em and the reader itself when the worker caps are full.  Real,
reproducible, and independent of the above.  Caught in a sample as
.CW "exworker -> exdispatch -> exreply -> ipwrite -> so_send -> write" .
.IP 3.
.I "Not by raising Maxconnproc."
exportfs.c records that 4 is a CORRECTNESS bound, not merely a resource
one: the redesign faulted on a nil dereference at 4 and not at 1.  That
audit comes first.
.NH 2
Latency as a distribution, and what it does to the shared-hop story
.PP
Measured with
.CW tools/jtag/styxlat.py ,
which reports a distribution and names which step failed \(em connect,
send or reply \(em rather than answering yes or no:
.P1
idle                40 samples, 40 answered, 0 failed
                    median 0.001s  p90 0.011s  max 0.016s
board cadence       probes at 0.011s, 0.007s, 0.002s on a fresh server
under the hammer    short probe fails; the patient probe has come back
                    at 0.02s, 0.77s, 2.07s, 34.90s and 45.91s
.P2
An idle server answers in a millisecond and a board-paced one in
single-digit milliseconds.  Whatever this is, it is not present until
connections churn.
.PP
.B "The shared-hop explanation is NOT established, and the previous
section overstated it."
One A/B trial of
.CW "styxlisten -P 4"
against the shared default gave 112 disconnects to failure shared and
98 with the pool \(em if anything slightly worse, certainly not the
fourfold improvement four independent hops should give if queueing on
one hop were the cause.  One trial is not a result either, but it is
enough to stop asserting the conclusion.
.PP
The 0.02s patient answer is the sharper objection to it.  A server that
answers a fresh connection in twenty milliseconds was never busy; that
probe failed at
.I connect ,
not at reply, and a connect failure has nothing to do with the shared
pipe.  So the "failures" counted under the hammer are at least two
different events with two different mechanisms, and attributing the
common one's frequency to the rare one's mechanism is how the last three
wrong answers were reached.
.NH 2
What the fault looks like at LOW load, which is the case that matters
.PP
The board dials once every fifteen seconds.  Measured: one accept in
twenty seconds, 0.05/s.  A run of
.CW styxabrupt.py
is one connection, and the hammer does about a hundred as fast as python
manages \(em two orders of magnitude more than the board, and a load
generator that produces a failure the board cannot produce will keep
pointing away from the board's problem.
.PP
.B "It reproduces at 0.7 connections per second."
With one probe every 1.5 seconds and an abrupt disconnect every 15, a
server forty-one seconds old reached a state where a fresh connection
completed in ONE MILLISECOND and then got no Styx reply in ten seconds,
with five connections \(em four loopback and the board \(em each holding
an unread nineteen-byte Tversion, and the process at 0% CPU.
.PP
At that moment, from a sample: exactly one exportfs exists and it is the
pipe's; the listener is in accept; and the Dis scheduler has NOTHING
ready to run.  The threads parked in
.CW iyield
are not processes waiting for the VM \(em iyield parks the OUTGOING VM
thread after handing over, so those are the idle pool.  Nothing wants to
run, and five connections are waiting to be served.
.PP
That combination is the whole remaining question, and these are ruled
out as its cause: a recycled listening descriptor; a stopped mount
multiplexer; sys->export failing; a blocked reply write; and
conversation exhaustion in devip, which never grew and never printed
EXHAUSTED.
.NH 2
Both states are real, and the second one is the fault
.PP
.B "Correction."
The section above says the listen queue stays empty and that the server
is slow rather than stopped.  Measured with
.CW "netstat -anL" ,
which is the invocation that prints it, that is wrong, and both halves
of it are wrong in the same direction.
.PP
There are two states, not one:
.IP "ISLOWP"
the patient probe comes back in 0.02s to 45.91s, the listen queue is
.CW 0/0/128 ,
and the server recovers by itself.  A queue with a long tail.
.IP "ISTOPPEDP"
no answer in sixty seconds, CPU frozen to the hundredth of a second, the
stall persisting through minutes of probing, and the listen queue at
.CW 3/0/128 .
Connecting one more client took it to
.CW 4/0/128 .
.B "accept is not consuming."
.PP
The second is the fault.  The first is a queue and may well be nothing
but load.
.NH 2
The scheduler has handed the VM to nobody
.PP
In the STOPPED state, from the scheduler's own state rather than a
stack:
.P1
progwatch: 5 dis processes, 0 idle, runhd nil
progwatch:    1 release Sleep      3 release Sh
progwatch:    4 release Dial       5 release Export
progwatch: 5285 release Styxlisten
.P2
Every Dis process is in state
.I release
\(em each has given up the VM to make a kernel call \(em
.CW runhd
is nil, and
.CW idle
is 0, meaning the scheduler believes some thread holds the VM.  From a
sample of the same live process: no host thread is running
.CW vmachine
at all.  Three threads are parked in
.CW iyield
on idlevmq, one is parked in
.CW acquire
on its semaphore, and the listener \(em which had been in accept \(em is
now among them.  It never calls accept again, which is why the queue
grows.
.PP
So the VM was handed to somebody who never woke, and every process is
waiting for a VM that nobody is running.
.PP
.B "vmwatch cannot see this,"
because it fires only when
.CW "isched.vmq != nil" ,
and the waiter has already been taken off that queue and signalled.  Its
silence through every stall was never evidence of anything \(em the same
mistake as mntwatch's, made twice in one session.  progwatch now prints
.CW holder ,
.CW vmq ,
.CW idlevmq ,
.CW creating
and the handoff counter, because which of those is wrong cannot be
inferred from outside and inferring it is what produced the last four
wrong answers.
.NH 2
It was App Nap.  macOS was suspending the emulator
.PP
.CW emu
links Cocoa and creates an
.CW NSApplication
even when it is serving Styx from a terminal with no window on screen.
To macOS that is an app doing nothing visible in the background, and App
Nap suspends the whole task.
.PP
.B "The tell, which was in every sample from the beginning."
Watchdog kprocs whose only job is a three-second
.CW nanosleep
had not fired for three and a half minutes.  Nothing inside a process
can stop an independent timer.  Only the OS declining to schedule the
process can.  Every stack in every sample was simply where each thread
happened to be when the process was frozen, which is why they never
agreed on a culprit and why four different subsystems each looked guilty
in turn.
.PP
.B "What it looks like from outside,"
and why it was mistaken for six different bugs: connections complete
their handshake in the kernel and queue on the listen socket while the
application never accepts, so
.CW "netstat -anL"
climbs 1/0/128, 2/0/128, 3/0/128 \(em and 4/0/128 the moment another
client is added; a Styx handshake goes unanswered for a minute or more;
CPU time is frozen; SIGTERM is ignored, because the handler never runs;
and then it recovers completely, with no explanation.
.PP
.B "Two rival explanations, both killed by measurement."
.IP 1.
.I "The machine idle-sleeping."
It did not.
.CW kern.sleeptime
and
.CW kern.waketime
are from the previous afternoon, the total sleeps since boot is four,
and
.CW PreventUserIdleSystemSleep
was asserted continuously across the whole window.
.IP 2.
.I "A Dis scheduler deadlock."
It is not: progwatch is a kproc that touches nothing the scheduler owns,
and it stopped too.  The scheduler state that looked so damning \(em
.CW "idle 0, runhd nil" ,
every process in
.I release ,
the holder asleep in the idle
.CW Sleep
\(em is just the last state before the freeze, printed by the last scan
that ran.
.PP
.B "The fix"
is one call in
.CW main-cocoa.m :
.P1
[[NSProcessInfo processInfo] beginActivityWithOptions:
    NSActivityUserInitiatedAllowingIdleSystemSleep
    reason:@"Inferno is an operating system; ..."];
.P2
AllowingIdleSystemSleep deliberately: that says "do not nap me", not
"keep the machine awake".  An emulator has no business holding
somebody's laptop out of sleep.
.PP
.B Measured.
Eleven runs of
.CW tools/jtag/wedgewatch.sh
against the previous binary failed, at 11, 21, 45, 65, 69, 71, 73, 82,
92, 112 and 115 abrupt disconnects.  The first run with the change
survived 400 and kept answering, with an empty listen queue and six
times the CPU time \(em a process that was running rather than
suspended.
.PP
.CW "taskpolicy -B"
on the live process is NOT the fix and was not evidence for the
diagnosis either: applied every two seconds it still froze at 82.  A
single application of it appeared to drain the accept queue, but that is
indistinguishable from any other command running at that moment, and it
was nearly written down as proof.
