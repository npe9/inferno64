.TL
exportfs: a better way to dispatch connections
.AU
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
Move the queue into
.CW Export .
This is the fairness fix and the one the measurement is really about.
Measure.
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
