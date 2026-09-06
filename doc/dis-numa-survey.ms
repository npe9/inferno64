.TL
Is libinterp correct on a multicore, big.LITTLE, NUMA machine?
.AU
.PP
.NH 1
The question, and the short answer
.PP
The question is whether the Dis runtime in
.CW libinterp
is correct on a modern machine: several processors, asymmetric cores,
and memory that is nearer to some processors than others.  The answer
has three parts, because those are three different problems and
.CW libinterp
fails them in three different ways.
.IP \(bu
.B "Multiprocessor: not correct."
Reference counting is not atomic on the boards that have more than one
processor, and it is not atomic in
.I any
of the three code generators that are still live.  The collector's
shared state has no ordering of any kind.
.IP \(bu
.B "Asymmetric cores: correct, but not fair."
Nothing breaks.  The one scheduling mechanism the interpreter has is a
count of instructions, and on cores of different speeds a count of
instructions is not a time slice.
.IP \(bu
.B "NUMA: correct, and blind."
Nothing breaks.  There is no concept of a processor, a node, or
locality anywhere in the runtime; there is one arena per pool behind
one lock.
.PP
Sorting them that way is the useful part.  The first must be fixed
before a second interpreter runs at all.  The second is a design
question that only appears on a big.LITTLE part.  The third costs
throughput and costs nothing in correctness.
.NH 1
What holds it together today
.PP
.CW libinterp
is correct today for one reason, and the reason is not written down
anywhere in
.CW libinterp :
only one program is inside
.CW xec()
at a time.  Everything below is a place where that serialisation is
load-bearing in a way the code does not say.  This document is a list
of those places, in the order they start to matter as the lock is
removed.
.PP
The companion documents are
.CW doc/dis-parallel-plan.ms ,
which is the plan for removing it, and
.CW doc/multicore-plan.ms ,
whose own NUMA section covers the same ground for the
.I kernel .
This one is about the runtime.
.NH 1
Breaks first: any multiprocessor
.NH 2
Reference counts are not atomic on arm64
.PP
.CW interp.h
defines
.CW AINC
and
.CW ADEC
as calls to
.CW ainc
and
.CW adec ,
and
.CW libinterp
uses them ninety-five times across twelve files.  Hosted, they are
.CW __atomic_add_fetch
with
.CW __ATOMIC_SEQ_CST
.CW ( emu/port/atomic.c ).
On amd64 and 386 they are
.CW "LOCK; XADDL"
.CW ( libkern/ainc-amd64.s ),
and on riscv64 an
.CW AMOADDW
.CW ( libkern/ainc-riscv64.s ).
Those are right.
.PP
There is no
.CW ainc-arm64.s .
What the arm64 boards link is this, from
.CW os/inferno/virtarm64/archvirtarm64.c
and its copy in
.CW os/inferno/raspi3b :
.IP
.nf
int
ainc(int *addr)
{
	int s, r;

	s = splhi();
	r = ++*addr;
	splx(s);
	return r;
}
.fi
.PP
That is interrupt masking, which is mutual exclusion against the
.I current
processor and nothing else.  The in-tree comment says so \- "same
uniprocessor assumption
.CW cmpswap
above already makes (MAXMACH is 1 on this board)" \- and it is not dead
code: the board configuration
.CW os/inferno/raspi3b/raspi3b
lists
.CW archvirtarm64
among its objects.
.PP
arm64 is where big.LITTLE lives.  So the single most common shape of
the machine in the question is the one shape whose reference counting
is a plain read-modify-write.  Two cores dropping the last two
references to the same object both see 1 and both free it, or both see
2 and neither does.
.NH 2
Reference counts are not atomic in the code generators either
.PP
This one does not depend on the board, and it was the surprise.  Fixing
.CW ainc
would not be enough, because compiled Dis does not call it.  The write
barrier is emitted inline, and in all three live backends it is a
non-atomic read-modify-write.
.PP
.CW comp-arm64.c ,
in
.CW maccolr() :
.IP
.nf
mem(Ldw, O(Heap, ref) - sizeof(Heap), RA1, RA0);
ADD_IMM(RA0, RA0, 1);
mem(Stw, O(Heap, ref) - sizeof(Heap), RA1, RA0);
.fi
.PP
A load, an add and a store.  There is no
.CW LDXR/STXR
pair and no LSE
.CW LDADD .
.PP
Reading that closely turned up something bigger than the atomicity, and
it is fixed:
.CW Ldw
and
.CW Stw
are the file's own names for
.I 64-bit
load and store, and
.CW Heap.ref
is an
.CW int
at offset 4 with
.CW Type*
.CW t
at offset 8, so all four reference-count sites were reading and writing
both fields at once.  The decref then tested the whole 64-bit result
for zero, which is "is
.CW ref-1
together with the low half of
.CW t
zero?" \- never true for a live pointer, so the destroy branch was
unreachable and the store put
.CW ref
back as 0 on an object that stayed linked.  The hosted arm64 JIT died on
every run with
.CW "marklist: bad container ... ref 0" .
.CW Ldw32/Stw32
fixes it, the same width mistake
.CW os/inferno/virtarm64/l.s
records
.CW _tas
making on
.CW Lock.key ,
in a third place \- and the colour code a few lines below in the same
function had it right all along.
.PP
So the barrier is now correct on one processor and still not atomic on
two.  What follows is about the second half.
.CW comp-amd64.c
and
.CW comp-386.c
emit
.CW Oincrm
and
.CW Odecrm ,
which are
.CW INC
and
.CW DEC
on memory with no
.CW LOCK
prefix \- there is no
.CW LOCK
anywhere in either file.  On x86 that is atomic against an interrupt on
the same core and not against another core, which is the classic lost
update.
.PP
The same macro then reads
.CW h->color ,
compares it against
.CW mutator ,
stores
.CW propagator
back, and sets
.CW nprop \-
all plain accesses.  That is the entire tricolour write barrier, run on
every pointer store in compiled code, with no atomic operation in it.
.PP
Two things follow.  The first is that this is currently latent on the
native boards, because every one of them defines
.CW "int cflag = 0"
and interprets \-
.CW pc64.c ,
.CW virtarm64.c
and
.CW raspi3b.c
all do.  Hosted
.CW emu
defines
.CW "int cflag = 1"
.CW ( emu/port/dis.c )
and compiles by default, which is why the parallel work in
.CW doc/dis-parallel-plan.ms
is done under
.CW -c0 .
The second is that Phase 6 of that plan is not optional decoration: it
is where the write barrier becomes atomic, and until it does, a
parallel interpreter is correct only with the code generators switched
off.
.NH 2
The collector's state has no ordering at all
.PP
There is not one memory barrier in
.CW libinterp .
No
.CW coherence() ,
no
.CW __atomic ,
nothing.  Every word the collector and the mutator share is a plain
.CW int :
.CW gccolor ,
.CW mutator ,
.CW marker ,
.CW sweeper ,
.CW nprop ,
.CW gchalt
.CW ( libinterp/gc.c
lines 24 to 39), and
.CW h->color
on every object.
.PP
The epoch advance is
.CW gccolor++
followed by recomputing
.CW mutator ,
.CW marker
and
.CW sweeper
as
.CW gccolor%3
and its two predecessors.  With one interpreter that is a sequence
point and a set of values every reader agrees on.  With two, a mutator
can be colouring objects against one epoch's
.CW mutator
while the collector sweeps against another's
.CW sweeper ,
and no barrier makes the four writes visible together.
.PP
.CW gchalt
deserves naming separately: it is the "do not collect now" flag, read
at the top of
.CW rungc()
and set elsewhere, and a flag that stops a collector has to be visible
to the collector to work.
.NH 2
The root set, which is already in hand
.PP
The collector takes
.CW Prog->reg
as its root set, and
.CW Prog->reg
is a whole quantum out of date for whichever program is running.  This
is the same problem as the rest of this section and it is the one piece
already dealt with:
.CW progreg()
in
.CW libinterp/xec.c
puts the question in one function, and
.CW doc/dis-parallel-plan.ms
section on Phase 5a is the argument.  Noted here so the list is
complete.
.NH 1
Breaks nothing, but is wrong-shaped: asymmetric cores
.NH 2
The quantum is a count of instructions
.PP
.CW "PQUANTA = 2048"
.CW ( include/interp.h
line 30) is the whole of the interpreter's fairness mechanism.  Every
program gets 2048 Dis instructions and then
.CW xec()
returns.
.PP
On cores of the same speed that is a time slice by proxy.  On a
big.LITTLE part it is not: the same 2048 instructions are a
significantly longer wall-clock slice on a little core than on a big
one, so a program's share of the machine depends on which cluster it
lands on, and a program that migrates changes its own latency
behaviour without changing anything about itself.
.PP
This is a design observation and not a bug.  Nothing computes a wrong
answer.  But any scheduling policy built on top of
.CW PQUANTA \-
fairness, priority, latency bounds \- inherits the assumption that all
processors retire instructions at the same rate, and on the machine in
the question they do not.  The fix, when it is wanted, is to make the
quantum a deadline rather than a count, which needs a clock the
interpreter currently never reads.
.NH 2
There is no cache-line concept in the runtime
.PP
.CW libinterp
has no notion of a cache line.  The only
.CW CACHELINESZ
in the tree are in device drivers, and one of them
.CW ( os/inferno/pc64/audio.h )
says 8.
.CW os/inferno/raspi3b/usbdwc.c
knows the Cortex-A53 line is 64 and aligns to it, which is a driver
getting it right locally.
.PP
Where this will be felt is the object header:
.IP
.nf
struct Heap
{
	int	color;		/* Allocation color */
	int	ref;
	Type*	t;
	ulong	hprof;
};
.fi
.PP
.CW color
and
.CW ref
are adjacent 32-bit fields in one 64-bit word, immediately before every
Dis object.
.CW ref
is the field an atomic increment would have to operate on, and
.CW color
is written by the collector, so once both are done properly they
contend in the same word on every object that two processors touch.
.PP
big.LITTLE adds a second-order version of this: clusters can report
different cache geometry, and code that hard-codes a line size gets it
wrong on one cluster or the other.  Since
.CW libinterp
hard-codes nothing, it has nothing to get wrong \- but it also has no
way to align anything deliberately when the time comes.
.NH 1
Costs throughput, not correctness: NUMA
.NH 2
One arena, one lock, no locality
.PP
There is no affinity, node, or locality concept anywhere in
.CW libinterp
or
.CW emu .
Allocation is three pools \- main, heap and image \- and each is one
.CW Lock
in front of one free-list root and one arena chain
.CW ( os/inferno/port/alloc.c ,
.CW "struct Pool" ).
Every allocation and every free on every processor goes through the
same word.
.PP
On a NUMA machine there is no first-touch policy, no node-local arena
and no attempt to reuse a block on the processor that freed it.  A
block freed on one node is handed to the next caller wherever it runs,
so a long-running system tends towards every processor's working set
being spread evenly over every node, which is the worst arrangement
available.
.PP
This is Phase 3 of
.CW doc/dis-parallel-plan.ms ,
and the ordering there is right: per-processor caches are worth doing
for the lock contention alone on a plain SMP machine, and a per-node
policy is a later refinement of the same mechanism, not a separate one.
.NH 2
False sharing in the pool header
.PP
.CW "struct Pool"
puts
.CW Lock
.CW l
in the middle of the statistics it protects \-
.CW cursize ,
.CW arenasize ,
.CW hw ,
.CW nalloc ,
.CW nfree ,
.CW lastfree \-
and the pools are an array,
.CW "Pool pool[MAXPOOL]" .
So the lock word and the counters written under it share cache lines,
and adjacent pools share cache lines with each other.  Every
acquisition invalidates the line for every other processor spinning on
it, and the counters guarantee the line is dirtied on every operation
rather than just on contention.
.PP
This costs nothing today, with one interpreter, and is the first thing
a profile would show on a machine with several.
.NH 2
The root list is global by design
.PP
.CW rungc()
walks
.CW isched.head ,
the list of every
.CW Prog
in the system.  Phase 2a of the parallel plan deliberately left that
list on
.CW isched
while moving the run queue into a per-context
.CW Pctx ,
because splitting the root set is how a collector loses objects.
.PP
That decision is correct and it has a NUMA consequence worth stating:
every collection touches every program on every node, so collection
cost does not partition even when the programs do.  A per-node
collector is not a small change to this design; it is a different
collector.
.NH 1
What is already right
.PP
Worth saying, so the list above is read in proportion.
.IP \(bu
The reference-counting
.I discipline
is uniform.
.CW Heap.ref
is an
.CW int
everywhere, deliberately \- the comment in
.CW interp.h
says "so that one
.CW ainc
serves them all" \- so making it atomic is one change in one place per
architecture, not an audit of ninety-five call sites.
.IP \(bu
The hosted build is already correct on all of these except the code
generators, because
.CW emu
uses real C11 atomics.
.IP \(bu
The write barrier the concurrent collector wants already exists and
already runs on every pointer store.  As
.CW doc/dis-parallel-plan.ms
notes, that makes concurrent marking cheaper here than the literature
assumes.  It has to become atomic; it does not have to be invented.
.IP \(bu
Nothing in the runtime hard-codes a processor count, a cache geometry,
or a memory layout.  There is nothing to un-assume \- only things to
add.
.NH 1
The order the work goes in
.PP
Following the same rule as the rest of this branch: fix what is wrong
before adding what is missing.
.IP 1.
.B Done .
.CW libkern/ainc-aarch64.s
is an
.CW LDXRW/STXRW
loop, and the two C definitions are gone.  It follows the operand-order
and register-width traps that
.CW os/inferno/virtarm64/l.s
already records from
.CW _tas ,
because both of them assemble cleanly and do the wrong thing.  Checked
by booting virtarm64 under qemu with each implementation and diffing
the console: identical but for the build date, one kprof sample and the
qemu pid.
.IP 2.
The collector's shared words become atomic, and
.CW h->color
with them.  This is Phase 5 of the parallel plan and it is the gate on
everything else.
.IP 3.
The code generators' write barrier becomes atomic \- Phase 6.  Until
then a parallel interpreter is correct only with
.CW cflag
at 0, which is what every native board already does.
.IP 4.
Per-processor allocation caches \- Phase 3 \- for lock contention, on
any multiprocessor.
.IP 5.
Node affinity on top of those caches, for NUMA proper.
.IP 6.
A quantum that is a deadline and not an instruction count, if and when
a big.LITTLE part is a target rather than a hypothetical.
.PP
Items 1 through 3 are correctness.  Items 4 through 6 are performance.
.PP
Read "only item 1 is worth doing now" as a statement about
.I testability ,
not about priority.  Items 2 and 3 are the gate: until the collector's
shared words and the code generators' write barrier are atomic, a
second interpreter is not correct, and no amount of the rest makes it
so.  They are not done yet because neither can be verified at one
interpreter \- there is nothing for the atomicity to protect against
until something runs concurrently, so landing them now would mean
landing untested code that looks finished.  Item 1 was different: it is
small, it is self-contained, and a differential boot tests it today.
