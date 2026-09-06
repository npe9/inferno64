.TL
Native Inferno on Multiple Cores
.AU
Inferno multicore
5 September 2026
.PP
This is a plan for making the native Inferno kernel
.CW ( os/inferno )
run on more than one processor.  It is written against a measurement,
not against an idea of where the tree is: the pc64 kernel already
starts its application processors, already schedules Dis on them, and
already dies on them within a second.  The work is not to add SMP, and
it is not to make the interpreter parallel \- both were built already.
The work is to make what is already there correct.
.PP
Two other systems are the sources.  9front supplies the kernel-side
idiom \- the run queue, the
.CW "ilock / iunlock"
discipline, cross-processor TLB invalidation \- and a copy of the
relevant flavour is in this tree at
.CW os/9front .
The hosted emulator supplies both the process structure
.CW ( emu/port/kproc-pthreads.c
gives every
.CW Proc
a host thread) and, less obviously, a working answer to the hardest
question here.  Section 3 is about that answer, because the shape of
.CW acquire()
and
.CW release()
invites exactly the wrong conclusion about it.
.NH 1
What the tree does today
.PP
The kernel measured is
.CW Inferno/amd64/ipc64 ,
built 31 August 2026, run under QEMU 9 on an arm64 macOS host, so pure
TCG with no acceleration.  The invocation is the one
.CW os/inferno/pc64/qemu-boot.sh
documents, with
.CW -smp
added:
.IP
.nf
qemu-system-x86_64 -m 512 -smp N -kernel ipc64 \e
	-append 'console=0' \e
	-netdev user,id=net0 -device virtio-net,netdev=net0 \e
	-nographic -no-reboot
.fi
.PP
With
.CW -smp
.CW 1
the kernel boots to
.CW "Welcome to Inferno..."
and reaches a shell.  It then loops printing
.CW "sh: true: file does not exist" .
That is a root-filesystem gap in this build; it happens on one
processor as well, it is not a multiprocessor symptom, and section 5.1
deals with it because it stands between this plan and a usable test.
.PP
With
.CW -smp
.CW 2
the second processor comes up \-
.CW "cpu1: 1000MHz AuthenticAMD"
prints from
.CW squidboy
\- the kernel reaches
.CW "Welcome to Inferno..." ,
and then dies.  Four consecutive runs of the identical command died
four different ways:
.IP
.nf
panic: movp: bad sv 0x18
panic: cpu0: ilockdepth 1, sched called from 0x27344e
panic: cpu0: ilockdepth -1, sched called from 0x26ac83
panic: cpu0: ilockdepth 1, sched called from 0x26ac83
.fi
.PP
With
.CW -smp
.CW 4
all three application processors identify themselves, and the kernel no
longer survives as far as the greeting; it dies inside
.CW schedinit
with
.IP
.nf
decref-underflow: a1fe60 in main: ...
panic: decref pc=0x263997 old=0
.fi
.PP
The failure is not a hang, not a missing bring-up path, and not
deterministic: a different race wins each run, and adding processors
makes it win sooner.
.NH 2
Where those addresses are
.PP
The kernel carries its symbol table \- 428880 bytes of it, after 1030208
of text and 6780896 of data, behind the 40-byte amd64 header
.CW ( magic
.CW 0x8a97 ,
.CW entry
.CW 0x200000 ,
matching the
.CW etext
.CW 0x2fb840
in the boot log).  Resolving the three program counters against it:
.IP
.nf
0x26ac83  ->  acquire+0xff
0x27344e  ->  irqhandled+0x113
0x263997  ->  pathclose+0x18
.fi
.PP
Those are not generic.
.CW acquire
is the Dis scheduler's own entry into the run queue,
.CW os/inferno/port/dis.c ,
line 901, and its last statement is
.CW sched() ;
the panic says that on one run it got there with
.CW m->ilockdepth
at
.CW \-1 .
.CW irqhandled
is the interrupt path.  And
.CW pathclose
in
.CW os/inferno/port/chan.c ,
line 352, is a kernel
.CW Path ,
not a Dis heap object \- the pool named in the message is
.CW main ,
the kernel's own.
.PP
That last one narrows usefully.
.CW incref
and
.CW decref
in
.CW os/inferno/port/chan.c
are compare-and-swap loops over an
.CW s32 ,
so the count itself cannot lose an update.  An underflow there is
therefore an
.I ownership
error \- a reference released by something that did not hold one \- and
not a torn counter.  That is a name-space or channel lifetime bug under
concurrency, and it wants reading, not a lock.
.PP
One caveat, stated because this document's rule is that nothing in it is
remembered: those addresses are against the 31 August binary, and
several sources it was built from have changed since
.CW ( os/inferno/pc64/pc64dev.c
and
.CW pc64.root.s
are dated 4 September).  Rebuild before trusting them; see 6.1.
.NH 1
What is already multiprocessor
.PP
Rather more than one would guess.  None of the following needs to be
built.
.IP \(bu
.B "Application-processor bring-up."
.CW os/inferno/pc64/pc64
configures
.CW archacpi
and
.CW archmp ,
each with
.CW mp ,
.CW apic
and
.CW squidboy .
.CW main.c
calls
.CW arch->intrinit() ,
which launches the other processors;
.CW os/inferno/pc64/squidboy.c
holds a complete
.CW mpstartap
(warm-reset vector, Universal Startup Algorithm,
.CW lapicstartap )
and a complete
.CW squidboy
that runs
.CW machinit ,
.CW mmuinit ,
.CW cpuidentify ,
.CW syncclock ,
.CW lapicinit ,
.CW lapiconline ,
.CW timersinit
and enters
.CW schedinit .
The boot log above is that code working.
.IP \(bu
.B "Per-processor"
.CW m
.B and
.CW up .
They are registers \- R15 and R14 \- and
.CW os/inferno/pc64/l.s
reloads
.CW m
from
.CW GS:(0)
on kernel entry and
.CW up
from
.CW 16(RMACH) .
.CW os/inferno/pc64/mmu.c
writes the per-processor
.CW GSbase
and
.CW KernelGSbase
to
.CW &machp[m->machno] ,
and
.CW mmuinit
is called by
.CW squidboy ,
so every application processor gets its own.
.CW MAXMACH
is 128.
.IP \(bu
.B "Real spin locks."
.CW os/inferno/port/taslock.c
is the genuine article: test-and-set,
.CW coherence()
before the release store,
.CW "ilock / iunlock"
raising and lowering
.CW spl
and keeping
.CW m->ilockdepth .
It is not a uniprocessor stub.
.IP \(bu
.B "Per-processor timers."
.CW os/inferno/port/portclock.c
already carries
.CW "Timers timers[MAXMACH]"
and
.CW intrcount[MAXMACH] ,
indexed by
.CW m->machno .
.IP \(bu
.B "Atomic reference counts, in both worlds."
The kernel's
.CW incref / decref
are compare-and-swap loops
.CW os/inferno/port/chan.c ,
lines 86 and 104.  The interpreter's are
.CW "AINC / ADEC" ,
defined in
.CW include/interp.h
and implemented for this architecture as
.CW "LOCK; XADDL"
in
.CW libkern/ainc-amd64.s ;
.CW libinterp/heap.c
uses them for every
.CW Heap
and
.CW Type
reference it touches.
.IP \(bu
.B "A run queue of the shape 9front ships."
.CW os/inferno/port/proc.c
has one global
.CW "Schedq runq[Nrq]"
with
.CW runvec
and
.CW nrdy
under
.CW lock(runq) .
That is not a defect to fix on the way to multicore:
.CW os/9front/port/proc.c
in this same tree declares
.CW "Schedq runq[Nrq]"
at line 35 and runs on many processors.  Per-processor run queues are a
scaling question for section 5.4, not a correctness one.
.IP \(bu
.B "Several interpreters."
See the next section.  This is the surprise.
.NH 1
What emu already answered
.PP
It is natural to read
.CW acquire()
and
.CW release()
as two halves of a single token \- one interpreter at a time,
system-wide \- and to conclude that parallel Dis is the whole job.
That reading is wrong, and the tree says so in two places.
.PP
.CW include/interp.h ,
at the definition of
.CW "AINC / ADEC" :
.QP
the scheduler genuinely runs multiple native threads executing Dis
bytecode concurrently ... so two threads touching the same object's
.CW ->ref
field is a real, not hypothetical, race.
.PP
And a long comment in
.CW vmachine()
itself
.CW ( emu/port/dis.c ),
which records the investigation: multiple
.CW vmachine
kernel processes, spun up by
.CW release()
whenever a process blocks, each independently pull programs off
.CW isched.runhd
and call
.CW xec()
in parallel.  The code agrees.
.CW release()
ends with
.IP
.nf
kproc("dis", vmachine, nil, KPDUP);
.fi
.PP
on the path where both wait queues are empty \-
.CW os/inferno/port/dis.c ,
line 978, and the same line without
.CW KPDUP
at
.CW emu/port/dis.c ,
line 1071.  It creates an interpreter; it does not hand
one over.
.CW isched.idle
is a flag saying whether an interpreter is currently waiting for work,
not a mutex.
.PP
That comment also records what was tried and rejected.  A single global
lock around Dis execution, taken at the end of
.CW acquire
and dropped at the start of
.CW release ,
deadlocked
.CW "sh -c 'echo a; echo b'" :
the interpreter unwinds errors by
.CW longjmp
back into
.CW vmachine 's
own
.CW while(waserror())
block, jumping straight over the paired
.CW unlock ,
and the lock is then held by nobody forever.  That is a constraint on
every future design here, and it is why the fix that shipped was
atomics on reference counts and no held lock at all.
.PP
Two things follow for this plan.
.PP
First,
.B "Phase 3 is not a phase."
The native kernel has the same structure \- the same
.CW vmachine
loop, the same
.CW release()
spawning another \- so it is already trying to run several interpreters
across several processors.  That is not a thing to build; it is the
thing that is crashing.
.PP
Second, there is a gap the same comment names and does not close: the
JIT.
.CW libinterp/comp-arm64.c
and its siblings emit plain non-atomic load-modify-store for the same
.CW h->ref
field, so the atomics cover the interpreted path only, and everything
in that investigation was validated with
.CW -c0 .
For this plan that is a reprieve rather than a problem:
.CW os/inferno/pc64/pc64
sets
.CW "int cflag=0;"
in its
.CW code
section, so the pc64 kernel interprets.  It is a hard blocker for any
board that wants the JIT and more than one processor, and it should be
written down as such rather than discovered later.
.NH 1
What is actually missing
.NH 2
The Dis run queue is shared and unlocked
.PP
This is the largest single item, and it is visible in ten lines.
.CW vmachine 's
main loop in
.CW os/inferno/port/dis.c
does
.IP
.nf
r = isched.runhd;
if(r != nil) {
	...
	r->xec(r);
	...
	if(isched.runhd != nil)
	if(r == isched.runhd)
	if(isched.runhd != isched.runtl) {
		isched.runhd = r->link;
		r->link = nil;
		isched.runtl->link = r;
		isched.runtl = r;
	}
}
.fi
.PP
with no lock held.
.CW isched.l
guards
.CW vmq
and
.CW idlevmq
in
.CW acquire
and
.CW release ,
but not
.CW runhd
and
.CW runtl
here.  The triple-nested
.CW if
is a re-check that the list did not move under the interpreter, which is
an acknowledgement of the race rather than a defence against it: two
interpreters can pass all three tests and then both rewrite the list.
.CW "movp: bad sv"
is what a program reached through a corrupted list looks like from
inside
.CW xec .
.NH 2
Kernel object lifetimes
.PP
The
.CW pathclose
underflow of section 1.1.  The counter is atomic, so this is an
ownership error in the name-space code, reachable only when two
processors walk it at once.  Expect siblings: every
.CW Chan ,
.CW Path ,
.CW Pgrp
and
.CW Egrp
release path is a candidate, and the audit is the deliverable, not the
one fix.
.NH 2
The lock-depth accounting
.PP
.CW ilock
increments
.CW m->ilockdepth
and
.CW iunlock
decrements it, in the same pair, both under
.CW splhi ,
so on inspection they balance.
.CW os/inferno/port/proc.c
panics from
.CW sched()
when the depth is not zero, and the two panics above came from
.CW acquire+0xff
and
.CW irqhandled+0x113 .
Both panics printed
.CW "last lock 0x0 at 0x0" ,
so
.CW up->lastilock
was nil and whatever unbalanced the count was not the most recent
.CW ilock
on that processor.  A depth of
.CW \-1
means an
.CW iunlock
landed on a
.CW Mach
that never took the matching
.CW ilock ,
which is what happens if a process changes processor between the two.
.NH 2
There is no cross-processor TLB invalidation
.PP
.CW os/inferno/pc64/fns.h
defines
.IP
.nf
#define mmuflushtlb() putcr3(getcr3())
.fi
.PP
and
.CW invlpg
in
.CW mmu.c
is likewise local.  Nothing sends the other processors anything.
.CW mpstartap
copies the top-level page-table entries out of
.CW MACHP(0)->pml4 ,
so the processors share page tables, and every runtime change to a
kernel mapping \-
.CW vmap ,
.CW kmap ,
.CW xspanalloc
growth \- is visible to the processor that made it and stale everywhere
else.
.PP
This matters less here than it would in Plan 9, and the plan should say
so rather than inflate it: native Inferno has no per-process address
space to tear down.
.CW schedinit
in
.CW os/inferno/port/proc.c
has
.CW mmurelease
commented out with the note that memory is linear.  So the exposure is
kernel mappings only.  It is still real, and it is still unimplemented.
.PP
The idiom to copy is in the tree:
.CW procflushmmu
at line 1483 of
.CW os/9front/port/proc.c
sets
.CW MACHP(nm)->flushmmu
on every processor that needs it and waits for each to take its own
clock interrupt and flush.  No interprocessor interrupt is required for
that shape, which suits a kernel whose IPI path
.CW ( lapicicrw
in
.CW os/inferno/pc/apic.c )
is used today only to start processors.
.NH 2
The collector's controls are not atomic
.PP
The reference counts were made atomic; the collector's own were not.
.CW include/interp.h
has
.IP
.nf
#define Setmark(h)  if((h)->color!=mutator) { \e
                        (h)->color = propagator; nprop=1; }
#define gclock()    gchalt++
#define gcunlock()  gchalt--
#define gcruns()    (gchalt == 0)
.fi
.PP
.CW gchalt
and
.CW nprop
are plain
.CW int s
in
.CW libinterp/gc.c .
.CW gchalt++
is a read-modify-write, and
.CW "gclock / gcunlock"
is precisely a nesting count that two processors will corrupt.  The
colours
.CW ( mutator ,
.CW propagator )
are global, and
.CW libinterp/gc.c
flips epochs on
.CW "nprop == 0" .
With several interpreters demonstrably live, this is Phase 1 work.
.NH 1
The phases
.NH 2
Phase 1 \- a test that can fail
.PP
There is no usable pass criterion today, and this must come first or
nothing after it can be reported honestly.
.IP 1.1
Build the kernel from this tree.  The measurements above are against a
31 August binary whose sources have moved; the reproducer and the source
must agree before any address in section 1.1 is chased.
.IP 1.2
Close the root-filesystem gap behind
.CW "sh: true: file does not exist" ,
which is present at
.CW -smp
.CW 1
and makes "reaches a shell and stays there" unobservable.
.IP 1.3
Build a self-driving load, because the console cannot drive one:
.CW qemu-boot.sh
records that
.CW console=0
is output-only and that no keystroke can be delivered over this harness
at all.  So the exercise must be a boot-time Dis program \- allocate
hard, pass references between programs, touch the file system and the
IP stack \- that prints a fixed completion marker and its own
per-processor counters.
.PP
Verified by: a script that boots
.CW N
times at each of
.CW -smp
1, 2, 4 and 8 and reports how many runs reached the marker.  Repetition
is the criterion, not a single pass: every failure found so far was a
race that won on some runs and not others.
.NH 2
Phase 2 \- one correct multiprocessor kernel
.IP 2.1
Lock
.CW isched.runhd
and
.CW isched.runtl ,
under the constraint section 3 records: no lock may be held across
.CW xec() ,
because error unwinding
.CW longjmp s
out of it.  A short lock around the list surgery only, with the
interpreter running outside it, is the shape that fits.
.IP 2.2
Find the
.CW ilockdepth
imbalance, starting at
.CW acquire+0xff
and
.CW irqhandled+0x113 ,
re-resolved against the Phase 1.1 kernel.
.IP 2.3
Audit kernel object lifetimes, starting from the
.CW pathclose
underflow and covering the
.CW Chan ,
.CW Path ,
.CW Pgrp
and
.CW Egrp
release paths.
.IP 2.4
Make
.CW gchalt ,
.CW nprop
and the mutator/propagator epoch safe against concurrent mutators.
.IP 2.5
Audit the remaining kernel globals written from more than one
processor: what
.CW machinit
does not reset, the
.CW active
structure, and the allocators \-
.CW os/inferno/port/alloc.c ,
.CW xalloc.c ,
.CW allocb.c .
.IP 2.6
Implement cross-processor TLB invalidation on the
.CW procflushmmu
pattern.
.PP
Verified by: Phase 1's harness, clean at every processor count.
.NH 2
Phase 3 \- measure, then decide
.PP
Only with a kernel that survives is the interesting question askable:
does throughput rise with processors?  Two outcomes, and the plan
should not pretend to know which:
.IP \(bu
If it does, the work is ordinary scaling \- section 5.4.
.IP \(bu
If it does not, the shared heap and its single collector are the
ceiling, and the answer is
.I n
independent schedulers, each with its own heap and collector.  That is a
close fit to the task and message-queue model
.CW doc/osprey-plan.ms
describes for this same branch, and it scales.  Its price is that a
channel send between shards can no longer pass a pointer: it becomes a
deep copy, or it becomes illegal.  That is a change to Limbo as programs
experience it, and it should be bought only against a measurement, never
on expectation.
.PP
The JIT gap of section 3 is decided here too: either the code generators
learn to emit atomic reference-count updates, or boards that want the
JIT stay on one processor.  Both are honest; leaving it unstated is not.
.NH 2
Phase 4 \- scale
.PP
Per-processor run queues in
.CW os/inferno/port/proc.c ,
processor affinity, and whichever of the two Phase 3 outcomes the
measurement chose.
.NH 1
Ground rules
.PP
Every claim in this document about what the kernel does is either a
citation to a file and line in this tree or a quotation from a boot log
produced by the command in section 1.  Where a claim rests on the 31
August binary rather than on current source, it says so.  Phase 2 in
particular must not be reported as done on the strength of one clean
boot: the failures it exists to remove are races, a single pass is not
evidence, and the repetition is the test.
