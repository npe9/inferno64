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
interpreter is.  Section 4.
.IP 2.
.B "The uniprocessor baseline is not stable."
This tree panics at
.CW -smp
.CW 1 ,
and did so before any of this work: general protection violations, page
faults and Dis heap double-frees, at roughly half of all boots.  It is a
known bug with a long hunt already recorded in
.CW doc/inferno-ports.ms .
Multicore cannot be demonstrated on top of it.  Section 5.
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
This section's title is about the interpreter as it stands, and should
be read that way: it is a statement about the present design, not a
proof that no design could be parallel.
.CW doc/dis-parallel-plan.ms
is what changing it would cost \- a per-context register file, a
scheduling context on Go's P, a lock per channel, per-context
allocation, and a collector that does not keep its mark state in file
statics \- and why reference counting, which Go does not have and Dis
cannot drop, is the ceiling on how far it goes.
.PP
The honest conclusion for this document: Dis executes one program at a
time, system-wide, and the useful parallelism in a native Inferno is in
the kernel around it.  A Limbo program does not get faster on four processors.  A system
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
Two caveats, and they matter enough that this result is a direction and
not a conclusion.
.PP
The emulator binary used is dated 24 August, and things have moved since
\-
.CW mkfiles/mkdis
changed on the 28th and
.CW dis/sh.dis
was rebuilt on the 29th.  So "emu is clean" could as easily mean "the
bug is newer than this binary", which would point at
.CW libinterp
rather than away from it.  Rebuilding emu would settle it, and emu does
not currently build: linking against the present
.CW libinterp
fails on
.CW _printfreehist
and
.CW _checkfreeptr ,
which
.CW OP(movp) 's
and
.CW destroy() 's
probes call and which live in
.CW os/inferno/port/alloc.c ,
a file no hosted build has.  Worth fixing on its own account \- an emu
that cannot be built cannot be used as the control it is useful as.
.PP
.B "Since resolved."
.CW inferno-rio 's
commit
.CW 1a55f0c9
is that repair; cherry-picked here as
.CW 2c33d1e2 ,
emu links again, and the stress loop run under an emu built from
.I current
source is clean six times out of six.  So the staleness objection is
answered and the result stands rather than merely pointing: the same
interpreter, the same
.CW .dis
files and the same workload do not corrupt on the host, on today's
code.
.PP
And it does not clear
.CW libinterp
even if the binary were current: emu links its own build of it, and a
bug that needs a particular heap layout to show would not show there.  What it does say is that the
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
The sanitiser build, and what it caught
.PP
.CW MacOSX/arm64/bin/emu-cocoa-asan
is an AddressSanitizer build sitting untracked in the tree, dated 4
September.  Run against the same stress loop it reports exactly one
error:
.IP
.nf
ERROR: AddressSanitizer: stack-buffer-overflow
READ of size 136 ...
    #0 memcpy
    #1 newstack
    #2 schedmod
    #3 disinit
    [32, 64) 'f' (line 955)
.fi
.PP
That is the bare on-stack
.CW "Frame f"
in
.CW schedmod() :
.CW newstack()
does
.CW "memmove(p->R.FP, f, f->t->size)"
where
.CW f->t
is the module's complete entry-frame type, far larger than a
.CW Frame
header, so the copy reads past it into whatever the C stack held next.
.PP
It is already fixed.  Both
.CW emu/port/dis.c
and
.CW os/inferno/port/dis.c
now allocate
.CW "mallocz(m->entryt->size, 1)" ,
and the comment in the native one records the hunt that found it.  The
sanitiser binary predates the fix \- ASAN reports
.CW f
as a 32-byte object, which is the struct, where the present source has
a pointer.
.PP
So the run says nothing about the live bug, and it says something about
method: the most useful instrument in this tree is a stale binary of a
program that no longer builds.  Fixing that is worth more than another
hypothesis.
.NH 2
The kernel stack: tested, and it is not that
.PP
The emulator result points underneath the interpreter, and one
difference underneath it is worth testing before anything else,
because it would produce this exact fingerprint and it is one line to
try.
.PP
A native Dis program is interpreted on an Inferno kernel stack.
.CW os/inferno/pc64/mem.h
sets
.IP
.nf
#define	KSTACK		(32*KiB)	/* Size of kernel stack */
.fi
.PP
and
.CW os/inferno/port/proc.c
allocates it with
.IP
.nf
p->kstack = malloc(KSTACK)
.fi
.PP
\- out of the main pool, with the ordinary pool blocks of other objects
on either side of it, and no guard page, because it is a buffer and not
a mapping.  Under the emulator the same interpreter runs on a host
thread stack that
.CW emu/port/kproc-pthreads.c
sets to 512KB, sixteen times larger, with a real guard page under it.
.PP
So a kernel stack that runs a little past its bottom writes straight
into whatever pool block is next to it, and every symptom this hunt has
collected is what that looks like from the far side: a
.CW Path
with a garbage
.CW len ,
a
.CW Type
whose size field reads as ASCII text, a pointer slot holding a small
non-\c
.CW H
value,
.CW alloc:D2B
on a block whose header no longer says what it said, and a different
failure every boot depending on which allocation happened to be the
neighbour.
.PP
It is worth saying what does not obviously support this: 32KiB is not a
small stack by the standards of this family \-
.CW os/9front/pc64/mem.h
sets
.CW KSTACK
to
.CW 8KiB
and 9front is fine on it.  But 9front does not interpret Dis on that
stack, and this kernel does:
.CW xec()
and the
.CW OP(mcall)
builtins run on the same 32KiB as the whole device and file system
path beneath them.
.PP
.B "Refuted."
Tested by detection rather than by raising
.CW KSTACK ,
which would have been the weaker experiment and would also have moved
.CW MACHSIZE ,
.CW "2*KSTACK" ,
out of the fixed data-area layout the boot checks at compile time.  A
128-byte band at the low end of every kernel stack is painted
.CW 0xA5
once in
.CW newproc() ,
and
.CW sched()
reads it back on every call.
.PP
Twelve boots: eleven panicked, and the guard was never touched.
.PP
That alone is not quite an answer, because a guard band only catches a
stack that walks down through it.  A single function whose frame is
larger than the band decrements the stack pointer straight past it and
writes its locals below
.CW kstack+0
without ever storing into the band.  So the probe also keeps the
smallest headroom it has ever seen \-
.CW "(uintptr)&local - (uintptr)up->kstack" ,
one subtraction on each
.CW sched() \-
and
.CW panic()
prints it, so the boots that fail early report as well as the ones that
survive.
.PP
Across eight more boots, five of them panicking, the least headroom ever
seen was
.B 29528
of 32768 bytes.  The deepest any kernel stack got was about 3240 bytes,
a tenth of what it has, and the guard was untouched again.  The
hypothesis is dead, not merely unproven, and the probe stays in as a
standing answer.
.PP
Two other things fell out of the same round and are recorded so nobody
repeats them.  Memory size barely matters: twelve boots at each of
.CW -m
.CW 256 ,
.CW 512 ,
.CW 1024
and
.CW 2048
panicked 8, 8, 7 and 6 times, so an eight-fold change in the pool
arenas moves the rate very little and pool sizing is not the dominant
term.  Those four ran back to back on one kernel, which is why they are
comparable; the rate itself wanders between batches \- 80%, 67%, 92% on
the same code \- so any two arms meant to be compared have to be
interleaved in one batch, and twelve boots an arm resolves very little
against that.  And the same failure rate holds with
.CW nvm
pinned at
.CW 1 ,
which is section 5's result from another angle.
.PP
What survives, after this round, is the emulator result of 5.1: the
same interpreter, the same
.CW .dis
files and the same workload do not corrupt when the memory underneath
them is the host's rather than
.CW os/inferno/port/alloc.c 's.
Not the stack.  Not the pool sizing.  The allocator itself, what it
hands out, and who else is writing to it.
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
.PP
.B "Where this now stands on virtarm64."
The plan below was written for pc64, on the assumption that it would be
the multiprocessor board because it already brings processors up.  It
boots to a shell about three percent of the time, so it is a poor place
to build.
.CW virtarm64
boots fourteen of fourteen, and now starts a second processor:
.IP \(bu
PSCI
.CW CPU_ON
starts cpu1, which is straightforward here because the board never
turns the MMU on \- identity addressing throughout \- so a secondary
needs no page tables and its entry address is its own physical address.
.IP \(bu
Each processor keeps its own
.CW Mach
in
.CW TPIDR_EL1 ,
the register the architecture reserves for it, which is what pc64 uses
the GS base for.  cpu1 reads back
.CW "machno 1"
and mutates only its own
.CW Mach .
.IP \(bu
cpu0 meanwhile finishes
.CW DIS-STRESS-OK ,
.CW VIRT-OK
and
.CW CHANTEST-OK
as before, and at
.CW "-smp 1"
nothing changes.
.PP
.IP \(bu
.CW m
and
.CW up
are machine registers, R27 and R26, not globals.  That was the step
this section previously called large and it was not, because the tree
already had the answer: pc64's
.CW dat.h
declares
.CW "extern register Mach* m"
for R15, and 7c honours the same thing.  Every
.CW m->x
becomes register-relative with no pointer load, so each processor has
its own without a shared global, a
.CW TPIDR_EL1
read per access, or turning the MMU on to map a fixed address per
processor.  R27 and R26 are free:
.CW comp-arm64.c 's
JIT uses R0-R5 and R20-R22, and
.CW l.s 's
trap path already saved both in the
.CW Ureg .
.PP
It also fixed something that was quietly wrong.
.CW splhi()
and
.CW splx()
wrote
.CW m->splpc
through a hard-coded
.CW $mach0(SB) \-
harmless while
.CW MAXMACH
was 1, and cpu0's Mach corrupted from another processor the moment it
is not.  They go through the register now.
.PP
.IP \(bu
The exception vectors, the GIC cpu interface and the generic timer.
cpu1 takes its own timer interrupt at HZ \- four ticks in fifty
milliseconds \- and idles in WFI between them.
.IP \(bu
And it can enter the scheduler.  With
.CW secsched
set it calls
.CW schedinit()
and runs processes: 136 context switches in three seconds against
cpu0's 334.  The portable scheduler needed nothing, which is the Plan 9
heritage holding up \-
.CW Schedq
embeds a
.CW Lock ,
.CW proc.c
takes it,
.CW procalloc
is locked.
.NH 2
The smallest reproducer this branch has had
.PP
.CW secsched
is 0, because with it set the board corrupts about one boot in ten:
.IP
.nf
track: CHANGED TO BAD VALUE addr 0x437ee0b0 old 0x43717630 new 0x0
.fi
.PP
a run of words in a live Dis heap object going to zero \- the same
signature
.CW doc/inferno-ports.ms
has been chasing on pc64.  Ten boots with it clear are ten clean.
.PP
That is worth more than the bring-up it came out of.  On pc64 this
corruption is one boot in a hundred and twenty-six on a machine where
almost every boot fails somehow, which makes it nearly impossible to
bisect.  Here it is one in ten, on a board that is otherwise fourteen of
fourteen clean, switched on and off by a single
.CW int .
Whatever shared state a second scheduling processor touches unsafely,
that is the thing to look at first, and this is the handle to hold it
by.
.NH 2
What the reproducer has already said
.PP
Two results from it, one negative and one that joins this work to the
other hunt.
.PP
.B "It is not the collector."
The obvious suspect was the tricolour state \-
.CW gccolor ,
.CW mutator ,
.CW nprop
and every
.CW h->color
are plain words with no ordering, exactly as
.CW doc/dis-parallel-plan.ms
says, and a premature free would show as a run of words zeroed when the
block is handed out again.  So the collector was halted outright
.CW ( gchalt
raised at boot, never lowered) and the ten boots run again.  It got
.I worse ,
not better: six clean, one panic, three corrupt against nine and one.
No boot showed any allocation failure, so this is not the pool running
dry with reclamation off.  Halting the collector does not remove the
corruption, which retires the hypothesis rather than confirming it.
.PP
.B "It is mcall, and it is the same bug pc64 has."
With the collector halted the failure is not merely reproducible, it is
identical from run to run \- the same address, the same previous value:
.IP
.nf
track: CHANGED TO BAD VALUE addr 0x437ed3b0 old 0x43716930 new 0x0
track: instruction that just ran: op 0x09 module Sh inst 2079
track: object 0x437ed360 type 0x437d0d38 size 0 np 0
track: object 0x437ed2f0 type 0x437d1738 size 1132271384 np 0
.fi
.PP
Opcode 9 is
.CW IMCALL .
The
.CW Type
descriptors those objects point at are not types: one reports size 0,
the other a size of 1132271384, which is a pointer-shaped value read as
a length \- the same shape as the
.CW "\(lqYini\(rq"
capture in
.CW doc/inferno-ports.ms .
And that document's own name for what it is chasing on pc64 is the
.CW "mcall / movp / destroy"
corruption, at
.CW "op 0x09 add 0x48 module Sh inst 2079" \-
the same opcode, the same module, the same instruction index this board
now produces on demand.
.PP
So the two investigations are one investigation.  But the obvious
reading of that \- "the pc64 corruption is what this kernel does when a
second processor touches shared state" \- is wrong, and worth writing
down as wrong because it is the first thing anyone will think.
.PP
Every pc64 boot measured here ran at
.CW "-smp 1" .
One processor, and it still corrupts.  So a second processor is not
what causes this; on
.CW virtarm64
it is only what makes it appear.
.PP
Two further checks say the same thing from the other side.  The VM lock
holds:
.CW nvm ,
the count of processors inside the interpreter, never rises above 1
across four boots with
.CW secsched
set, and the holder is always cpu0 \- cpu1 never enters
.CW xec()
at all.  So this is not two processors in the interpreter, and it is
not the collector.  What is left is a bug that one processor can hit on
its own, which a second processor perturbs the timing enough to expose:
constantly on pc64, one boot in ten here.
.PP
That is a better position than it sounds.  A latent single-processor
bug with a switch that changes how often it fires is far easier to work
on than a rare one with no switch at all, and it means the reproducer
is useful to the
.CW doc/inferno-ports.ms
hunt without either investigation having to wait for the other.
.NH 2
The recipe, and why the collector-off case is the one to use
.PP
Two switches at the top of
.CW os/inferno/virtarm64/main.c :
.CW secsched
puts cpu1 into the scheduler,
.CW nogc
raises
.CW gchalt
at boot so the collector never runs.  Booted with
.CW "qemu-system-aarch64 -M virt -cpu cortex-a53 -smp 2" :
.IP
.nf
secsched  nogc     result over ten boots
    0       0      10 clean
    1       0       9 clean, 1 corrupt
    1       1       5 clean, 5 corrupt
.fi
.PP
Use the third row.  Not only because it fails half the time rather than
one time in ten, but because when it fails it fails
.I identically :
.IP
.nf
CHANGED TO BAD VALUE addr 0x437ed3b0 old 0x43716930 new 0x0
.fi
.PP
the same address and the same previous value in every one of the five,
against a pc64 needle that has never repeated an address once.  The
whole run is deterministic enough to put a watchpoint on.
.PP
What the failure looks like underneath: the object at
.CW 0x437ed360
has words zeroed, and its
.CW Type
reads
.CW "size 0 np 0" ,
while a neighbour's reads
.CW "size 1132271384" .
Those are not types.  With the collector halted nothing is reclaimed by
.I it ,
so an object whose header has been overwritten and whose words have
been zeroed is an object that
.CW destroy()
freed on a refcount reaching zero and something else then allocated and
cleared \- which is a premature free, and is what the
.CW "mcall / movp / destroy"
name in
.CW doc/inferno-ports.ms
has meant all along.  The collector was never the suspect it looked
like; the refcount is.
.NH 2
It is the Type that is freed, not the object
.PP
The tracker's report now prints
.CW t->ref
alongside the size, because
.CW Type 's
first field is its reference count.  At the corruption it reads
.IP
.nf
object 0x437ed360 word 10, type 0x437d0d38 ref 0 size 0 np 0
.fi
.PP
three times out of three.  A
.CW Type
with
.CW "ref 0 size 0"
has been freed and had its memory zeroed, and the object still points
at it.  So the premature free is of the
.I type ,
not of the object whose words were seen going to zero \- those went to
zero because the freed
.CW Type 's
memory was handed out again.  The tracker's own staleness check agrees:
it compares the object's type tag against the one it recorded, and the
tag still matches, so nothing reallocated the object.
.PP
That is a much smaller thing to look for.  Every
.CW Type
reference is dropped in one of six places \-
.CW freetype()
from
.CW heap.c
line 528 and
.CW xec.c
line 920 and
.CW load.c
line 863, and three open-coded
.CW "ADEC(&t->ref) == 0"
sites in
.CW freearray()
and
.CW freelist() \-
and with the collector halted the sweeper's is not among them.
.PP
One of the six is already eliminated.
.CW freelist() 's
.CW "ADEC(&th->t->ref)"
is unguarded, frees nothing and carries a comment saying the type
"should be &Tlist and ref shouldn't go to 0 here nor be 0 already" \-
an assumption rather than a check, and the obvious suspect.  A probe
asserting both halves ran over six boots, four of which corrupted, and
never fired.  The assumption is sound and that line is not the bug.
.NH 2
It is freemod: a module unloaded while its types are still in use
.PP
Every
.CW Type
free was then recorded in a ring \- which of the six sites, and the
caller \- and the dead
.CW Type
looked up in it when the tracker fired.  Twenty-two hits across the
corrupting boots, all of them the same:
.IP
.nf
that Type was freed at site 0 pc 0x400903d8
.fi
.PP
Site 0 is
.CW freetype() ,
and the caller resolves by printing the candidates' addresses from C,
since the kernel links stripped:
.CW destroy
is at
.CW 0x400929e0
and
.CW freemod
at
.CW 0x400903a8 ,
so
.CW 0x400903d8
is
.CW freemod+0x30 .
.PP
.CW freemod()
is
.CW libinterp/load.c :
.IP
.nf
if(m->type != nil) {
	for(i = 0; i < m->ntype; i++)
		freetype(m->type[i]);
	free(m->type);
}
.fi
.PP
So the premature free is not of an object, and not of a type in
isolation: it is a
.I module
being torn down while objects created from its types are still live.
Which is why the failure surfaces at
.CW IMCALL ,
the inter-module call \- that is where a module's reference count is
taken and dropped, and
.CW OP(mcall) 's
native branch drops it with a bare
.CW "ADEC(&h->ref)"
that checks nothing.
.PP
That also explains why this looks like the
.CW "mcall / movp / destroy"
corruption
.CW doc/inferno-ports.ms
named long ago: all three are the same event seen from different
distances.  The next question is which module reference is dropped too
early, and that is a question about
.CW OP(mcall) ,
.CW unload()
and
.CW freemod() \-
a much smaller place to look than the whole interpreter.
.NH 2
A constraint on how it can be investigated
.PP
The obvious next step was to watch that one
.CW Type \-
its address is stable across rebuilds \- and print every change to its
reference count with the caller, since an imbalance there is the bug.
That does not work, and the reason is worth recording so nobody spends
an afternoon on it.
.PP
With
.CW twnote()
calls added at the four places a
.CW Type 's
count moves, six boots produced no corruption at all.  Removing them
again, six boots produced three, at the same
.CW "type 0x437d0d38 ref 0 size 0" .
The instrumentation does not fix it; it hides it.  A handful of
function calls in the reference-counting path perturb the timing enough
to close the window entirely.
.PP
So this cannot be chased by printing from inside the refcount path.
What is still available: the reference counts can be
.I checked
rather than traced \- an assertion that fires without printing on the
common path, a count kept in a variable and reported once at the end,
or a check at
.CW freemod()
that the types it is about to free are not still referenced by any live
object.  The last of those is expensive but runs once per module
unload, not per reference, and would name the offending module rather
than the offending line.
.PP
It is also worth saying what the sensitivity implies.  A window this
narrow, closed by a few extra calls, is consistent with the shape
already established \- a single-processor bug that a second processor
only perturbs into view \- and it is why the pc64 side of this hunt has
been able to add instrumentation for years without ever cornering it.
.NH 2
Confirmed by removal, which the timing could not fake
.PP
The way past that constraint was to take work away rather than add it:
.CW freemod() 's
.CW freetype()
loop was skipped entirely, leaking the module's types, and the
reproducer run again.
.IP
.nf
                    freed/garbage Types      IMCALL failures
not leaking (6)     14 across three types              12
leaking (8)                          0                   0
.fi
.PP
The
.I character
of the failure changes and not merely its rate, which is what
distinguishes this from the timing sensitivity above.  Every capture
without the leak has a
.CW Type
that is dead or overwritten \-
.CW "ref 0 size 0" ,
or a
.CW ref
of 1953066601 beside a
.CW size
of 1132271384, which is a path string lying in a
.CW Type
and the same shape as this hunt's old
.CW "\(lqYini\(rq"
capture.  Every capture with the leak has a
.CW Type
that is entirely valid:
.CW "ref 1 size 136 np 3" .
.PP
So the chain is closed.  A module is unloaded while objects created
from its types are still live;
.CW freemod()
releases the types; an object keeps pointing at freed memory; that
memory is handed out and cleared; the tracker sees the words go to
zero.  Every link of that was measured.
.PP
What is left with the leak on is a
.I different
failure, and smaller:
.CW ILOAD
rather than
.CW IMCALL ,
at
.CW readmod:after-parsemod
rather than mid-instruction, on a
.CW Type
that is intact.  A second bug, not this one, and now separable from it
for the first time.
.PP
The leak is not the fix.  It trades a use-after-free for a leak on
every module unload.  The fix is whatever reference the unloading
module should have been holding, or should have been held on it \-
which is now a question about
.CW OP(mcall) ,
.CW unload()
and
.CW lookmod() ,
with a switch that turns the symptom on and off to check any answer
against.
.NH 2
Which modules, and the technique that could ask
.PP
Recording the module path beside each freed
.CW Type
and dumping it only when the tracker fires names them:
.CW /dis/cd.dis ,
.CW /dis/echo.dis
and
.CW /dis/pwd.dis .
Shell commands \- and precisely the ones
.CW virtinit 's
smoke script runs, since it ends with
.CW "cd /usr/inferno; pwd" .
So the sequence is ordinary: the shell loads a command module, runs it,
drops it, and something created from that module's types is still alive
when its type table goes.
.PP
Getting that took two tries and the failures are the useful part.  The
first stored
.CW m->path
as a pointer and read back
.CW "\(lq\(rq"
and
.CW "\(lqp\(rq" ,
because
.CW freemod()
frees the path immediately afterwards; the ring has to copy the string.
The second, and more important: an earlier attempt simply printed the
path at
.CW freemod() ,
seven lines a boot, one per unload \- and the corruption vanished
entirely, eight boots of nothing.
.PP
So the constraint is tighter than "do not instrument the refcount
path".  Any print anywhere near this closes the window.  What works is
to record silently into a ring and dump it only from the failure path,
which is how both the freeing site and the module name were obtained.
Anyone continuing should reach for that shape first rather than
rediscovering it.
.PP
There is also a limit worth stating plainly: a check that would be
genuinely decisive \- walking the heap at
.CW freemod()
for a live object still pointing at a type about to be freed \- has not
been run, and on this evidence it may well hide the bug too.  The
leak-versus-no-leak comparison worked only because it removed work
instead of adding it.
.NH 2
The object is a stack frame, and frames hold types uncounted
.PP
The tracker reports, every time,
.IP
.nf
typetagp 0x437ed378 obj 0x437ed360 diff 0x18
.fi
.PP
\- the type tag lies 24 bytes into the object rather than in its
.CW Heap
header.
.CW Frame 's
.CW t
field is at offset 24.  The things being corrupted are Dis stack
frames.
.PP
And
.CW OP(frame)
is
.IP
.nf
t = R.M->type[W(s)];
...
f->t  = t;
f->mr = nil;
initmemtt(t, f, &f->t);
.fi
.PP
with no
.CW "AINC(&t->ref)" .
Every heap-allocated object takes a reference on its type \-
.CW heap()
and
.CW heapz()
both do, and
.CW nheap()
has no type \- but a frame does not, because a frame is stack and its
module is supposed to outlive it.
.PP
That is the invariant, and it is the one being broken: the shell loads
.CW /dis/cd.dis ,
a frame of one of its types goes on a Dis stack, the shell drops the
module, and
.CW freemod()
frees the type the frame still names.  The next
.CW freeptrs(f, f->t) \-
which
.CW OP(mcall) 's
native branch and
.CW OP(ret)
both perform \- reads a freed
.CW Type ,
walks a garbage pointer map, and destroys whatever the wrong offsets
name.  That is
.CW "mcall / movp / destroy"
in one sentence, and it is why all three opcodes have been implicated
for as long as the hunt has run.
.PP
The first of the two fixes was then built and measured, behind
.CW framerefs
in
.CW libinterp/xec.c :
.CW OP(frame)
and
.CW OP(mframe)
take a reference,
.CW OP(ret)
releases it.  And the result corrects the section above.
.IP
.nf
                  IMCALL failures    Type at the corruption
baseline (6)                   12    ref 0 size 0, ref 1953066601 ...
leaktypes (8)                   0    ref 1 size 136
framerefs (8)                  12    ref 1 size 88, ref 1 size 112
.fi
.PP
.CW framerefs
does what it was meant to: the Types at the very addresses that used to
read
.CW "ref 0 size 0"
now read
.CW "ref 1"
with sensible sizes.  Frames really were holding uncounted references
and really were outliving their modules' type tables.  That much is a
genuine bug and it is now demonstrated rather than argued.
.PP
But the corruption is unchanged \- twelve
.CW IMCALL
failures over eight boots, the same as baseline.  So keeping the
.CW Type
alive does not stop the object's words going to zero, and the two are
independent.
.PP
Which means the
.CW leaktypes
result has to be read again.  It also keeps types alive, and it removed
the corruption entirely; but
.CW framerefs
keeps them alive too and removes nothing.  The difference between them
is that
.CW leaktypes
additionally skips the
.CW free(t)
\- it changes what the allocator does with that memory.  So the honest
reading of "confirmed by removal" above is that it was probably an
allocation-pattern effect after all, not the causal demonstration it
was written up as.  Two switches that both keep the type alive disagree,
and the one that also changes allocation is the one that helped.
.PP
So the premature
.CW Type
free is real and now fixable, and it is
.I not
the corruption.
.NH 2
And a caution about the reproducer itself
.PP
One thing was never checked while all of the above was being measured,
and it should have been first: whether the
.CW virtarm64
"corruption" breaks anything.  It does not.  Every boot on this board
that tripped the tracker \- across every configuration, baseline,
.CW leaktypes ,
.CW framerefs ,
.CW secsched
\- still reached
.CW CHANTEST-OK
with no panic.  Not one failed.
.PP
On pc64 the same diagnostic fires and the machine panics much of the
time.  Here it fires and nothing happens.  So "one boot in ten
corrupts" was really "one boot in ten
.I trips
.CW checktracked() ",
and the classifier that counted those as failures was counting a
diagnostic, not a fault.
.PP
That has to be treated as a live possibility rather than argued away:
a popped Dis frame's memory, reused and reinitialised by a later frame
of the same type at the same address, would produce exactly this
report, because the tracker's staleness check compares the type tag and
an identical type tag does not look stale.  The addresses do not settle
it \- the tracked object sits outside the reporting proc's own stack
extent, so if it is a frame it is in another
.CW Stkext \-
but they do not rule it out either.
.PP
What this costs: the link between the
.CW virtarm64
switch and pc64's panics is weaker than the earlier sections claim.
What it does not cost: the
.CW framerefs
result stands on its own, because it was measured against the
.CW Type 's
own reference count and not against the tracker's verdict, and frames
holding uncounted type references is a real defect either way.
.PP
That question has now been answered, and the answer is no.
.NH 2
The reports were dead objects, and the diagnostic is fixed
.PP
Printing the watched object's own
.CW Heap
header at every report gave
.CW "ref 0 ... DEAD/REUSED"
twelve times out of twelve.  Every report on this board was about an
object that had already been freed; its memory was reused and
reinitialised, and the tracker called that corruption.  Which is
exactly why none of them ever led to a failure.
.PP
The staleness test compared the type tag at
.CW obj+O(Frame,t)
and nothing else, and an identical type does not change that tag \- so
a popped frame reused by another frame of the same type walks straight
through it.  The object's own
.CW Heap.ref
and
.CW t
are now part of the test.  On both boards:
.IP
.nf
virtarm64    8 boots, 0 tracker events (was 3-5 of 8), 8 CHANTEST-OK
pc64        14 boots, 8 tracker events, 9 panics
.fi
.PP
The false positives go and the real signal stays, which is the whole
point of the change: pc64's reports survive the check, on objects that
are live with a matching type, so its corruption is real.
.CW virtarm64 's
was not.
.PP
So the "one boot in ten reproducer" is retired, and with it the
sections above that reasoned from its rate \- the collector
elimination, the
.CW freemod
attribution, the module names.  Those experiments measured a false
positive's frequency.  What survives is what was measured against
something other than the tracker's verdict:
.CW framerefs ,
because it was checked against the
.CW Type 's
own reference count, and the multiprocessor bring-up itself, which was
never measured by the tracker at all.
.PP
The lasting result is the diagnostic.  Older captures in
.CW doc/inferno-ports.ms
were taken with the weaker check, and some fraction of them may be this
artefact rather than the bug.
.NH 2
What pc64 looks like through the fixed diagnostic
.PP
Fourteen boots with the corrected
.CW checktracked() ,
4512 surviving reports over the eight that fired, and the picture is
not the one this hunt has been working from.
.IP
.nf
copypath:before-mtptloop   2634        op 0x09      4509
copypath:after-strcopy     1099        op 0x08         2
copypath:after-alloc        408        op 0x53         1
walk:after-ewalk            204
walk:before-findmount       102
instr                         3
.fi
.PP
Every
.CW Type
in those reports is live and valid \-
.CW "ref 1"
with sizes of 88 to 336, no freed types and no garbage.  And three
reports out of 4512 are at
.CW instr .
The corruption is not happening while Dis executes; it is happening
inside
.CW copypath() ,
in the kernel's path handling.
.PP
The
.CW "op 0x09"
column is what made this look like
.CW mcall
for so long, and it is an artefact:
.CW trackPC
holds the last Dis instruction
.I dispatched ,
which stays where it was for the whole of a kernel call.  With a
.CW copypath
checkpoint the interpreter is not running at all, so that column
records what the proc last did before entering the kernel, not what
corrupted anything.
.PP
Between each pair of those checkpoints sits exactly one
.CW smalloc() ,
which
.CW memset s
what it returns \- the obvious next question, and it cannot be asked
directly.  Recording every
.CW smalloc()
return and testing the corrupted address against it gave zero reports
over eight boots while the panics continued at the same rate, seven of
eight.  The bug did not go away; the tracker's view of it did, because
which objects are watched is a function of layout and any change
reshuffles it.
.PP
So two things for whoever continues.  The panic rate is the durable
measurement and the tracker is not: a probe can silence the one while
leaving the other untouched.  And the search should start in
.CW copypath()
and
.CW walk() ,
not in
.CW OP(mcall) .
.NH 2
The tracker does not predict the failure either
.PP
Set the two signals side by side across the same fourteen boots and
they do not agree:
.IP
.nf
4 boots panicked with no tracker report at all
3 boots reported 168, 881 and 1493 times and never panicked
5 boots did both
.fi
.PP
So even with the liveness check the tracker is not measuring the fault.
It is measuring something that happens near it, often, and sometimes
neither.  A slot the type map calls a pointer holding a small value is
not necessarily wrong \- a Limbo
.CW adt
with a
.CW pick ,
or a union, will do that legitimately \- and nothing in the check
distinguishes those.
.PP
That downgrades the
.CW copypath
result above from "where the corruption is" to "where the tracker
mostly fires", which is a weaker claim and the only one the numbers
support.
.PP
What is left as reliable is the kernel's own integrity checks.  The
panics across those boots:
.IP
.nf
page fault                        3
movp: bad sv                      1
invalid opcode                    1
general protection violation      1
alloc:D2B:free                    1
alloc:D2B:destroy-entry           1
.fi
.PP
The two
.CW alloc:D2B
entries are the pool detecting a corrupted block header, which is a
specific, self-checking, layout-independent signal of the kind
everything else in this hunt has lacked.  They are the thing to
instrument and count, and unlike the tracker they say what was
corrupted rather than which watched word moved.
.PP
What is still not done, so the state is not overstated: GICv3 (the
redistributor is per processor and this board derives one fixed base),
preemption on a secondary (\c
.CW clockintr
returns early there, since
.CW checkalarms()
and
.CW timercheck()
walk machine-wide queues), and
.CW active.machs
/
.CW conf.nmach
still describe one processor.  Measured at each step with the
four-category classifier.
.PP
.B "Before any of it: 7c ignores volatile."
Found while starting a second processor on
.CW virtarm64 ,
and it changes how every item below has to be written.
.IP
.nf
extern volatile unsigned long long f, g;
void loopv(void) { f = 2; for(;;) g++; }

	MOV	g+0(SB),R9	/* g loaded once */
	MOV	$2,R1		/* f = 2, never stored */
	ADD	$1,R9,R9	/* g++ in a register, for ever */
.fi
.PP
Both operands are declared
.CW volatile
and the compiler hoists them regardless \- long-standing behaviour of
the Ken compilers, which accept the keyword and ignore it.
.PP
But the rule is narrower than "the compiler is unreliable", and the
difference is what makes 9front's kernel correct without
.CW volatile
anywhere near a spin loop.  Compiled with the same
.CW 7c :
.IP
.nf
void spinptr(S *l)  { while(l->key) ; }   /* through a pointer */
	MOVWU	0(R9),R2	/* reloaded every iteration */

void spinglob(void) { while(g) ; }        /* a direct global */
	MOVWU	g+0(SB),R9	/* loaded ONCE, before the loop */
.fi
.PP
A load through a pointer is reissued each time round; a direct global
symbol is hoisted.  So the question for any wait loop is not whether it
said
.CW volatile ,
it is how the location is reached.
.NH 2
What 9front does, and it is three things
.PP
Worth reading out of
.CW os/9front
rather than reinvented, because the tree is right here and the idioms
are consistent.
.IP 1.
.B "Reach shared state through a pointer."
.CW taslock.c 's
.CW lock()
spins on
.CW "while(l->key)" ,
and
.CW proc.c 's
.CW procflushmmu()
polls
.CW MACHP(nm)->proc
and
.CW MACHP(nm)->flushmmu .
Neither is
.CW volatile
and neither needs to be: they are pointer dereferences, so the compiler
reloads them.
.IP 2.
.B "Put a real call in the wait loop."
.CW procflushmmu()
calls
.CW sched()
each time round;
.CW cpushutdown()
in
.CW devcons.c
calls
.CW delay() .
That forces the reload for anything the compiler might otherwise keep,
and it yields the processor instead of burning it.
.IP 3.
.B "Read a genuine global through a function."
The one place 9front polls a plain global array,
.CW cpushutdown() 's
wait for the other processors, does it as
.IP
.nf
if(memchr(active.machs, 1, MAXMACH) == nil && consactive() == 0)
.fi
.PP
\- through
.CW memchr ,
not by indexing it in the loop condition.  Whether that was chosen for
this reason or for brevity, it is what makes it work.
.PP
And on the writing side,
.CW coherence()
before publishing the flag, so the state a reader will go looking at is
visible before the flag that sends it there:
.IP
.nf
coherence();
MACHP(nm)->flushmmu = 1;
.fi
.PP
So: every Phase 2 item that waits on another processor \- an
.CW active.machs
bit, a
.CW flushmmu
handshake, a collector's stop-the-world acknowledgement \- gets built
that way, and
.CW volatile
does not appear.  Where this branch has already needed it, the
secondary's own loop on
.CW virtarm64 ,
a
.CW coherence()
call in the body is what makes the stores land.
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
None of it should start before section 5 is closed, for the reason
section 5 gives: a board whose uniprocessor baseline crashes at four
boots in five cannot tell a porting bug from the bug it inherited.
.NH 1
NUMA, and the modern machine
.PP
This section is about the
.I kernel .
The same question for the Dis runtime \- whether
.CW libinterp
is correct on a multiprocessor, on asymmetric cores, and on NUMA \- is
answered separately in
.CW doc/dis-numa-survey.ms ,
and the answer is different for each of the three: not correct on a
multiprocessor, correct but unfair on big.LITTLE, correct and blind on
NUMA.
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
under section 7 inherits that question.  The rule should be stated in
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
