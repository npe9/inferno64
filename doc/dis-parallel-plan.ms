.TL
Parallel Dis
.AU
Inferno multicore
6 September 2026
.PP
.CW doc/multicore-plan.ms
section 4 is titled "Why the interpreter can never be parallel here",
and it is right about the interpreter as it stands: one global
.CW REG
.CW R ,
and every code generator compiling that object's address into what it
emits.  This document is what changing that costs.  The two are not in
conflict \- the first says what is true of the present design, this one
says what a different design would take \- but a reader who meets them
in the wrong order should be told, and section 4 now points here.
.PP
One thing to say at the front, because the last round ended blocked and
this one does not: none of this is gated on the
.CW "mcall / movp / destroy"
corruption.  Writing the design does not need a stable baseline.  Only
validating an implementation does, and by then step 0 below has given us
a better instrument for it than the one that hunt has been using.
.NH 1
The decision that is already made for us
.PP
Go is the obvious reference and it is the wrong one in exactly one
place, so that place goes first.
.PP
Dis reference-counts and colour-collects cycles.  Go does neither: it is
pure tracing, no reference counts, and that is deliberate, because
reference counting is the thing that does not parallelise.  Every
pointer store becomes an atomic read-modify-write, on every mutator, for
ever.  If Dis could drop its counts the way Go has none, parallel Dis
would be a much smaller and much faster project.
.PP
It cannot, and the reason is in
.CW os/inferno/port/inferno.c :
.IP
.nf
freeFD(Heap *h, int swept)
{
	...
	release();
	if(handle->fd.fd >= 0)
		kfgrpclose(handle->grp, handle->fd.fd);
	closefgrp(handle->grp);
	acquire();
.fi
.PP
That is the
.CW free
hook on the type behind
.CW Sys->FD ,
and
.CW destroy()
in
.CW libinterp/heap.c
calls
.CW t->free(h, 0)
the moment
.CW ADEC(&h->ref)
reaches zero.  Dropping the last reference to a file descriptor closes
the file
.I now .
.CW freechan
is the same shape: it
.CW killcomm s
both queues of a channel as the last reference goes.
.PP
So prompt finalisation is not an implementation detail here, it is
observable Limbo behaviour.  A Limbo program that drops an
.CW FD
and expects the file closed \- and they do, that is how the language is
written \- would, under a tracing collector, hold it open until a
collection got round to it.  Changing that is changing the language.
.PP
.B "Therefore reference counting stays, and that is the ceiling."
Every pointer store in the interpreter and in JIT-emitted code carries
an atomic pair, and no amount of scheduler work removes it.  A plan that
does not say this at the top is selling something.
.PP
There is one compensation and it is worth having.  A concurrent tracing
collector needs a write barrier at every pointer store, and that cost is
the usual objection to it.  Dis already executes code at every pointer
store \- the reference-count update is itself a barrier.  So the
marginal cost of making the collector concurrent, once the counts are
atomic, is far lower here than in a runtime that has to add barriers
from nothing.
.NH 1
What is a singleton today
.PP
Five things, and the numbers are counted rather than estimated.
.NH 2
The register file
.PP
.CW libinterp/xec.c
line 11:
.CW "REG R;" .
Fifteen fields \-
.CW PC ,
.CW MP ,
.CW FP ,
.CW SP ,
.CW TS ,
.CW EX ,
.CW M ,
.CW IC ,
.CW xpc ,
.CW s ,
.CW d ,
.CW m ,
and three temporaries \- about 120 bytes, referenced as
.CW R.field
1921 times across
.CW libinterp ,
and with its address taken 109 times outside the code generators.
.NH 2
Channels have no locks
.PP
Not weak locks: none.
.CW "struct Channel"
in
.CW include/interp.h
is a
.CW buf ,
two
.CW "Progq*"
queues, an
.CW aux ,
a
.CW mover
and three scalars, and
.CW libinterp/alt.c
manipulates the queues bare.  There is not one
.CW lock()
in the file.  This is correct today and only today, because one program
runs at a time.
.NH 2
The collector is global
.PP
.CW libinterp/gc.c
holds
.CW marker ,
.CW sweeper ,
.CW base ,
.CW limit ,
.CW visit ,
.CW markdepth ,
a
.CW ptrtab[PTRHASH]
pointer-hash table and its free list, all file-static.
.CW include/interp.h
adds
.CW gchalt
and
.CW nprop ,
plain
.CW int s,
with
.CW gclock()
defined as
.CW gchalt++ \-
a read-modify-write, not an atomic one \- and
.CW Setmark
writing
.CW nprop
directly.
.NH 2
Allocation is global
.PP
.CW os/inferno/port/alloc.c
and
.CW xalloc.c
are three pools behind
.CW ilock s,
and
.CW nheap()
goes through them for every Dis object.  Every kernel process on every
processor already contends here; a parallel interpreter multiplies it.
.NH 2
There is one run queue
.PP
.CW isched.runhd / runtl
in
.CW os/inferno/port/dis.c ,
with
.CW addrun ,
.CW delrun ,
.CW delrunq ,
.CW delruntail ,
.CW pushrun
and
.CW currun
all written against it, and
.CW currun()
in particular meaning "the head", which is the same thing as "the
program being interpreted" only while there is one interpreter.
.NH 2
The program table and the module list
.PP
Two more, smaller and easier to miss than the four above, and both on
paths two programs take at once.
.PP
.CW os/inferno/port/dis.c
has
.IP
.nf
static Prog*	proghash[64];
.fi
.PP
and
.CW pidlook()
walks a bucket chain with no lock anywhere.  Every
.CW spawn
inserts,
.CW delprog
removes, and every
.CW /prog
read goes through it \- the boot logs in
.CW doc/multicore-plan.ms
show
.CW "devprog: progpid progpid() reached, count 10"
on the way to a shell.  Two programs spawning at once race on a bucket.
.PP
.CW libinterp/load.c
has a global
.CW "Module *modules"
threaded through
.CW m->link ,
inserted with a bare
.IP
.nf
m->link = modules;
modules = m;
.fi
.PP
and walked by the module lookup.  Module loading is the other thing two
programs do simultaneously, and it is unprotected in the same way.
.PP
Neither is hard \- a lock, or per-context shards with a global fallback
\- but they belong on the list, because this is the class of thing that
gets found by a crash rather than by a plan.
.NH 1
What Go gives us, and where it stops
.PP
The single structural idea Inferno is missing is
.B P .
.PP
Go's runtime is G, M and P: a goroutine, an OS thread, and a
.I processor \-
a scheduling context that owns a run queue and an allocation cache, and
which an M must hold to run Go code.  Map it onto this kernel and the
gap is obvious.  G is
.CW Prog .
M is the
.CW dis
kernel process.  There is no P: nothing owns a register file, an
allocation cache and a run queue together, which is exactly why those
three are global.
.PP
Introducing P is the change.  Everything below hangs off it.
.IP \(bu
.B "The current-context register."
Go reserves a machine register for the current G \- R14 on amd64, R28 on
arm64 \- so that runtime code reaches it without a lookup.  That is what
.CW R
has to become, and it says what the JIT change actually is.
.IP \(bu
.B "Per-P run queues, a global queue, and work stealing."
Go gives each P a bounded local queue, overflows into a global one, and
lets an idle P steal half of another's
.CW ( runqsteal ).
.CW isched.runhd / runtl
becomes the per-P queue; what is left of
.CW isched
becomes the overflow and balance queue.
.IP \(bu
.B "A lock per channel."
Go's
.CW hchan
carries a mutex and send, receive and select all take it.  That is the
direct answer to
.CW Progq
being bare.
.IP \(bu
.B "Address-ordered locking for"
.CW alt .
This is the part that is easy to miss and expensive to get wrong.
Limbo's
.CW alt
waits on many channels at once, so it must hold many locks at once, and
two
.CW alt s
over the same channels in different orders deadlock.  Go's
.CW selectgo
sorts the channels by address and locks in that order.  Write it down as
a rule of the design, not as a thing to remember.
.IP \(bu
.B "Waking onto a queue."
Go's
.CW goready
puts an unblocked G on a specific P's queue.  This kernel's
.CW addrun
and the
.CW cwakeme / cblock
pair are the analogue and both assume there is only one place to put it.
.IP \(bu
.B "Per-P allocation caches."
Go's
.CW mcache ,
.CW mcentral
and
.CW mheap :
a per-P cache of size classes, a shared middle, a global heap, so the
common allocation takes no lock at all.  This is the same item as
.CW doc/multicore-plan.ms
section 8's per-processor allocation, but there it is an optimisation
and here it is a prerequisite.
.PP
Where Go stops being a guide:
.IP \(bu
.B "Reference counts."
Section 1.  Go has none; we cannot drop ours.  Everything Go says about
write barriers being the price of concurrent collection has to be
re-read in that light \- we are already paying it.
.IP \(bu
.B "Moving objects."
Go's collector does not move, which is lucky, because Dis hands raw
pointers to C
.CW runt()
builtins throughout and a moving collector would be out of the question.
Copy the non-moving choice and do not be tempted.
.IP \(bu
.B "Preemption."
Go preempts goroutines asynchronously.  Dis has a natural quantum
already \-
.CW R.IC
counts down
.CW PQUANTA
instructions \- and per-P scheduling should use it rather than invent
signal-based preemption.
.NH 1
Step 0: the instrument
.PP
Before any of the design: this work is developed under the hosted
emulator, not under QEMU.  Real threads, no emulation, a debugger that
works, and \- the part that decides whether the project is finishable at
all \-
.B ThreadSanitizer .
A parallel interpreter written without a race detector is not a project
anybody completes; it is a hunt like the one in
.CW doc/inferno-ports.ms ,
except every bug is a race.
.PP
There is one thing in the way, and it is already fixed on a sibling
branch.  emu does not currently link against this tree's
.CW libinterp :
the crash-hunt diagnostics call
.CW _printfreehist
and
.CW _checkfreeptr ,
which live in
.CW os/inferno/port/alloc.c ,
a file no hosted build has.  Commit
.CW 1a55f0c9
on
.CW inferno-rio \-
.I "emu: dumpstack and printfreehist, so the shared crash-hunt hooks link on a host" \-
is exactly that repair.
.PP
.B "Verified."
Cherry-picked onto this branch
.CW ( 2c33d1e2 ),
emu links, and the resulting
.CW o.emu-cocoa \-
built from current source, not the 24 August binary the last round had
to rely on \- runs the spawn storm six times out of six clean.  So Step
0 is one command and it is known to be sufficient, rather than hoped
to be.
.PP
Then build emu with
.CW -fsanitize=thread ,
alongside the
.CW -fsanitize=address
build the tree already keeps in
.CW MacOSX/arm64/bin/emu-cocoa-asan ,
and put both in the mkfiles rather than leaving them as untracked
binaries that go stale \- which is what happened to the ASAN one, and it
cost this round a false lead.
.PP
.B Done.
.CW emu/MacOSX/mkfile
takes
.CW SANCFLAGS
and
.CW SANLDFLAGS
from the environment \- from the environment, and not from mk's command
line, because mk reads a value beginning with a minus as an attribute:
.IP
.nf
SANCFLAGS='-fsanitize=thread -fno-omit-frame-pointer' \e
SANLDFLAGS=-fsanitize=thread mk
.fi
.NH 2
What the instrument had to be taught first
.PP
A tool that cannot see the locks reports every critical section, and
that is what happened on the first run: eight spawns of a shell,
.B "947 data races" ,
the bulk of them inside
.CW poolalloc ,
.CW poolfree
and
.CW pooldel .
That is not the allocator being wrong.  It is the allocator being the
most lock-protected code in the system.
.PP
.CW emu/port/lock.c
is invisible to ThreadSanitizer twice over.
.CW lock()
is built on
.CW _tas() ,
hand-written assembly the tool does not instrument and cannot know is an
acquire; and
.CW unlock()
was
.IP
.nf
coherencefn();
l->val = 0;
.fi
.PP
a plain store, which the tool sees as an ordinary racing write \- and
which is a data race under the C memory model however the hardware
behaves.
.PP
Two changes, and the count is the measurement:
.IP \(bu
.CW __tsan_acquire
and
.CW __tsan_release
around the
.CW _tas
success paths and in
.CW unlock \-
the interface that exists for a synchronisation primitive the compiler
did not generate, compiling to nothing without
.CW -fsanitize=thread .
947 reports become 122.
.IP \(bu
.CW unlock 's
store becomes
.CW "__atomic_store_n(&l->val, 0, __ATOMIC_RELEASE)" ,
which says what
.CW coherencefn()
and the assignment meant, to the compiler and to the tool at once.  122
become 14.
.PP
And the fourteen are real.  Six are
.CW acquire
at
line 1024 of
.CW emu/port/dis.c
and six are
.CW vmachine
at lines 1357 and 1363, and TSan names the object: "Location is global
.CW isched ".
That is
.CW isched.vmq
being written by one thread and read by another with nothing between
them \- the same defect this branch already fixed on the native side,
found independently by the tool, in emu, where it is still live.  The
rest are
.CW "qproduce / notempty"
in
.CW qio.c
and a handful in the pool.
.PP
So the instrument works, it took two small changes to make it work, and
the first thing it said was that the analysis in
.CW doc/multicore-plan.ms
section 3.2 was right about a kernel it was not looking at.
.NH 1
The phases
.NH 2
Phase 1 \- the register file becomes per-context
.PP
This is the one that sounds impossible and is not.
.CW R
is referenced as
.CW R.field
1921 times, and a macro redirects every one of them without an edit:
.IP
.nf
#define R	(*curR)
.fi
.PP
What
.CW curR
is differs by host, and the plan should not pretend otherwise.
.IP \(bu
.B Native :
.CW up
is a machine register already (R14 on amd64), so
.CW curR
is
.CW up->reg \-
one indirection off a register, in a kernel where
.CW up
is reloaded correctly on every entry, which
.CW doc/multicore-plan.ms
section 3.1 is the story of making true.
.IP \(bu
.B emu :
.CW up
comes from
.CW pthread_getspecific ,
which is a function call.  At 1921 sites in the hottest loop in the
system that is not a cost, it is a redesign.  emu needs
.CW __thread
storage for
.CW curR .
Say it plainly: the macro is free natively and is not free hosted.
.PP
.PP
.B "One fork inside this phase, and it is a correctness fork, not a
taste one."
.CW curR
can point at
.CW up->reg \-
a register file owned by the executing context \- or at
.CW &p->R ,
the one already inside each
.CW Prog .
Go's model argues for the second: in Go the register and stack state
lives in the
.CW g ,
and here that would make
.CW isave()
and
.CW irestore()
disappear, which is a real simplification.
.PP
Take the first anyway, and here is why, so that nobody undoes it.
Today
.CW p->R
is a snapshot that lags: the note at
line 1264 of
.CW os/inferno/port/alloc.c
records that it is "only refreshed at the start and end of
.CW xec() 's
whole PQUANTA=2048-instruction quantum, not per instruction".  And the
collector reads it.
.CW libinterp/gc.c 's
root walk is
.IP
.nf
while(root != nil) {
	ml = root->R.M;
	...
	sp = root->R.SP;
	ex = root->R.EX;
.fi
.PP
\- it takes
.CW Prog->R
as the root set and traverses the Dis stack from
.CW R.SP
through the
.CW Stkext
chain at
.CW R.EX .
Pointing
.CW curR
at
.CW &p->R
turns a quiet quantum-boundary snapshot into live, per-instruction
mutable state that a concurrent collector reads while the mutator
writes it \- a race that does not exist today and would be created by
the change that looks like a simplification.
.PP
So:
.CW up->reg ,
with
.CW "isave / irestore"
kept as the barrier between the live registers and the collector's
view.  If a later design does want
.CW &p->R ,
it has to answer the root-set question first.
.PP
The 109 address-taken sites split in two.  Those that hand a
.CW REG*
to something already parameterised \-
.CW destroystack(REG*) ,
.CW modstatus(REG*) ,
.CW progstack(REG*) \-
are already in the right shape and need nothing.  Those that assume the
singleton are the work, and 109 is the upper bound on it, not the
estimate.
.PP
Verified by: an unchanged single-threaded interpreter.  There is no test
suite to appeal to \- native panics on four boots in five and the
console cannot take input, which is why
.CW doc/multicore-plan.ms
has a phase devoted to building one \- so the concrete harness is the
one that already exists:
.CW tmp/spawnstress.sh ,
the sixty-seven spawn storm from
.CW /dis/init ,
under
.CW "o.emu-cocoa -c0" ,
which runs six of six clean today.  This phase changes no behaviour at
all.  If that moves, stop.
.NH 2
Phase 2 \- introduce P
.PP
A
.CW Pctx
owning a register file, a run queue and (Phase 3) an allocation cache.
.CW isched
keeps the global overflow queue and the list of all programs.
.CW currun()
stops meaning
.CW isched.runhd
and starts meaning this context's current program, which is what every
one of its callers already wants \-
.CW discall.c ,
.CW inferno.c ,
.CW exception.c
ask it for "the program making this call", and that has been ambiguous
since the day a second interpreter became possible.
.PP
Then per-P queues, a global queue, and stealing, on Go's shape.
.PP
Verified by:
.CW n
set to 1 throughout, behaving exactly as Phase 1, and only then raised.
Every step is a comparison against a known-good.
.NH 2
Phase 3 \- allocation
.PP
Per-P caches over
.CW os/inferno/port/alloc.c ,
on the
.CW "mcache / mcentral / mheap"
shape.  Until this lands, per-P run queues buy very little: the programs
run on different processors and then queue up on one allocator.
.NH 2
Phase 4 \- channels and alt
.PP
A lock per
.CW Channel .
.CW alt
takes them in address order.
.CW cblock / cwakeme
and
.CW addrun
learn which queue to wake onto.  This is the phase where Limbo
semantics are at risk and where the tests have to be written first: two
programs sending to one channel, an
.CW alt
against a send, two
.CW alt s
over the same set in opposite orders.
.NH 2
Phase 5 \- the collector
.PP
Make
.CW gchalt
and
.CW nprop
atomic, give the mark state a home per collection rather than per file,
and decide between stop-the-world with parallel marking and Go-style
concurrent marking.  The note in section 1 matters here: the write
barrier that concurrent marking wants is already being executed on every
pointer store, so the second option is cheaper here than the literature
suggests.
.NH 2
Phase 6 \- the code generators
.PP
Left last on purpose, because it is the only phase that cannot be done
by a macro, and because on the boards that matter it is not on the
critical path.
.PP
The scope is smaller than a raw count suggests.  Four backends are
stubs \-
.CW comp-riscv64.c ,
.CW comp-riscv32.c ,
.CW comp-thumb.c
and
.CW comp-spim.c
are 29, 29, 34 and 2 lines and compile nothing; RISC-V interprets.  Four
more \-
.CW arm ,
.CW mips ,
.CW power ,
.CW sparc \-
are legacy and should be said to be legacy rather than costed.  Three
matter:
.CW comp-386.c
(15 sites),
.CW comp-amd64.c
(15) and
.CW comp-arm64.c
(9).
.PP
And every native board in this tree sets
.CW "int cflag = 0"
in its configuration \-
.CW pc64 ,
.CW virtarm64
and
.CW raspi3b
all interpret.  The JIT is live in emu, where
.CW cflag
defaults to 1.  So Phase 6 gates hosted parallel Dis and does not gate
native parallel Dis at all, which is a useful thing to know before
budgeting it.
.PP
The sibling branches were checked for prior art and have none.
.CW comp-amd64.c
and
.CW comp-arm64.c
differ substantially between
.CW multicore ,
.CW amd64jit ,
.CW termux ,
.CW ILP64 ,
.CW arm64
and
.CW main \-
by hundreds and by thousands of lines \- but every one of them reaches
the register file the same way, through
.CW &R
as a compile-time constant, six to fifteen times.  The divergence is in
how much of the instruction set each compiles, not in how it addresses
.CW R .
Nobody has started this.  The counts above are
.CW multicore 's;
a backend taken from another branch brings its own.
.PP
Two changes per backend, and neither is a substitution.
.IP 1.
.CW "con((uintptr)&R, RTMP)"
becomes a load of the per-context pointer, which means
.B "reserving a register"
in that backend's allocator \- a change to its internal convention, the
same thing Go does for
.CW g .
.IP 2.
The reference-count updates the JIT emits are plain load-modify-store
where the interpreter's are
.CW "AINC / ADEC" .
The comment in
.CW emu/port/dis.c 's
.CW vmachine()
records this as a known, unclosed gap and says everything in that
investigation was validated with
.CW -c0 .
It needs the architecture's atomic add, or a compare-and-swap retry.
.NH 1
What to measure, and what would say this failed
.PP
The measurement is not "does a Limbo program get faster".  With
reference counts on every pointer store, a single-threaded Limbo program
gets slightly
.I slower ,
and that is the expected result, not a failure.
.PP
What has to get better is throughput across independent programs:
.IP \(bu
.CW n
independent Limbo programs, no shared channels, wall-clock against
.CW n=1 .
This is the headline and it should approach linear before anything else
is believed.
.IP \(bu
Single-thread slowdown from atomics, measured and stated.  If it is more
than about a fifth, the atomic strategy needs revisiting before the rest
is built on it.
.IP \(bu
Channel throughput between two programs, which is where per-channel
locking either pays or does not.
.IP \(bu
Time in the collector as a fraction of wall clock, at 1 and at
.CW n .
.PP
And the honest failure condition, written down in advance: if
independent programs do not scale after Phase 3, the reference counts
are the ceiling section 1 says they are, and the answer is not more
scheduler work.  It is the sharded design
.CW doc/osprey-plan.ms
already describes for this branch \-
.I n
independent runtimes that pass copies rather than pointers \- bought
deliberately, with the cost to Limbo stated, rather than arrived at by
exhaustion.
.NH 1
What not to build
.IP \(bu
.B "A moving or generational collector."
Raw heap pointers are handed to C builtins throughout.  Go does not move
either.
.IP \(bu
.B "Lock-free channel queues."
Go uses a plain mutex per channel and it is not the bottleneck.  Take
the mutex.
.IP \(bu
.B "Asynchronous preemption."
.CW R.IC
and
.CW PQUANTA
are already a quantum.  Use them.
.IP \(bu
.B "The JIT first."
It is Phase 6 because it gates nothing on the native boards, all of
which set
.CW "cflag = 0" .
.IP \(bu
.B "Any of it without ThreadSanitizer."
Step 0 is step 0.
