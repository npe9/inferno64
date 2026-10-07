.TL
Diagnosing the exportfs worker nil dereference
.AU
.NH 1
What is known
.PP
With a worker spawned per request (doc/exportfs-dispatch-plan.ms,
stage 2), emu dies under load:
.P1
3   emu    0x00000001000c5944 exdispatch + 516
4   emu    0x00000001000c56b4 exworker + 72
5   emu    0x0000000100089 0e8 tramp + 72
SYS: process exwork faults: dereference of nil
.P2
Intermittent, only with concurrent readers, never on an idle server.
An earlier crash in the same code was
.CW "panic: decref"
and is understood and fixed:
.CW exdispatch
adopts the connection's pgrp, egrp and fgrp by plain assignment
without taking a reference, which is survivable for a slave that loops
for ever and fatal for a worker that exits after one request.  That
one is not this one.
.PP
.B "\(lqDereference of nil\(rq is emu's own words."
It is the fault handler catching a SIGSEGV on a low address, so this
is a genuine C nil dereference, not a Limbo error.
.NH 1
Why ASan is not simply the answer here
.PP
.B "emu does not use the system allocator for these objects."
.CW Exq
and
.CW Export
come from
.CW "malloc / mallocz"
in
.CW emu/port/alloc.c ,
which is emu's own pool allocator \(em
.CW poolalloc ,
.CW poolfree ,
blocks carried on a
.CW Bhdr
chain with a
.CW magic
field \(em and the link line aliases
.CW __wrap_malloc
over
.CW malloc .
So to ASan the whole heap is a handful of enormous live slabs.  A
use-after-free of an
.CW Export
is a read of memory ASan believes is validly allocated, and it will
report nothing.
.PP
There is already an
.CW emu-cocoa-asan
binary in this tree, built ad hoc with no mkfile target.  Running it
unchanged against this bug would produce a clean report and a false
sense of having eliminated the whole class.  That is the same shape of
mistake this port has made repeatedly with instruments that cannot see
what they are pointed at, and it is worth stating before anyone spends
a day on it.
.PP
.B "Two ways to make it work, and one alternative."
.IP 1.
.B "Teach ASan about the pool."
ASan has a manual poisoning interface for exactly this:
.CW __asan_poison_memory_region
on the block in
.CW poolfree ,
.CW __asan_unpoison_memory_region
on the returned block in
.CW poolalloc .
With those two calls the pool becomes visible and a use-after-free
reports with the allocation, free and use stacks, which is what is
wanted.  Guarded by
.CW __has_feature(address_sanitizer)
so the normal build is untouched.
.IP 2.
.B "Bypass the pool for the diagnostic build."
Compile emu with the wrappers routed to the real
.CW malloc
and
.CW free .
Simpler, but it changes allocation timing, and this bug is a race \(em
so it may stop reproducing, which proves nothing.  Prefer 1.
.IP 3.
.B "Poison and quarantine, without ASan."
This tree has done it before and it worked: write a recognisable
pattern over a freed object, keep it out of circulation for a while,
and check for the pattern at every use.  When a field comes back
poisoned, the field NAMES the use-after-free.  It costs a few lines,
needs no special build, and runs at full speed so the race still
reproduces.
.NH 1
The plan
.NH 2
Phase 0 \(em make it reproducible, and say how often
.PP
Nothing can be concluded from a bug that appears sometimes.  Run the
load harness at 3 and 8 readers, twenty times each, and record the
crash rate and the mean time to crash.  If it is rarer than one run in
five, raise the pressure first:
.CW Maxconnproc
to 16, more readers, smaller
.CW msize
so more messages per megabyte.  Acceptance for this phase is a
reproduction of better than one in three within two minutes.
.NH 2
Phase 1 \(em the exact line, before any theory
.PP
.CW "exdispatch + 516"
is an offset into an
.CW -O2
build and is not worth guessing from.  Build emu
.CW -O0
.CW -g ,
reproduce, and resolve the address with
.CW atos
.CW -o
.CW emu
.CW -l
<slide>.  One line of source ends most of the candidate list below
without any further work.  It is the cheapest step and it was skipped
the first time.
.NH 2
Phase 2 \(em make the allocator honest
.PP
Add the two ASan poisoning calls to
.CW poolalloc
and
.CW poolfree
under
.CW __has_feature(address_sanitizer) ,
add an
.CW emu-asan
target to
.CW emu/MacOSX/mkfile
so it stops being an ad hoc binary, and re-run Phase 0 under it.
.PP
In parallel, because ASan may slow the race away: poison
.CW Export
and
.CW Exq
on free with a recognisable word, and assert the object is not
poisoned at the top of
.CW exdispatch ,
.CW exworker
and
.CW exreply .
.NH 2
Phase 3 \(em the hypotheses, each with what would settle it
.IP "H1.
.B "The Export is freed under the worker."
The worker takes
.CW incref(&fs->r)
before
.CW kproc
and
.CW exdispatch
ends with
.CW exfreeq(q) ,
which drops the request's own reference \(em so if the accounting is
off by one anywhere, the last use in
.CW exworker
touches freed memory.  SETTLED BY: poisoned
.CW fs->r
or an ASan use-after-free naming
.CW exfree
as the freer.
.IP "H2.
.B up->env " is not what a kproc'd process assumes."
.CW exdispatch
writes
.CW up->env->pgrp
and calls
.CW kstrdup(&up->env->user, ...) .
SETTLED BY: an assertion on
.CW up->env
and
.CW up->env->user
at entry to
.CW exworker ,
before anything else runs.
.IP "H3.
.B "The request is malformed or its type unhandled."
.CW fcalls[q->in.type]
is checked, but
.CW q->buf ,
.CW q->export
and
.CW q->bsize
are not.  SETTLED BY: assertions at entry to
.CW exdispatch .
.IP "H4.
.B "Two workers on one connection race."
Up to
.CW Maxconnproc
workers now run concurrently on a single Export where the old design
serialised them through
.CW exq.qwait ,
so
.CW fs->work ,
.CW fs->fid[]
and the reply path see a concurrency they did not before.  SETTLED BY:
.CW Maxconnproc
set to 1.  If the crash stops, it is a race between workers; if it
survives, it is not.  That one experiment splits the space in half and
should be run FIRST, because it costs a rebuild and no analysis.
.IP "H5.
.B "The reply path is not safe for concurrent writers."
.CW exreply
writes the connection fd.  Two workers replying at once could
interleave.  SETTLED BY: H4's outcome, then inspection of
.CW exreply .
.NH 2
Phase 4 \(em fix, and prove it
.IP \(bu
The crash must not recur in 200 harness runs at 8 readers under the
ASan build.
.IP \(bu
The latency distribution must beat the baseline \(em median 4.53s, p90
52.03s, max 66.56s at three readers with 164MB actually moved \(em and
be reported as a distribution, with the load the harness generated
printed beside it.
.IP \(bu
The Pi must complete a full kupdate, five times.
.NH 1
Order, and why
.PP
H4 first, because it is a one-line rebuild that halves the search
space.  Then Phase 1, because one line of source may end it outright.
Then Phase 2 only if those two have not.  The temptation is to reach
for the sanitizer immediately; here that would mean a day spent making
a tool work on an allocator it cannot see, to answer a question a
recompile might settle in ten minutes.
