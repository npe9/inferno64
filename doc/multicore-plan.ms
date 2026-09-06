.TL
Native Inferno on Multiple Cores
.AU
Inferno multicore
5 September 2026
.PP
This is the plan for making the native Inferno kernel
.CW ( os/inferno )
run on more than one processor, and the record of what building it
found.  It is written against measurements taken from booted kernels
built out of this tree; where a claim rests on anything else it says so.
.PP
Two findings reshaped it, and both belong at the front because they
decide what the word multicore can honestly mean here.
.IP 1.
.B "The interpreter cannot be made parallel."
Dis has one register set, a single global
.CW REG
.CW R
in
.CW libinterp/xec.c ,
and every JIT backend compiles that object's absolute address into the
code it emits.  Two processors interpreting at once share one register
file.  This is not a lock to be refined later; it is what the
interpreter is.  Section 3.
.IP 2.
.B "The uniprocessor baseline is not stable."
This tree panics at
.CW -smp
.CW 1 ,
and did so before any of this work: general protection violations, page
faults and Dis heap double-frees, at roughly half of all boots.  It is a
known bug with a long hunt already recorded in
.CW doc/inferno-ports.ms .
Multicore cannot be demonstrated on top of it.  Section 6.
.PP
So the deliverable is a multiprocessor
.I kernel
\- interrupts, drivers, the IP stack, the file system, and every kernel
process spread across every processor \- with the Dis interpreter
serialised behind one lock.  That is a real and useful thing, and it is
not parallel Limbo.  Saying so plainly is worth more than letting the
word imply what the interpreter cannot do.
.NH 1
What was measured
.PP
The kernel is built from this tree
.CW ( "cd os/inferno/pc64; mk install" ,
host tools first in
.CW PATH )
and run under QEMU 9 on an arm64 macOS host, so pure TCG with no
acceleration.  The invocation is the one
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
Every count below is boots of that command, not one run.  This hunt's
failures are races and near-misses; a single pass is not evidence, and
the repetition is the test.
.NH 2
Where the tree started
.PP
The application processors already came up.
.CW cpu1 ,
.CW cpu2
and
.CW cpu3
each printed their own
.CW cpuidentify
line from
.CW squidboy ,
and the kernel then died within a second of
.CW "Welcome to Inferno..." .
Four consecutive runs at
.CW -smp
.CW 2
died four different ways, and
.CW -smp
.CW 4
did not survive as far as the greeting.
.NH 1
What was already multiprocessor
.PP
More than one would guess.  None of this had to be built.
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
.CW squidboy ;
.CW main.c
calls
.CW arch->intrinit() ,
which launches them;
.CW os/inferno/pc64/squidboy.c
holds a complete
.CW mpstartap
and a complete
.CW squidboy .
.IP \(bu
.B "Per-processor"
.CW m
.B and
.CW up ,
in registers R15 and R14, with
.CW os/inferno/pc64/mmu.c
writing a per-processor
.CW GSbase
and
.CW l.s
reloading
.CW m
from
.CW GS:(0)
on kernel entry.
.IP \(bu
.B "Real spin locks"
.CW ( os/inferno/port/taslock.c :
test-and-set,
.CW coherence()
before the release store), and per-processor timers
.CW ( "Timers timers[MAXMACH]" ).
.IP \(bu
.B "Atomic reference counts"
in both worlds:
.CW incref / decref
are compare-and-swap loops in
.CW os/inferno/port/chan.c ,
and the interpreter's
.CW "AINC / ADEC"
are
.CW "LOCK; XADDL"
in
.CW libkern/ainc-amd64.s .
.IP \(bu
.B "A run queue of the shape 9front ships"
\- one global
.CW "Schedq runq[Nrq]"
under
.CW lock(runq) ,
exactly as
.CW os/9front/port/proc.c
declares it at line 35 and runs on many processors.  Per-processor run
queues are a scaling question, not a correctness one.
.NH 1
Two bugs fixed, and how they were found
.NH 2
The trap return reloaded a stale Mach
.PP
.CW os/inferno/pc64/l.s 's
.CW _intrestore
popped
.CW RUSER
and
.CW RMACH
back off the
.CW Ureg
unconditionally.
.CW trap()
can reach
.CW sched() ,
and a process that gives up the processor there may be resumed on a
different one; the scheduler that resumes it leaves the new processor's
.CW Mach
in
.CW RMACH ,
and the return then overwrote that with the processor the trap was
taken on.  The process ran on holding another processor's
.CW Mach ,
reading and writing its fields.
.PP
The symptom was
.IP
.nf
panic: cpu2: ilockdepth -2, last lock 0x0 at 0x0,
	sched called from 0x28dae4		(acquire+0xff)
.fi
.PP
on every
.CW -smp
.CW 2
and
.CW -smp
.CW 4
boot, with the depth reading
.CW -2 ,
.CW -1 ,
.CW 0
and
.CW 1
across four runs of one command.  A depth of
.CW 0
reaching a panic that only fires when the depth is not
.CW 0
is the same fact from the other side: the field was being changed by
the processor that owned the
.CW Mach
while another read it.
.PP
The comment above
.CW _strayintr
says the nested check 9front does was removed
.I "as we are not using different code segments or tasks" .
That check is not about code segments.  It is about more than one
processor, and 9front keeps it \- its
.CW _iretnested \-
for this reason.  Restored, with the frame offset re-derived from this
kernel's own push sequence.
.PP
.CW sched()
went with it: it lowered to
.CW spllo()
unconditionally after
.CW procswitch() ,
handing interrupts back to callers that had raised
.CW spl
themselves.  9front saves and restores; so does this now.
.PP
Measured: four boots at
.CW -smp
.CW 4
before, four
.CW ilockdepth
panics; after, none, and three of four reached the shell and stayed
there.
.NH 2
The interpreter was not serialised at all
.PP
The
.CW "isched.idle / vmq / idlevmq"
handshake in
.CW os/inferno/port/dis.c
looks like a token \- one interpreter at a time \- and is not one.  A counter
between
.CW acquire()
and
.CW release() ,
on a four processor boot, printed
.IP
.nf
nvm: 3 hold the vm
.fi
.PP
\- two and three across three runs.  Two processes holding what has to
be exclusive is already fatal, because what they share is the register
file.
.PP
A retraction belongs here.  The first version of this measurement
counted processes nested inside
.CW vmachine() 's
.CW xec()
call rather than processes holding the VM, and reported
.CW 10 .
That counter was wrong for the purpose: a process that calls
.CW release()
inside a Dis system call and then blocks on I/O is still nested in the
.CW xec
C frame, so the count included processes that had correctly given the
VM up.  The
.CW 10
was quoted in the commit that made this change and in the first version
of this document; the number that supports the claim is two to three,
measured with the lock compiled out and the correct counter left in.
.PP
Replaced with one
.CW QLock .
A
.CW QLock ,
not a
.CW Lock :
the holder blocks in Dis system calls, and
.CW qunlock()
hands the lock to the head of its own FIFO queue rather than dropping
it, so
.CW iyield()
is a real yield.
.CW Proc.vmheld
makes acquire and release idempotent, and that is what lets this
survive the error path \-
.CW propex() / nexterror()
longjmps out of
.CW xec()
straight back to
.CW vmachine() 's
.CW waserror()
block, over any unlock in between.  An earlier attempt at a single Dis
lock was reverted for exactly that reason; the history is in the long
comment in
.CW emu/port/dis.c .
.PP
Two further bugs fell out of making a
.CW QLock
hot for the first time in this kernel, and both are worth knowing about
on their own account.
.IP \(bu
.CW qlock()
never cleared
.CW up->qnext .
A process queued a second time still pointed at whoever followed it the
time before, so the queue became circular;
.CW qunlock() 's
.CW "q->head = p->qnext"
then handed the lock to a process that was not waiting, and the real
waiter was never readied.  The dump showed it plainly:
.CW vmlocked
.CW 1
with no process holding it, and the wait queue reading 12, 11, 12, 11.
.CW eqlock() ,
.CW rlock()
and
.CW wlock()
in the same file all clear it;
.CW qlock()
alone did not, and 9front's does.
.IP \(bu
Idle interpreters cannot
.CW sleep()
on a shared
.CW Rendez ,
which holds exactly one sleeper; a second produced
.CW "double sleep called from vmachine+0x22b" .
They park on a list and are restarted by
.CW ready() ,
as the code this replaces already did.  That list needs a link field of
its own \-
.CW Proc.vmnext \-
because
.CW up->qnext
now belongs to the VM lock's queue.
.PP
Measured:
.CW nvm
never exceeds
.CW 1
at
.CW -smp
.CW 1 ,
.CW 2
or
.CW 4 ,
where it reached two and three before.
.NH 1
Why the interpreter can never be parallel here
.PP
This is the finding that settles the shape of everything after it, and
it is two citations long.
.PP
.CW libinterp/xec.c
line 11 declares
.IP
.nf
REG	R;			/* Virtual Machine registers */
.fi
.PP
one register set for the whole system.
.CW irestore()
loads it from a
.CW Prog
and
.CW isave()
stores it back
in
.CW xec.c ,
line 2280.  Every opcode reads and writes it \- 250 references
in
.CW xec.c
alone.
.PP
And the code generators compile its address in.
.CW libinterp/comp-amd64.c
has eight occurrences of
.IP
.nf
con((uintptr)&R, RTMP);
.fi
.PP
and the other backends match.  So making the register file
per-processor is not a matter of changing a declaration: it is a
rewrite of every opcode and every code generator in the tree.
.PP
There is a second, independent blocker behind it.  The atomics that
protect
.CW Heap.ref
cover the interpreted path only; the JIT emits plain non-atomic
load-modify-store for the same field.  The
.CW emu
comment that records this says everything in that investigation was
validated with
.CW -c0 .
This kernel is safe from it only because
.CW os/inferno/pc64/pc64
sets
.CW "int cflag=0;"
in its
.CW code
section and therefore interprets.  Any board that wants both the JIT
and more than one processor needs that fixed first.
.PP
The honest conclusion: Dis executes one program at a time, system-wide,
and the useful parallelism in a native Inferno is in the kernel around
it.  A Limbo program does not get faster on four processors.  A system
serving files over the network while running Limbo does.
.NH 1
The blocker: the uniprocessor baseline
.PP
After the two fixes above,
.CW -smp
.CW 4
still panicked \-
.CW "movp: bad dv" ,
.CW "decref old=0" ,
page faults \- with
.CW nvm
never above
.CW 1 .
So the remaining failures are not that race.  The control experiment
settles what they are.
.PP
Twenty boots of each of the two kernels, at
.CW -smp
.CW 1 ,
same command, same host:
.IP
.nf
                    panicked   survived
before the VM lock    16/20       4/20
with the VM lock      15/20       5/20
.fi
.PP
The lock does not move it.  One processor: no migration, no shared
.CW Mach ,
no second interpreter, and
.CW nvm
never above
.CW 1 .
This tree has a memory-corruption bug that has nothing to do with more
than one processor, and it fires on about four boots in five.
.PP
The kinds of failure moved even though the rate did not, which is worth
recording but not over-reading.  Before: seven general protection
violations, three page faults, three invalid opcodes, and one each of
.CW smalloc ,
.CW incref
and
.CW alloc:D2B .
After: six page faults, three
.CW movp
captures, two
.CW alloc:D2B ,
and one each of
.CW unload ,
.CW smalloc ,
.CW incref
and invalid opcode.  A different draw from the same distribution is the
simplest reading of that at this sample size, and this document has
already had to retract one over-read number.
.PP
It is not new and it is not unknown.
.CW doc/inferno-ports.ms
carries a long hunt for it: a pointer-typed slot holding a small
non-\c
.CW H
garbage value rather than a heap address or the nil sentinel, read by
two independent opcodes \-
.CW destroy() 's
.CW "bad v"
captures and
.CW OP(movp) 's
.CW AINC(&h->ref) \-
both reached through
.CW OP(mcall) ,
at what that document calls "this hunt's usual near-50% rate".  The
.CW -z
array-zeroing fix was tried against it and explicitly retracted as the
cause
.CW ( f1a01e07 ).
.PP
.NH 2
The same interpreter does not corrupt on the host
.PP
One experiment worth recording, because it is cheap and it points
somewhere.
.PP
The native
.CW /dis/init
in this tree carries a deliberate provocation \- a
.I "TEMPORARY diagnostic stress loop (determinism check phase)"
that runs
.CW "sh -n -c 'true'"
sixty-seven times, a spawn and module-load storm through exactly the
.CW OP(mcall)
path the hunt is looking at.  That loop is why a native boot fails so
often; it was put there to make the bug fire.
.PP
That same loop was run under the hosted emulator, on the same tree,
against the same
.CW .dis
files, with
.CW -c0
so that the interpreter rather than the JIT executes it \- the same
setting
.CW os/inferno/pc64/pc64
compiles in.  Six runs, six clean completions.  Natively, sixteen boots
in twenty panic.
.PP
What that does and does not say.  It does not clear
.CW libinterp :
emu links its own build of it, and a bug that needs a particular heap
layout to show would not show there.  What it does say is that the
interpreter's logic and the
.CW .dis
files are not sufficient on their own to produce the corruption.  The
two sides differ in what sits underneath: emu allocates through
.CW emu/port/alloc.c
and the host's memory, native through
.CW os/inferno/port/alloc.c ,
.CW xalloc.c
and
.CW poolsizeinit 's
arenas; emu's processes are host threads, native's are this kernel's
own, with its own stacks and its own trap path.  The next probes should
be aimed there rather than at the opcodes, which is where several
refuted rounds have already been spent.
.NH 2
Two captures that name their own arithmetic
.PP
Two of the failures in the twenty-boot runs carry values worth decoding
rather than filing, because both say where they came from.
.IP
.nf
panic: smalloc: size 18446744073441179736 > mainmem
	maxsize 262987776, pc=0x286add		(addelem+0x8b)
arena too large: heap size 1768843609 ...
	pc=0x2f2d81				(nheap+0x22)
.fi
.PP
The first is
.CW 0xFFFFFFFFF000F858 :
the sign extension of the 32-bit value
.CW 0xF000F858 ,
which is
.CW -268371880 .
.CW addelem
in
.CW os/inferno/port/chan.c
computes
.IP
.nf
	int a, i;
	i = strlen(s);
	a = p->len+1+i+1;
	if(a > p->alen){
		a += PATHSLOP;
		t = smalloc(a);
.fi
.PP
.CW a
is an
.CW int ,
.CW smalloc
takes a
.CW usize ,
and a negative
.CW int
sign-extends on the way.  So the captured number is not a wrapped
subtraction reaching
.CW smalloc
by accident; it is exactly this line, with a
.CW Path
whose
.CW len
or whose
.CW s
was already garbage.  The second value,
.CW 1768843609 ,
is
.CW 0x696E6959 ,
which is the four ASCII bytes
.CW Yini :
a
.CW Type 's
size field read out of something holding text.
.PP
Both are consequences, not causes \- a corrupt
.CW Path
and a corrupt
.CW Type \-
and they agree with the first capture this work took, a
.CW decref
underflow at
.CW pathclose+0x18
on a kernel
.CW Path
rather than a Dis heap object.  The
.CW Path
code itself is not where to look: every one of
.CW copypath ,
.CW uniquepath ,
.CW pathclose ,
.CW newpath
and
.CW addelem
is identical to
.CW os/9front/port/chan.c 's
apart from this tree's own
.CW checktracked()
probes.  Something is writing over these objects, or handing back a
stale one; the arithmetic above is only how it becomes visible.
.PP
One thing worth doing on its own account:
.CW addelem 's
.CW int
is silent about it.  A check there that reports the
.CW Path ,
its
.CW len ,
its
.CW alen
and the string it was handed would turn a misleading
.CW smalloc
panic into a direct description of the corrupt object, at the first
place that notices.
.NH 2
Ordering, and a rule broken
.PP
Section 1's rule applies to this plan's own ordering, and was broken
once already: the first version of this document made a stable single
processor baseline the first phase, and that step was skipped in favour
of the multicore fixes, which is why two rounds of measurement had to
be re-read once the control experiment was finally run.  Nothing after
this section can be validated until it is closed.
.NH 1
The phases
.NH 2
Phase 1 \- a baseline that does not crash
.PP
Everything else waits on this.  It is the tree's existing
.CW "mcall / movp / destroy"
hunt, not new work, and
.CW doc/inferno-ports.ms
is where it lives.  Two things this round can contribute to it:
.IP \(bu
The VM lock removes an enormous confounder.  Every capture in that hunt
until now was taken on a kernel where up to ten interpreters could be
running against one register set, so any capture could have been that
race rather than the bug.  Captures taken from here are clean of it.
.IP \(bu
A pass criterion, which the hunt has been working without: the console
cannot deliver a keystroke
.CW ( qemu-boot.sh
records that
.CW console=0
is output-only), so the exercise has to be a boot-time Dis program that
allocates hard, passes references between programs, touches the file
system and the IP stack, and prints a fixed completion marker.  Then N
boots reaching the marker is a number, and 20 of 25 is a regression
from 25 of 25 rather than an impression.
.NH 2
Phase 2 \- finish the multiprocessor kernel
.IP 2.1
Audit the kernel globals written from more than one processor: what
.CW machinit
does not reset, the
.CW active
structure, and the allocators \-
.CW os/inferno/port/alloc.c ,
.CW xalloc.c ,
.CW allocb.c .
.IP 2.2
Implement cross-processor TLB invalidation.
.CW os/inferno/pc64/fns.h
defines
.CW "mmuflushtlb()" as
.CW putcr3(getcr3()) ,
which is local, and
.CW invlpg
in
.CW mmu.c
likewise; nothing tells the other processors anything, while
.CW mpstartap
copies the top-level page-table entries out of
.CW MACHP(0)->pml4
so they share page tables.  This matters less here than in Plan 9 \-
native Inferno has no per-process address space to tear down, and
.CW schedinit
has
.CW mmurelease
commented out with a note that memory is linear \- so the exposure is
kernel mappings only.  The idiom to copy is
.CW procflushmmu
at line 1483 of
.CW os/9front/port/proc.c ,
which sets
.CW MACHP(nm)->flushmmu
and waits for each processor to take its own clock interrupt.  No
interprocessor interrupt is needed for that shape, which suits a kernel
whose IPI path is used today only to start processors.
.IP 2.3
Make the collector's controls safe.
.CW include/interp.h
has
.CW gclock()
as
.CW gchalt++
and
.CW Setmark
writing a global
.CW nprop ;
both are plain
.CW int s
in
.CW libinterp/gc.c .
The VM lock covers interpreters, but kernel processes on other
processors reach heap objects through devices and channels.
.PP
Verified by: Phase 1's harness, clean at 1, 2, 4 and 8 processors.
.NH 2
Phase 3 \- measure the kernel, not the interpreter
.PP
The question is no longer whether Limbo gets faster; section 4 answered
that.  It is whether the work around Limbo spreads.  Per-processor
.CW intrcount ,
time-in-Dis against wall-clock, and packets and file operations
serviced per processor, under a network and disk load.  Where a driver
or a service is pinned to the interpreting processor by accident,
unpin it.
.NH 1
The other native ports
.PP
The survey is short and it is not what one would expect.  Of the
sixteen boards under
.CW os/inferno ,
.B two
are configured for more than one processor:
.CW pc
.CW ( MAXMACH
.CW 8 )
and
.CW pc64
.CW ( MAXMACH
.CW 128 ).
Every other board \-
.CW raspi3b ,
.CW virt ,
.CW virtarm64 ,
.CW virt32 ,
.CW sifiveu ,
.CW spike ,
.CW mangopi ,
.CW shakti
and the rest \- has
.CW "MAXMACH 1" .
.PP
So "port multicore to the other boards" is not an audit of existing
code.  For each board it is: raise
.CW MAXMACH ,
write the board's processor bring-up, and give the board per-processor
.CW m
and
.CW up .
The portable work \- the scheduler, the locks, the VM lock, the atomics
\- is done once and is already done.
.PP
Two things carry across for free, and one does not.
.IP \(bu
.B "The atomics carry."
.CW ainc / adec
already exist for every architecture that needs them \-
.CW libkern/ainc-amd64.s ,
.CW ainc-386.s ,
.CW ainc-riscv64.s ,
.CW ainc-thumb.s ,
and C implementations in
.CW os/inferno/raspi3b/archvirtarm64.c ,
.CW os/inferno/virtarm64/archvirtarm64.c ,
.CW os/inferno/virt32/archvirt.c
and
.CW os/inferno/armv7/archv7.c .
.IP \(bu
.B "The VM lock carries."
It is in
.CW os/inferno/port/dis.c
and is architecture-independent.  So is the
.CW qlock()
fix.
.IP \(bu
.B "The trap-return bug does not carry, and it is per-architecture."
It exists because amd64 keeps
.CW m
and
.CW up
in callee-saved registers that the interrupt frame saves and restores.
The 386 port does not have it in that form:
.CW os/inferno/pc/dat.h
makes
.CW m
a global pointer and
.CW up
a field read through the fixed address
.CW MACHADDR ,
which is automatically right after a migration.  Every board that
gets a second processor needs its own answer to this question, and the
answer depends on how that board holds
.CW m :
a register saved in the frame needs 9front's nested check, a fixed
per-processor mapping needs nothing.
.PP
The order to do them in follows the hardware, not the source tree.
.CW raspi3b
has four real cores and is the board this tree cares most about;
.CW virtarm64
and
.CW virt
can be given processors with
.CW -smp
under QEMU and are the cheap test benches for the ARM64 and RISC-V
paths.  The single-core microcontroller boards \-
.CW teensy41 ,
.CW nucleof303 ,
.CW mps2 ,
.CW armv7m \-
want none of this and should keep
.CW "MAXMACH 1" .
.PP
None of it should start before section 6 is closed, for the reason
section 6 gives: a board whose uniprocessor baseline crashes at half of
all boots cannot tell a porting bug from the bug it inherited.
.NH 1
NUMA, and the modern machine
.PP
This section is deliberately last and deliberately cautious, because
the honest answer to "what about NUMA" in this kernel today is that it
is the wrong question by several orders of magnitude, and saying that
is more useful than a design that cannot be justified.
.PP
NUMA is a memory-placement problem: it pays when many processors
allocate and touch memory at once, and the cost of getting placement
wrong is a remote-node access instead of a local one, worth some tens
of nanoseconds.  In this kernel, allocation for Limbo happens inside a
lock that admits one processor at a time.  The serialisation costs
microseconds of waiting; the placement costs nanoseconds.  Fixing the
second while the first stands is measuring the wrong end of the
system.
.PP
What follows is therefore ordered by what the measurement in Phase 3
would actually show, with NUMA in its real place near the end.
.NH 2
What is worth doing, in order
.IP 1.
.B "Cache-line alignment for contended locks."
The cheapest real win on any modern machine, and it is not
speculative: this kernel's global
.CW runq ,
.CW isched.l ,
the VM lock and the pool allocator's locks are ordinary struct members
that share cache lines with the data they protect and with each other.
Two processors spinning on unrelated locks in one line serialise on the
cache protocol.  9front's
.CW Lock
is not padded either, so this is a change to make deliberately and
measure, but it is where the first factor lives.
.IP 2.
.B "Per-processor allocation."
.CW os/inferno/port/alloc.c
and
.CW xalloc.c
are global pools behind global locks, and every kernel process on every
processor goes through them \- including the network and file paths
that Phase 3 is trying to spread.  Per-processor free lists with a
global backing pool is the standard shape and is worth more than
everything else in this section combined.  It is also the honest
prerequisite for NUMA: a per-processor cache is where a node-affine
policy would eventually be expressed.
.IP 3.
.B "Interrupt steering."
Today
.CW mpintrcpu
in
.CW os/inferno/pc/mp.c
assigns interrupts round-robin.  On a machine with MSI-X, a modern NIC
has a queue per processor and can raise a separate interrupt for each,
which is what lets the IP stack scale at all.  The driver side of this
is real work and the payoff is measurable; it belongs before anything
about memory placement.
.IP 4.
.B "Memory ordering, written down."
.CW coherence()
is a full barrier on amd64 and the code uses it correctly at the lock
release.  ARM64 and RISC-V are weakly ordered, and every board added
under section 8 inherits that question.  The rule should be stated in
one place \- which operations imply which barriers \- rather than
rediscovered per board.  This costs nothing now and prevents a class of
bug that is very expensive to find later.
.IP 5.
.B "Processor affinity."
9front's
.CW Proc
carries an
.CW affinity
field, set in
.CW sched()
from
.CW m->machno ;
this tree's
.CW Proc
has no such field.  Keeping a process on the processor whose caches are
warm for it is worth real time, and it is the mechanism a NUMA policy
would later hang from.  The global run queue does not have to go: it
can prefer, rather than require.
.IP 6.
.B "NUMA proper."
Only here.  It needs, in order: a way to learn the topology (the ACPI
SRAT and SLIT tables \- this kernel already parses ACPI through
.CW archacpi ,
so the table walk is not new machinery); memory tagged by node, which
means
.CW memmap.c
and the pool allocator learning about more than one arena; a policy,
of which first-touch is the only one worth implementing first; and
per-node rather than per-processor free lists, which is why item 2 is a
prerequisite and not an alternative.
.PP
Heterogeneous cores \- the performance and efficiency clusters on
current ARM64 parts, including the machine this was tested on \- are a
nearer and sharper version of the same question than NUMA is, and
.CW raspi3b
does not have them while an Apple or a modern Snapdragon part does.  A
scheduler that treats all processors as interchangeable puts an
interactive process on an efficiency core and a background one on a
performance core with equal probability.  That is worth more than
memory placement on those machines, and it wants the same affinity
mechanism from item 5.
.NH 2
What this kernel should not chase
.PP
Said explicitly so that it does not get built by accident.
.IP \(bu
.B "Lock-free data structures in the Dis scheduler."
There is one interpreter.  There is nothing to be lock-free about.
.IP \(bu
.B "Per-processor run queues, for now."
9front runs on many processors with one global run queue and so does
this.  It is a Phase 3 measurement away from being justified, and not
before.
.IP \(bu
.B "Making the JIT multiprocessor-safe as a route to parallel Dis."
It is not one.  Atomic reference counts in generated code would fix a
real bug, and the global
.CW R
would still be there.
.NH 1
Ground rules
.PP
Every claim in this document about what the kernel does is either a
citation to a file and line in this tree or a count of boots produced by
the command in section 1.  Where a claim rests on a binary rather than
on current source, or on another document's investigation rather than
this one's, it says so.  A fix is not reported as done on the strength
of one clean boot: the failures here are races, a single pass is not
evidence, and the repetition is the test.
