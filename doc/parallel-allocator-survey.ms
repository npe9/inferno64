.TL
What a parallel allocator would need
.AU
.LP
A survey, before any of it is built, of what stands between this tree's
allocator and two Dis executors running at once.  Everything below was read out
of the source or measured, and where something is a guess it says so.  The
companion plans are
.CW doc/raspi3b-parallelvm-plan.ms
(the VM infrastructure) and
.CW doc/open-issues-plan.ms
(the collector work already done).
.PP
The short answer: the allocator is already
.I correct
under concurrency and would be
.I slow ,
and the unsafe parts are not in the allocator at all \(em they are the write
barrier, one JIT backend, and the two unlanded phases of the parallel VM.
.NH 1
What exists today
.NH 2
The pool allocator is locked, per pool, and that is all
.LP
.CW os/inferno/port/alloc.c
keeps three pools \(em
.CW main ,
.CW heap ,
.CW image
\(em in one static table.  Each
.CW Pool
carries its own
.CW "Lock l" ,
and every allocation and free takes it with
.CW ilock(&p->l) :
there are nineteen
.CW ilock / iunlock
pairs in the file and no path that touches the free list without one.
.PP
So it is MP-safe now.  What it is not is parallel: a
.CW Pool
has a
.I single
free list
.CW ( "Bhdr* root" ,
with
.CW chain
for the arena list), so two executors allocating at once contend on one lock
per pool, and on this board every
.CW NEW
and
.CW NEWA
a Limbo program executes goes through it.  There is no per-processor cache, no
magazine layer, nothing between a Dis instruction and that lock.
.PP
The accounting is in the same place:
.CW nalloc ,
.CW nfree ,
.CW cursize ,
.CW hw ,
.CW nbrk
are plain fields of
.CW Pool ,
updated under the lock.  Correct, and a guaranteed cache-line bounce between
processors on every allocation.
.NH 2
Dis refcounts are atomic in C, and in one of the two aarch64 JITs
.LP
.CW include/interp.h
defines
.CW AINC / ADEC
over
.CW __atomic_fetch_add / __atomic_sub_fetch ,
and the comment there spells out why: a plain
.CW ->ref++
can lose an update, and two threads can both observe the count reach zero and
both free the object.  Every genuinely shared site across
.CW heap.c ,
.CW xec.c ,
.CW draw.c ,
.CW tk.c ,
.CW loader.c ,
.CW keyring.c ,
.CW link.c ,
.CW load.c ,
.CW string.c ,
.CW runt.c ,
.CW crypt.c
and the
.CW emu/port
files that touch Limbo heap objects goes through them.
.PP
The JIT is the interesting half, and the tree contains two aarch64 backends:
.P1
comp-aarch64.c   kernels (OBJTYPE=aarch64: raspi3b, raspi4, virtarm64)
                 LDXRW/STXRW retry loops at all four Heap.ref sites.  ATOMIC.
comp-arm64.c     hosted emu on this machine (OBJTYPE=arm64)
                 no LDXR, no STXR, no LDADD anywhere.  NOT atomic.
.P2
No board builds
.CW arm64 ,
and no
.CW mkfiles/mkfile-os-arm64
exists, so for kernels the JIT is already correct.  But
.CW emu/MacOSX
builds with
.CW -DOBJTYPE="arm64" ,
which means
.I every hosted test in this tree runs the non-atomic one .
The standing comment in
.CW emu/port/dis.c
describes this gap and is right about it; it is only misleading in that it reads
as though no aarch64 JIT had been fixed.
.NH 2
What the parallel VM already has, and the two phases it does not
.LP
Landed and verified on silicon:
.CW Prog.reg ,
.CW curR ,
.CW Pctx ,
the
.CW gchalt / gcdepth
split,
.CW progreg() ,
the
.CW inxec
safepoint and its
.CW rungc()
invariant check,
.CW stoptheworld() / starttheworld() ,
the process-group lock, and a per-context run queue.
.PP
Not landed, and both are prerequisites:
.IP "\(bu" 3
.B "Phase 1b, curP as a register."
Two executors inside
.CW xec()
both reach the register file through
.CW curP ,
which is a single global here, so they would share one register file.
.CW claimctx() 's
own comment calls sharing "unsafe while parallelvm=1".
.IP "\(bu" 3
.B "Phase 4, a lock per channel."
.CW isend / irecv
walk channel queues and write another
.CW Prog 's
.CW ptr
\(em into its stack \(em with nothing held.  This is what the old global VM lock
used to cover.
.NH 1
What a parallel allocator would need
.NH 2
1.  Per-processor free lists, which is the only real allocator work
.LP
The lock is correct, so this is a throughput change and can be done
incrementally and measured at each step: a small per-processor magazine in front
of each pool, refilled from and flushed to the shared free list under the
existing lock.  Nothing about the current interface has to change, and the
fallback path is what exists today.
.PP
.B "Size it from a measurement, not from taste."
A figure already exists to start from: 300 file creates through
.CW efs
cost 1143908 allocations, and
.CW /dev/memgc
counts them per pool, so the allocation rate per processor under a real workload
is one command away.  A magazine that does not cover the common size classes is
just a slower path to the same lock.
.NH 2
2.  The accounting has to stop being shared fields
.LP
.CW nalloc ,
.CW nfree
and
.CW cursize
are read by
.CW /dev/memory ,
by
.CW memlow()
on every quantum, and written on every allocation.  Per-processor counters
summed on read is the usual answer.  Note that
.CW memlow()
is on the hot path of the collector trigger
.CW ( emu/port/dis.c ,
and the kernel's copy), so making
.CW cursize
expensive to read would be a poor trade: it wants to stay cheap even if it
becomes approximate.
.NH 2
3.  The write barrier \(em AUDITED, and it is not the hole
.LP
.CW include/interp.h :
.P1
#define Setmark(h) if((h)->color!=mutator) { (h)->color = propagator; nprop=1; }
.P2
This section used to call that "the first thing that is actually UNSAFE" and
"the piece to design first", on the grounds that two mutators race on the colour
field and that losing a
.CW nprop
set frees a live object.  The audit below says the first claim is wrong and the
second was aimed at the wrong pair of threads.  Nothing here is a code change:
.CW npctx
is 1,
.CW othersrunning()
is therefore always 0, and every parallel case in this section is latent.
.PP
.B "Two concurrent barriers on one object are benign, and the reason is the values."
.CW propagator
is an enum constant, 3 \(em not a variable.  Every generator loads it as an
immediate
.CW ( "con(propagator, RA2)" ),
so compiled code never reads it.
.CW Heap.color
is a plain
.CW int ,
word-sized and aligned.  So two mutators running the barrier on the same object
write
.I identical
bits to an aligned word, and identical bits
.CW ( 1 )
to
.CW nprop .
There is no lost update to lose.
.PP
.B "What that argument does NOT cover."
Publication.  One executor allocating an object writes
.CW "h->color = mutator"
and then stores the pointer; another loads the pointer and dereferences it.
Those two colour values \(em
.CW mutator
and
.CW propagator
\(em differ, so idempotence says nothing about them, and without release/acquire
the second executor can see the pointer with a stale colour.  That is a separate
question from the barrier and it is open; see section 4a.
.PP
.B "The nprop hazard is real, but it is mutator-versus-COLLECTOR."
Losing a
.CW nprop
set needs a concurrent writer, and there is exactly one: the collector's
.CW "nprop = 0"
at
.CW gc.c :684.
The old text read as though two mutators could lose each other's, which they
cannot.  In the kernel it is covered already \(em both
.CW rungc()
call sites,
.CW execatidle()
and the busy path, are inside
.CW stoptheworld() ,
so no mutator is running.  A mutator also cannot be stopped part way through the
barrier: it is inlined with no safepoint in it, and safepoints are between Dis
instructions.
.PP
.B "In emu it is NOT covered, and that matters for item 1's own purpose."
.CW emu/port/dis.c
has three
.CW rungc()
call sites and no
.CW stoptheworld()
at all \(em the function is not even declared there.  Today that is correct by
construction, because emu runs one serialised interpreter and the collector runs
in the mutator's own thread.  But this survey says
.CW parallelvm=1
would be developed under
.CW emu ,
and under two executors emu would have exactly the mutator-versus-collector race
the kernel is protected from.  Wrapping emu's collector is a prerequisite that
item 1 does not cover.
.NH 2
4.  The colour globals \(em ESTABLISHED, stoptheworld() does cover them
.LP
The previous text said: "Suspected, not established: that no other code path
advances them.  Worth checking before relying on it, because the whole safety
argument for the colour scheme under two mutators rests on it."  Checked:
.IP "\(bu" 3
.CW gccolor
is written in exactly one place,
.CW gc.c :670,
.CW gccolor++
at the end of an epoch.
.IP "\(bu" 3
.CW mutator ,
.CW marker
and
.CW sweeper
are assigned in exactly one place,
.CW gc.c :433-435, inside
.CW rootset() .
.IP "\(bu" 3
.CW rootset()
has exactly one caller:
.CW gc.c :671, the line after
.CW gccolor++ .
.LP
So the colour globals change only at an epoch boundary, only inside
.CW rungc() ,
which in the kernel is inside
.CW stoptheworld() .
The safety argument the old text said everything rested on holds, and it is now
read off the source rather than assumed.
.NH 2
4a.  NEWLY OPEN \(em the inxec handshake has no barriers, and one site is in the wrong order
.LP
.CW stoptheworld()
publishes
.CW "gcstw = 1"
with a
.CW coherence()
and then spins until
.CW othersrunning()
reads 0.  There is no
.CW coherence()
on the success path before the collector starts reading the heap, and \(em the
grep that discriminates \(em none at any of the six sites that clear
.CW inxec
either.  So both halves of the handshake are missing their barrier, not just the
reader's.
.PP
Worse, and independent of barriers entirely,
.CW libinterp/xec.c :2533 does this:
.P1
curP->inxec = 0;
curP->curprog = nil;
p->reg = R;
.P2
It announces the safepoint and
.I then
publishes the register snapshot, under a comment saying "p->reg is authoritative
again" \(em which it is not until the next line.  A collector that saw
.CW inxec
go to 0 in between would read a stale
.CW p->reg .
.CW isave()
at
.CW xec.c :2366 does the same two things in the opposite, correct order, so the
file disagrees with itself.  That one is wrong in plain program order on a
sequentially consistent machine, never mind reordering.
.PP
Latent, like everything else here, and this tree has already paid for a missing
barrier of exactly this shape once \(em
.CW emu 's
.CW unlock()
had no release barrier and it cost the scheduler deadlock.
.NH 2
4b.  NEWLY OPEN \(em gclock() is the lost update, and gcdepth should not be shared
.LP
This is what section 3 was looking for, in the same file:
.P1
#define gclock()   do{ gchalt++; if(++gcdepth > gcdepthmax) gcdepthmax = gcdepth; }while(0)
#define gcunlock() do{ gcdepth--; gchalt--; }while(0)
.P2
Non-atomic read-modify-write on two globals, and
.I not
idempotent, which is exactly what makes them unlike
.CW Setmark .
A lost
.CW gchalt++
leaves
.CW gcruns()
true while a destroy is in progress, and the collector runs through a destroy.
That is the lost-update shape section 3 described, at the site that really has
it.
.PP
.CW gcdepth
is worse than racy, it is in the wrong place, and the comment above it already
says so: "gcdepth is how deep
.I "this thread"
is in nested destruction ... That is a property of one thread's stack."  It is a
plain
.CW "extern int" .
The comment goes on to record that sharing one counter for both purposes "fails
both ways" on two processors, and that the
.CW multicore
branch measured the depth half hitting exactly 65 against
.CW heap.c 's
guard of 64.  Splitting
.CW gchalt
from
.CW gcdepth
fixed the conflation; it left both of them global.  So
.CW gcdepth
belongs in
.CW Pctx
and
.CW gchalt
needs atomic increment and decrement \(em and unlike the barrier, neither can be
argued away by the values being equal.
.NH 2
5.  comp-arm64.c's refcounts, for hosted emu \(em DONE
.LP
Covered above.  It is a prerequisite for ever running
.CW parallelvm=1
under
.CW emu ,
which is where it would be developed and tested, so in practice it comes before
the allocator work rather than after.
.CW comp-aarch64.c
is the worked example: four sites, LDXRW/STXRW retry loops.
.PP
.B Landed.
The four sequences were ported, not rewritten, and the nine emitted words
checked against the system assembler \(em including the operand order of
.CW "STXR Ws, Wt, [Xn]" ,
which
.CW os/inferno/virtarm64/l.s
records getting backwards in
.CW _tas ,
where it assembled cleanly and stored the old contents back over themselves.
.PP
.B "And it cost something this survey asked for."
Section 3 calls the barrier the hottest shared word in a parallel VM, so the
figure matters.  None of
.CW disbench 's
six tests reaches these sequences:
.CW call 's
.CW macret
decrement sits behind a test of
.CW Frame.mr ,
nil on every local return;
.CW array
stores ints, so no pointer move and no barrier; and
.CW string
is
.CW IADDC ,
which both generators punt to the interpreter, so its counts go through the C
.CW AINC / ADEC .
An A/B against those three moved
.CW call
+2.5 per cent and
.CW string
\-12 per cent, in opposite directions, which is code layout.
.PP
So
.CW disbench
grew a seventh test,
.CW ptr :
one
.CW a[i&1]
per iteration, an
.CW IMOVP
with a memory source, which is the one Dis instruction that calls BOTH
barriers.  Six interleaved pairs, host emu,
.CW "-n 3000" ,
with
.CW array
as the control:
.P1
            base           atomic
array    690-752 ms      688-752 ms      (flat: no barrier)
ptr      841-849 ms     2238-2432 ms     2.75x
.P2
About 5 ns, some 18 cycles, per pointer move for two LDXR/STXR pairs.  The flat
control is what says the instrument measures the sequences rather than the
layout, and 2.75x is the number to argue with when item 2 below is designed:
it is the cost of making one word atomic by retry loop, in a loop that does
nothing else.  The efs suites, which do real work, show no visible change.
.NH 2
6.  And the fact each generator states about itself
.LP
.CW comp-aarch64.c
declared
.CW "int jitrefsatomic = 1"
and said in a comment that
.CW disinit()
refuses to run the JIT and the parallel VM together unless it is 1.  Neither
half was true: one file out of twelve declared it, and nothing read it.
.PP
Every generator now declares its own answer, each read off its emitted code at
the four
.CW Heap.ref
sites rather than inferred from the architecture:
.CW aarch64
and
.CW arm64
1;
.CW 386 ,
.CW amd64 ,
.CW arm ,
.CW mips ,
.CW power
and
.CW sparc
0, all six emitting a plain read-modify-write;
.CW riscv32 ,
.CW riscv64
and
.CW thumb
1, because they are stubs that emit nothing at all.
.PP
A first pass at that table grepped for atomic mnemonics and would have recorded
.CW 386 ,
.CW amd64
and
.CW mips
as atomic.  All three matched on something else \(em x86
.CW XCHG
between registers is not a locked operation \(em and reading the four sites gave
the opposite answer for all three.  The lesson is the one this tree keeps
relearning: grep what the code
.I emits ,
not what the architecture can express.
.PP
The refusal still cannot be wired, because there is no
.CW parallelvm
switch in this tree to gate on.  What is wired is reporting:
.CW "echo sched >/dev/sysctl"
ends its GC-COUNTS line with
.CW "jitrefsatomic 1 cflag 1" ,
so a board states what its generator does.
.NH 1
Order, and what not to do
.LP
.P1
1  comp-arm64.c atomic refcounts      DONE; 2.75x on a pointer-move loop
2  gclock()/gcunlock()                the lost update; gcdepth into Pctx
3  the inxec handshake                barriers both halves, and xec.c:2533
4  stoptheworld() around emu's rungc  or item 1 cannot be exercised at all
5  Phase 1b (curP as a register)      without it two executors share R
6  Phase 4 (a lock per channel)       without it isend/irecv corrupt stacks
7  per-processor magazines            throughput only; measure first
8  per-processor accounting           throughput only
.P2
.PP
.B "That list changed, and the audit in sections 3 to 4b is why."
What used to be item 2, "the Setmark barrier, by design -- the only correctness
hole in the GC", is not a hole:
.CW propagator
is a constant and
.CW Heap.color
an aligned
.CW int ,
so two mutators running the barrier write identical bits.  The lost update it
described is real and lives in
.CW gclock() ,
which is not idempotent, and the
.CW nprop
half of it is mutator-versus-collector and already covered in the kernel by
.CW stoptheworld() .
Items 3 and 4 are new: the safepoint handshake has no memory barrier at either
end and one of its two sites publishes in the wrong order, and
.CW emu
has no
.CW stoptheworld()
at all, which matters because item 1's whole stated purpose is to make
development under
.CW emu
possible.
.PP
.B "None of it is a code change in this tree, deliberately."
.CW npctx
is 1 and nothing assigns it, so
.CW othersrunning()
is always 0 and every case above is latent.  A concurrency fix that cannot be
exercised is the one thing not to ship on the strength of an argument, however
carefully the argument is written down \(em so this is written down instead.
.PP
.B "Where the infrastructure already is, which is less work than it sounds."
.CW Pctx ,
.CW curR ,
.CW progreg() ,
the
.CW inxec
safepoint and
.CW stoptheworld()
live entirely in
.CW include/interp.h ,
.CW os/inferno/port/dis.c
and
.CW os/inferno/port/proc.c .
Every board compiles all three, so there is nothing per-board to port: it is in
all seventeen by construction, and what was unverified was only that they still
build and boot with it.  They do \(em seventeen build, and raspi3b, raspi4,
virtarm64, sifiveu, virt, virts, virt32 and virt32s boot with their marker sets
unchanged.
.CW os/inferno/port/dis.c
is also why the uniprocessor boards get it free: its own comment records that
.CW othersrunning()
is 0 there and
.CW stoptheworld()
returns without waiting.
.B "And parallelvm=1 should not be switched on at the end of this list either."
The
.CW multicore
branch's own numbers are the reason: pc64 pooled three failures in sixteen boots
at
.CW parallelvm=1
against none in sixteen at 0, "bad frame" on eleven boots of sixteen, and an
undiagnosed
.CW "incref: bad r 0x300000003" .
Those were measured with Phase 4 absent, so items 2 to 4 above may well be their
explanation \(em but that is a hypothesis, and the way to test it is to fix 1 to
4 and then re-run
.I their
acceptance numbers, not to assume the list was complete.
.PP
The destination this tree has been working towards is the infrastructure in place
with the switch absent or 0, which is where it is now.  Nothing in this survey
changes that; it says what the switch would need to become safe.
