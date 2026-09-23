.TL
exportfs: a better way to dispatch connections
.AU
.SH
Priority
.PP
.B "This is a first-class piece of work, not a side quest."
Every emu in this tree serves files through
.CW exportfs ,
so the 1700-fold latency improvement measured below is not a Pi 3B
detail \(em it is the file service every hosted Inferno on this
machine depends on.  On the board it is the difference between
kupdate appearing to hang and kupdate working, and it cost a day of
misdiagnosis before it was even localised.
.PP
It gets whatever it needs: a dedicated diagnosis plan
(doc/emu-exportfs-nil-plan.ms), a measurement harness that proves its
own load, sanitizer work on emu's pool allocator if that is what the
remaining bug takes, and as many board and host runs as the numbers
require.  Nothing here is to be left at "probably fine" \(em the one
reference-counting bug between this and shipping is worth however long
it takes, because what is behind it is a server that answers in
milliseconds instead of a minute.
.NH 1
The measurement that motivates this
.PP
A new connection to an
.CW emu
serving a tree over styx takes, while three clients read from it:
.P1
no load:        max  0.01s
three readers:  median 0.01s  p90 37.00s  max 82.53s
.P2
Nothing is wedged \(em every connection is eventually answered \(em but
a median of 10ms with a maximum of 82 seconds is not a server, it is a
lottery.  On the Pi 3B it shows up as
.I kupdate
appearing to hang, and it cost most of a day being chased as a hang
rather than as a latency tail.
.NH 1
What the current design is, and its four faults
.PP
.CW styxlisten
accepts a connection and spawns an
.CW exportproc
for it.  That process reads one Styx message at a time and puts it on
.CW exq
\(em ONE global queue, shared by every connection in the emu.
.CW exslave
processes take work off it.
.IP 1.
.B "One queue for every connection."
A new connection's Tversion goes behind every message already queued
by every other client.  There is no isolation at all: one busy reader
sets the latency for everyone.
.IP 2.
.B "Dispatch is a convoy through one qlock."
A slave must hold
.CW exq.qwait
to look for work, and the IDLE slave holds it while sleeping on
.CW exq.rwait .
So at most one slave is listening at any moment and every dispatch is
a lock handoff.  Adding slaves adds contention, not throughput.
.IP 3.
.B "The spawn heuristic is inverted."
.P1
if(exq.qwait.head == nil)
        kproc("exslave", exslave, nil, 0);
.P2
An idle slave HOLDS
.CW qwait
and queues nobody, so
.CW head
is nil and a new slave is spawned although one is already idle.  When
several slaves are genuinely contending,
.CW head
is not nil and it declines to spawn \(em which is when capacity might
actually help.  Sixteen blocked slave threads were counted on a server
with three clients.
.IP 4.
.B "No bound and no backpressure."
Nothing limits the number of slaves, the depth of the queue, or the
work one connection may have outstanding.
.NH 1
The design
.PP
.B "Per-connection queues, per-connection workers, global bounds."
The unit of fairness should be the connection, because that is the
unit a client experiences.  Concretely:
.IP \(bu
the work queue moves from the global
.CW exq
into
.CW Export ,
so each connection has its own FIFO and its own rendezvous;
.IP \(bu
a connection spawns a worker when it has queued work and fewer than
.CW Maxconnproc
of its own are running \(em four is a sensible start, since Styx
clients rarely keep more outstanding \(em subject to a global cap
.CW Maxproc
so one client cannot exhaust the emu;
.IP \(bu
workers wait on their OWN connection's rendezvous.  No global lock is
taken to find work, so there is no convoy and no single point every
dispatch must pass;
.IP \(bu
an idle worker lingers briefly and then exits, so a quiet connection
costs nothing and a busy one keeps its workers hot;
.IP \(bu
the spawn decision counts what it means: workers idle on THIS
connection, not processes queued on a lock.
.PP
This is the shape every modern server converges on \(em per-connection
state with bounded concurrency \(em and it is what the original design
was reaching for with one queue and a heuristic.
.NH 1
What Go does, and why it points somewhere simpler
.PP
Go's answer to this problem is to not have a pool.  The canonical
server is
.P1
for { c, _ := l.Accept(); go serve(c) }
.P2
with another goroutine per request where the protocol allows
concurrent requests \(em which 9P does, through tags.  The application
never sizes a worker set, because the runtime does that job: cheap
growable stacks, and an M:N scheduler that multiplexes goroutines onto
GOMAXPROCS threads.  The thing exportfs hand-rolls is exactly what Go
pushed down into the runtime so no application has to get the
heuristic right.
.PP
Three of its choices bear directly on the faults above.
.IP \(bu
.B "Per-P run queues, not one global queue."
A processor takes work from its own queue first, then STEALS from
others, and only checks the global queue every 61 ticks \(em and that
periodic check exists precisely to stop globally-queued work
starving.  Fault 1 and fault 2 are that principle stated as a bug: a
single queue behind a single lock on the dispatch path is a latency
tail generator.
.IP \(bu
.B "A blocking syscall does not consume a slot."
The runtime hands the P to another thread so other goroutines keep
running.  In exportfs a slave blocked in a slow read is a slave
serving nobody, and the pool shrinks under exactly the load that needs
it.
.IP \(bu
.B "Bounds are a counting semaphore, not a heuristic."
Where a Go program must limit concurrency the idiom is a buffered
channel used as a semaphore: acquire before the work, release after.
Explicit, and correct by construction \(em rather than inferring "is
anyone idle?" from whether a lock has waiters, which is fault 3.
.PP
.B "So the design gets simpler, not more elaborate."
Delete the global queue.
.CW exportproc
already reads one message at a time on its own connection; have it
spawn a worker per request, bounded by a counting semaphore per
connection and another globally.  No
.CW exq ,
no
.CW qwait ,
no rendezvous handoff, no spawn heuristic \(em three of the four
faults stop existing rather than being fixed, and the fourth (bounds)
becomes the one explicit thing the code does say.
.PP
Dis processes are not goroutines \(em
.CW kproc
is heavier than
.CW go
\(em which is why the semaphore is per connection as well as global,
and why workers linger briefly before exiting rather than being
created per message on a chatty connection.  That is the one place
this design has to be more careful than Go's.

.NH 1
Staging, because exportfs is shared by everything
.PP
Each stage is separately measurable with
.CW latency.py
(load N readers, time new connections) and separately revertible.
.IP "Stage 1."
Fix the spawn heuristic and the convoy without moving the queue: count
idle slaves explicitly rather than inferring from
.CW qwait.head ,
and let slaves wait on the rendezvous WITHOUT holding
.CW qwait ,
so more than one can be listening.  Small, contained, and it should
move the tail on its own.  Measure.
.IP "Stage 2."
Remove the global queue: a worker per request, spawned by the
connection's own
.CW exportproc ,
bounded by a per-connection semaphore.  This is the fairness fix and
the one the measurement is really about.  Measure.
.IP "Stage 3."
Bounds and linger:
.CW Maxconnproc ,
.CW Maxproc ,
idle exit.  Measure, and check that a client which stops reading
cannot make the emu grow without limit.
.NH 1
How it is judged
.PP
The same harness, before and after, reported as a DISTRIBUTION and not
a threshold \(em median, p90 and max over at least twenty connections
at each of zero, one, three and eight concurrent readers.  A fix that
improves the median and leaves the tail is not a fix: the tail is the
whole complaint.
.PP
Acceptance: p90 under 1 second and max under 5 at three readers, with
no regression in throughput measured by the same client reading a
1.9MB file.
.NH 1
Where the time goes, measured with a harness that proves its own load
.PP
.B "The connect is instant.  The service is not."
Splitting the measurement into TCP connect and the Tversion round
trip, with three readers and the bytes they actually moved reported:
.P1
LOAD ACTUALLY GENERATED: 164.1 MB by 3 readers
  slow: connect 0.00s  handshake 10.31s
  slow: connect 0.00s  handshake  1.35s
median 4.53  p90 52.03  max 66.56
.P2
So
.CW accept
is not the problem and styxlisten is not the problem: the connection
is established at once and then waits to be SERVED.  That is
exportfs's dispatch, which is what this plan is about, and it is the
first measurement that localises it rather than inferring it.
.PP
.B "And the harness had to be fixed first, for the same reason as
.B "everything else in this port."
An earlier run of the identical code reported p90 0.03s at three
readers, which would have said the problem did not exist.  The
loaders had failed to connect and the harness had no way to say so.
It now reports the megabytes it actually moved and shouts if a load
run moved less than one, because a benchmark that cannot prove it
applied load is not evidence of anything.
.NH 1
Status of the implementation
.PP
Stage 2 was written \(em global queue removed, a worker spawned per
request by the connection that read it, inline service at the bound \(em
and it is NOT committed: it crashes.
.IP \(bu
The first crash was
.CW "panic: decref" ,
from
.CW exdispatch
adopting the connection's pgrp, egrp and fgrp by plain assignment
without taking a reference.  That was survivable when a slave looped
forever and never exited; with a worker per request every worker
exits and closes three groups it never referenced.  Fixed by saving
and restoring the worker's own groups.
.IP \(bu
The second is
.CW "process exwork faults: dereference of nil"
inside
.CW exdispatch ,
intermittently and only under load.  Not diagnosed.  The candidates
are the Export being freed under the worker despite the reference
taken before the spawn, and
.CW up->env
not being what a kproc'd process assumes.
.PP
It is reverted rather than left in, because
.CW exportfs.c
is shared by every emu in the tree and a server that crashes under
load is worse than one that is slow under load.  The baseline above is
the number to beat, and the crash above is the next thing to fix.
.NH 1
Result: the redesign works, and H4 is answered
.PP
.B "The latency problem is solved."
The same harness, reporting the load it actually moved:
.P1
                       median    p90     max
baseline (queue)         4.53s  52.03s  66.56s   164MB, 3 readers
worker per request:
  1 reader  (563MB)      0.01s   0.02s   0.02s
  3 readers (813MB)      0.01s   0.01s   0.02s
  8 readers (248MB)      0.02s   0.04s   0.04s
.P2
The acceptance criterion \(em p90 under a second, max under five \(em
is met by three orders of magnitude, under heavier load than the
baseline was measured at.  A new connection is now served in tens of
milliseconds while the server moves hundreds of megabytes.
.PP
.B "And the nil dereference is a race between workers on one
.B "connection."
That is H4 from doc/emu-exportfs-nil-plan.ms, settled by the
experiment the plan said to run first because it was a one-line
rebuild:
.CW Maxconnproc
at 1 serialises a connection's workers exactly as the old
.CW exq.qwait
did, and the nil fault does not occur.  It did occur repeatedly at 4.
So the fault is not in the per-request dispatch itself but in two
workers of the same connection running at once \(em which the old
design never allowed, and which therefore nothing in
.CW Exfid ,
.CW fs->fid[]
or the reply path was ever required to tolerate.
.PP
Note what this means for the design: the per-connection worker LIMIT
is not only a resource bound, it is currently a correctness
requirement.  Raising it needs the concurrency audit that the old
serialisation made unnecessary.
.PP
.B "What is not fixed."
.CW "panic: decref"
on connection teardown, intermittently.  It is not the group
references \(em those are saved and restored \(em and it survives at
.CW Maxconnproc
1, so it is not the worker race either.  The likely area is
.CW exshutdown
calling
.CW swiproc
on a worker mid-request: the old
.CW exslave
was written to be killed and looped afterwards, whereas a worker that
is interrupted may unwind without reaching its
.CW exfreeq ,
or reach it twice.
.PP
.B "Where the work is."
.CW doc/exportfs-dispatch.patch ,
389 lines against the committed
.CW exportfs.c .
The tree is reverted, because that file is shared by every emu here
and a server that dies on teardown is not an improvement on a server
that is slow.  The patch is worth finishing: a 1700-fold latency
improvement is sitting behind one reference-counting bug.
.NH 1
Done: both crashes were one bug, and it was in the borrow
.PP
.B "The fault was the borrowed process groups, on the paths that
.B "return."
.CW exdispatch
installs the connection's pgrp, egrp and fgrp into the running
process by plain assignment and takes no reference.  The old
.CW exslave
got away with it because it was a dedicated process that looped for
ever and never exited.  Both callers in the new design are different:
a worker exits after one request, and the INLINE caller is the
connection's own reader, whose environment has to survive the call.
Either way the groups were still installed at exit,
.CW pexit
closed three groups the process had never referenced,
.CW exfree
closed the same three when the Export went, and the second close
panicked.
.PP
Restoring inside
.CW exdispatch ,
wrapped in
.CW waserror
so it happens on the error unwind too, fixes it: what borrows, returns.
.PP
.B "And it was the nil dereference as well."
The earlier conclusion \(em that the nil fault was a race between two
workers of one connection, because it stopped at
.CW Maxconnproc
1 \(em was wrong.  Both symptoms were this single bug.  With the borrow
fixed,
.CW Maxconnproc
4 survives six runs of half a gigabyte each with no fault of either
kind.  That is a useful reminder that a knob which makes a symptom go
away has not thereby explained it.
.NH 2
What made it findable: getcallerpc was broken on arm64
.PP
.CW "panic: decref, pc=0x..."
had been naming nobody, because
.CW lib9/getcallerpc-MacOSX-arm64.c
used
.CW __builtin_return_address(0)
where the amd64 file beside it uses
.CW (1) .
Zero is the return address of
.CW getcallerpc
itself, so every panic reported an address inside the REPORTING
function.  The proof was arithmetic: the panic printed
.CW pc=0x102a03a2c
and
.CW decref=0x1029ffd28 ,
and the difference is 0x3c \(em inside
.CW decref .
.PP
With
.CW (1) ,
the same panic resolves immediately to
.CW "closefgrp (pgrp.c:201)" ,
which is the whole diagnosis.  This affects every
.CW getcallerpc
user on Apple Silicon, including
.CW poolfault
in
.CW include/pool.h ,
so every allocator fault on this platform has been pointing at the
allocator rather than at whoever corrupted it.  It is the second time
in this session that the instrument, not the system, was the thing
that was wrong.
.NH 2
Measured, with the load proven
.P1
                       median    p90     max
baseline (queue)         4.53s  52.03s  66.56s   164MB, 3 readers
after, Maxconnproc 4:
  0 readers                 0s   0.01s   0.01s
  1 reader  (1589MB)     0.01s   0.03s   0.04s
  3 readers ( 500MB/run) 0.01s   0.03s   0.05s
.P2
Six consecutive three-reader runs at half a gigabyte each, no panic
and no fault.  p90 improves by a factor of about 1700.
