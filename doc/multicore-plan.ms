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
.NH 2
What the pool's own check already says
.PP
It needed no new instrumentation: the free-history ring this hunt
already built \-
.CW NFREEHIST
raised to 4096 for exactly this \- fires and names the earlier freer.
From one capture:
.IP
.nf
alloc:D2B:destroy-entry: 78f1338 in heap: in free blk at 78f1318
area at 78f1318: badc0c0a 80 0 0 0 0 0 ... 2e68732f7369642f
_poolfault: 0x78f1338 was freed before, from pc=0x2f249e pid 1 module Sh
_poolfault: 0x78f1338 was freed before, from pc=0x2f2083 pid 1 module Sh
_poolfault: 0x78f1338 was freed before, from pc=0x2f249e pid 7 module Env
panic: alloc:D2B:destroy-entry 78f1338 (from 2f24f3/...)
.fi
.PP
Two things in that.  The same block was freed from the same pc
repeatedly and across different procs and modules \- so this is a
double free, which the hunt already suspected, and the ring now catches
the first freer rather than ageing it out.
.PP
And the block's contents decode:
.CW 2e68732f7369642f
is
.CW "/dis/sh."
and
.CW 736964
is
.CW dis .
The thing being freed twice is a
.I path string .
A second capture on the main pool has the same shape.  That is a
.CW Path ,
allocated by
.CW newpath()
or
.CW copypath()
in
.CW os/inferno/port/chan.c
and released by
.CW pathclose() ,
which frees
.CW p->s
when its reference count reaches zero.
.PP
So the durable signal and the tracker point at the same file for once,
and the reading is much more specific than "corruption in
.CW copypath ":
.CW Path
reference counting is wrong, and a path string is freed twice.
.PP
The blocker is the same one
.CW doc/inferno-ports.ms
records for armv7: those pcs cannot be resolved to functions.
.CW inm
produces no output for this kernel, and a hand-written reader of the
Plan 9 symbol table mis-parses it and returns plausible-looking
nonsense.  Fixing that \- a working
.CW nm
for this objtype, or a
.CW "6l -a"
listing kept beside the kernel \- is worth more than any further
probing, because every capture this hunt has taken carries pcs it
cannot read.
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
Reading captured pcs
.PP
This branch's corruption captures all carried pcs nobody could read:
.CW inm
prints nothing for these kernels, because nm's
.CW execsyms()
swallows a
.CW syminit()
failure without a message, so an unreadable symbol table looks exactly
like a stripped one.
.CW utils/p9sym.py
reads the table directly, following libmach's own
.CW decodename()
rules \(em 8-byte values under
.CW HDR_MAGIC ,
fixed-length names when the type byte lacks
.CW 0x80 ,
.CW z / Z
names as
.CW "00 00" Ns -terminated
pairs \(em and is verified against
.CW Inferno/amd64/ipc64
by three absolute-addressed operands resolving to
.CW poolfault ,
.CW gcdepth
and
.CW gcdepthmax
at offset 0, with zero bytes of the table left unconsumed.
.PP
A correct reader was not sufficient, and the reason is the useful
finding.  A pc means nothing except against the binary that produced
it; this tree rebuilds constantly and its panics carry no build stamp,
so pcs recorded in one boot were read against a later kernel in which
the functions had moved, and resolved to confident, wrong names.
.CW "p9sym.py -s"
recovers the shift by finding one offset that makes every pc in a
capture a valid call-return address \(em decisive because chance hits
run at the call-return density, 1.87% of text bytes here.  This hunt's
four heap.c captures all resolve at offset
.CW +0x74 ,
two of them to the
.CW poolfree()
calls in
.CW destroy()
and
.CW freelist()
exactly, which is what a freehist entry recorded by
.CW poolfree() Ns 's
own correctly-anchored
.CW getcallerpc(&p)
must be.  The earlier symbolic names in doc/inferno-ports.ms were
wrong; the conclusion drawn from them \(em that the first free was an
ordinary successful
.CW destroy()
or
.CW freelist()
exit, so a second independent owner held a dangling reference \(em
stands.  One attribution moves:
.CW freearray
was a boundary crossing, and the pc is
.CW freelist+0x63 .
Two pcs remain unplaced, so
.CW free+56
is withdrawn.
.PP
Read end to end, the captures name a static
.CW Type
being handed to
.CW free() :
.CW freelist()
freeing
.CW Tptr ,
and, once
.CW freetype()
was made to refuse that,
.CW Tarray Ns 's
count reaching zero eighteen times in one boot under
.CW OP(cvtac) .
Creation of Arrays is 1:1 with destruction, so that count is one more
than the number of live Arrays and reaching zero means Arrays were
destroyed more often than created \(em the double free this branch has
been chasing, confirmed by a mechanism independent of the pool's magic
check.  It narrows the object kind; it does not yet locate the surplus
release.
.PP
The build stamp needed for this already existed and was never used:
every mkfile compiles
.CW $CONF.c
with
.CW "-DKERNDATE=`{$NDATE}"
and the boot banner prints it.
.CW p9sym.py
reads the same word out of the binary and compares, so a capture from
the wrong kernel is now refused rather than resolved \(em this tree's
.CW ipc64
is built at 1788855526 and the logs these pcs came from say 1788170900,
1788655402 and 1788656011, confirming the offset result by an
independent route.  See doc/inferno-ports.ms, "The captured pcs were
right".
.NH 1
The serialisation, measured
.PP
This branch's premise is that Dis runs one program at a time behind a
single global lock and that removing that is worth doing.  Until now
the premise was reasoning, not measurement.  Two counters make it a
measurement, both temporary and both in os/inferno/port/dis.c.
.PP
.CW maxnrunq
walks
.CW curP->runhd
at the scheduler's own pick and records the high-water mark of Dis
programs ready at once.  It is 2 on the ordinary boot workload, on
pc64 and on virtarm64 alike, in every boot.  So there is concurrency
available.
.PP
That alone proves little \(em two programs can be ready and still each
get the processor promptly.
.CW vmblocked
over
.CW vmpasses
is the cost:
.CW vmlock.head
is the queue of kernel processes blocked in
.CW vmacquire() ,
so a scheduler pass finding it non-nil is a pass taken while a
runnable interpreter waited on the lock.  Across the 94 boots of a
96-boot batch at
.CW "-smp 2"
that reached the report: minimum 57.2%, median 76.9%, maximum 96.2%.
.PP
And the depth says more than the fraction.  The counter began as a
boolean \(em was anyone waiting \(em which rested on
.CW vmlock.head
meaning "processes blocked in
.CW qlock(&vmlock) "
and would have read plausibly whether or not it did.  Walking the chain
checks that (
.CW qlock()
appends through
.CW up->qnext
and sleeps the process, so every entry must be in
.CW Queueing ;
the check is silent) and counts the waiters.
.PP
Over 192 pc64 boots at
.CW "-smp 2"
the deepest queue seen in a boot is never less than four:
.TS
box, tab(;);
l l.
deepest vm-lock queue in the boot;boots
_
4;123
5;61
6;8
.TE
.PP
So at the moment the scheduler looks, between four and six interpreters
are stacked behind the one global lock.  That is the number that says
what the serialisation costs \(em not the duty cycle, which says only
that someone was waiting, but the depth, which says how many runnable
interpreters a second context would have to draw from.  Six on a
two-processor guest is more than the two processors could absorb, which
means the ceiling here is the lock and not the hardware.
.PP
At the median, three quarters of scheduler passes are taken with a
runnable interpreter blocked.  That is the justification for Phase 1b
and Phase 5, in numbers, on the workload this branch can run today \(em
a boot script and a shell on a two processor guest, which is not a
general Dis workload and is stated as such.
.PP
The blocker that stood in front of all of this is gone: pc64 boots at
.CW "-smp 1" ,
.CW "-smp 2"
and
.CW "-smp 4" ,
with every processor online, after the interrupt-entry fix recorded in
doc/inferno-ports.ms.  cpu1 takes interrupts and runs kernel work; the
interpreter is what is still serial.
.NH 1
Where this stands
.PP
The blocker is gone.  pc64 boots at
.CW "-smp 1" ,
.CW "-smp 2"
and
.CW "-smp 4"
with every processor online, after the interrupt-entry fix found by
the cloud-port session and confirmed here by disassembly: 82 of 96
boots panicked before it, 2 of 96 after, on the same command line with
each batch pinned to its build by
.CW etext .
.PP
The serialisation is measured, not assumed.  Two Dis programs are ready
at once on the ordinary workload, and a runnable interpreter is blocked
on
.CW vmlock
in 77% of scheduler passes at
.CW "-smp 2"
against 34.6% at
.CW "-smp 1"
\(em so about a third is inherent to the workload and the rest is a
processor with nothing to do.  That is the case for Phase 1b and Phase
5, in numbers.
.PP
Four bugs were fixed along the way, none of them the interpreter's
parallelism and all of them lifetime bugs the hunt had been circling:
.CW freetype()
handing a static
.CW Type
to
.CW free() ;
.CW modstatus()
and
.CW notefree()
dereferencing a
.CW Modlink
they had checked with the wrong question, and then re-reading the
pointer they had checked;
.CW delprog()
leaving a freed
.CW Prog
linked in the run queue; and
.CW delprog()
leaving
.CW curP->curprog
naming a freed
.CW Prog ,
which
.CW progreg()
compares by pointer and which Phase 1b is built on.
.PP
The collector invariant Phase 1b depends on was asserted rather than
argued, and holds:
.CW regsyncpc
against
.CW R.PC
is silent on both boards.  It stays as a permanent tripwire, because it
fires the moment Phase 1b opens that window without Phase 5.
.PP
What is left before Phase 1b is Phase 5's half of the disjunction \(em
the collector must stop trusting
.CW p->reg
for a running program, or
.CW xec()
must write it back more often than once a quantum.  The JIT
prerequisite (loading
.CW curR
at run time rather than baking its address into generated code) is
real but untestable on pc64 today, where
.CW cflag
is never set and the JIT is off; it should land with a board that runs
compiled code.
.PP
That last failure is fixed.  It was
.CW userureg()
in os/inferno/port/proc.c returning
.CW kp
where its own comment says
.CW !kp ,
so every kernel process's trap ran the user tail \(em
.CW notify()
and
.CW kexit()
over a
.CW Ureg
on a kernel stack \(em and one of those writes put a garbage stack
selector in the frame that
.CW IRETQ
then rejected.  Caught by a probe at both ends of
.CW trap() ,
after two earlier probes eliminated the CPU push and the device
handlers.  192 boots at
.CW "-smp 2"
since: 192 clean, cpu1 online in all, every probe silent.  At the
observed 1.4% rate zero in 192 has probability about 0.067, so the
weight is on the mechanism having been watched rather than on the
batch.  See doc/inferno-ports.ms.
.PP
Two more failures surfaced and were fixed after that, both found with
the cloud-port session and each of us wrong first.  The
.CW IRETQ
corruption was not
.CW notify()
but
.CW kprocchild()
starting every kproc's stack inside the
.CW Tos :
pc64 alone points
.CW USTKTOP
at a kernel stack,
.CW userinit()
reserves that region and
.CW kprocchild()
did not, so
.CW kexit() Ns 's
accounting landed on the interrupt frame \(em the captures held
.CW kcycles ,
.CW pcycles
and, in the top word,
.CW pid .
And the FP regression that followed correcting
.CW userureg()
was not fpu.c's own branch, whose flags are write-only here, but a bare
.CW "astate == FPinit"
in
.CW fpurestore() ,
the second of a pair of unmasked comparisons in a file that masks
everywhere else.
.PP
192 boots at
.CW "-smp 2"
with all four fixes: no panic, no
.CW "math emu" ,
no
.CW IRETQ ,
cpu1 online in all 192, and every probe silent but for seven benign
.CW "M is H"
sentinels.
.CW "-smp 4"
brings up four processors.  virtarm64 reaches an interactive shell with
DIS-STRESS-OK, VIRT-OK, ROOT-CMDS-OK and CHANTEST-OK.
.PP
The contention figure on that batch is min 62.9%, median 82.9%, max
96.1% over 192 boots, against a median of 76.9% measured earlier over
94.  The kernel is not the same one, so the two are not a controlled
comparison and the difference is not interpreted here; both say the
same thing about where the work is.
.PP
So pc64 has no known remaining failure.  The next work is Phase 5, and
it is no longer being done around a crash.
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
.NH 2
Audit: what is claimed from a boot, and what from a measurement
.PP
Prompted by the cloud-port session's arm64 timer control, whose general
form is worth keeping: falsify the constant the code would otherwise
trust, then measure something that has to move.  A boot reaching a
prompt is almost never that something \(em they showed a kernel with no
clock at all reaching a shell indistinguishably from a correct one,
because nothing between main() and the shell needs the timer interrupt.
.PP
This branch's one claim of that kind is that cpu1 takes its own timer
interrupt on virtarm64.  It survives the audit, for two reasons.
.IP 1.
It rests on a measurement, not on the boot.
.CW secmain()
stores
.CW mm->ticks
into
.CW seccount
in its idle loop, cpu0 reads that word, delays 50ms and reads it again,
and the print is the delta: four ticks in fifty milliseconds.
.IP 2.
The measurement is taken where interrupts are live.
.CW spllo()
runs on cpu1 before the loop.  This is exactly the placement that
caught them out \(em their first probe read
.CW "ticks 0 -> 0"
on a perfectly correct kernel, because interrupts are masked for the
whole of main() and are not enabled until init0 calls
.CW spllo() .
.PP
And it needs no separate falsification arm, which is the part worth
noticing.
.CW seccount
tracks
.CW mm->ticks ,
and that word is advanced only by cpu1's own clock interrupt handler,
so a non-zero delta cannot be produced without the timer firing.  The
measurement contains its own control.  Where a probe does not have that
property, the falsified-constant arm is not optional.
.NH 2
Every probe left in this branch, and why it can be believed
.PP
Applying the rule the cloud-port session put into words: a probe that
cannot produce a spurious reading needs no falsification arm, one that
can does \(em and if the reason it cannot be written down, it needs a
control.  Writing the reasons down is the exercise; the two that had no
reason got controls.
.IP "\f(CWmaxnrunq\fP (dis.c)" 
Could read plausibly whether or not the run-queue links mean what they
are taken to mean.
.B Control:
the same quantity counted over
.CW isched.head
by
.CW "state == Pready" ,
a different list maintained by different code, with both printed.  Also
a detector: linked exceeding Pready is a Prog queued in another state,
which is the shape of the
.CW delprog()
bug fixed in this branch.
.IP "\f(CWvmblocked\fP (dis.c)"
Was a boolean resting on
.CW vmlock.head
meaning "blocked in
.CW qlock(&vmlock) ".
.B Control:
the chain is walked and every entry checked for
.CW Queueing ,
which
.CW qlock()
guarantees by appending through
.CW up->qnext
and sleeping the process.  Silent.  The walk also yields the depth,
which the boolean did not.
.IP "\f(CWrungc\fP assertion (gc.c)"
Cannot be spuriously silent.  It fires when
.CW regsyncpc
differs from
.CW R.PC ,
and
.CW regsyncpc
is written at all five places
.CW R
is loaded from a Prog and all six where a Prog's
.CW reg
is synced back.  A missing update leaves it stale, which makes the
check fire, not stay quiet \(em it errs toward reporting.
.IP "\f(CWmodlinkmod()\fP (heap.c)"
A containment check, not a measurement, and it fails safe: it can
return nil for a live Modlink (costing a
.CW [?]
in a status line) but returns non-nil only for a pointer that is
canonical, carries
.CW &Tmodlink
in its heap header, and has a canonical
.CW m .
.IP "\f(CWfreetype\fP static-Type guard (heap.c)"
Cannot fire spuriously: the count reaching zero on a static is a real
event, and the guard reports the first per type rather than one per
destroy, so the repeats it used to produce were an artefact of the
repair and not of the detection.
.IP "the \f(CWss\fP probes (trap.c)"
Check the starting state as well as the end \(em the entry arm reports
a frame that is
.I already
bad, which is what distinguishes "the CPU pushed it" from "something
wrote it".  Without that arm the exit comparison alone could have
reported a change off a frame that was never good.
.PP
The last of those is the one worth generalising, and the cloud-port
session found the same hole in a self-test of their own an hour after
writing the rule: a before-and-after check that never reads the before
can report success off a dirty starting state.  "Nothing plausibly sets
this" is the reasoning that makes the read feel unnecessary, and is
exactly the reasoning the rule rejects.
.NH 1
Phase 1b, as it landed: the Dis context is per executor
.PP
The register file, the run queue and the quantum state were one
global, so a second interpreter on a second processor ran on the
first's.  They now live in a
.CW Pctx
that
.CW curP
names, and on amd64
.CW curP
is an external register beside
.CW m
and
.CW up .
Go reaches the current goroutine through a register \(em R14 on amd64,
R28 on arm64, so
.CW getg()
is a register read \(em and this is the same.  It is also the only route
.CW libinterp
can name, since the same sources link into emu and cannot see
.CW Proc .
.PP
Opted into per architecture with
.CW DISCTXREG .
amd64 defines it; every other board and emu keep the global
.CW curP
and are unchanged.
.NH 2
What that cost, in the tools
.PP
kencc assigns external registers per file in declaration order, so a
file declaring only
.CW curP
got R15 \(em the kernel's
.CW m
\(em and booting printed
.CW "cpu3318016: registers for kernel" ,
.CW m->machno
read through a context pointer.
.CW include/disreg.h
declares all three together so both sides agree.
.PP
6c permitted four external registers and reserved two.  The reservation
has to hold in every file 6c compiles, not just the files that declare
the variable: a file that never sees the declaration uses R13 as
scratch and clobbers it across a call into a file that did.  With two
reserved, a third external register is silently broken.  7c had the
same gap and was fixed first.
.PP
Three things the register itself needed, none of them obvious from the
plan:
.IP 1.
It has no initialiser.
.CW "Pctx* curP = &_pctx"
is compiled out under
.CW DISCTXREG
and nothing else writes R13.
.CW machinit()
calls
.CW disctxinit() ,
which runs on cpu0 through
.CW mach0init()
and on each AP through
.CW squidboy() .
.IP 2.
.CW _intrestore
restored R13 from the trap frame on a kernel-mode return.  That is the
staleness the comment there already forbids for
.CW m
and
.CW up :
.CW trap()
can reach
.CW sched() ,
and a process resumed on another processor must keep the value that
scheduler left.
.CW _iretnested
now skips three words.
.IP 3.
.CW sched()
sets
.CW curP
beside
.CW up ,
and must not do so by pre-filling
.CW Proc.pctx :
.CW vmachine()
reaches
.CW claimctx()
through
.CW "if(up->pctx == nil)" ,
so filling the field stopped any context after the first from ever
being claimed \(em one context per boot instead of seven, with the
register mechanism working and nothing using it.
.PP
.CW curR
is gone.  A single
.CW REG*
naming "the current register file" is exactly the global Phase 1b
undoes;
.CW R
is now
.CW curP->reg ,
which is also one indirection cheaper.
.NH 2
Verified
.PP
192 boots at
.CW "-smp 2"
and 192 at
.CW "-smp 4" ,
counting a boot as passing only if it reached the shell, panicked
nowhere and left every tripwire silent.  Testing for panics alone calls
silent queue and context corruption a pass, which is the failure mode
this change can introduce.
.NH 2
With the VM lock off
.PP
.CW *parallelvm=1
on the boot line selects the lock-free mode, so both come from one
kernel; measuring the other used to mean an edit, a rebuild and a
relink to ask a question a boot can answer.
.PP
It does not boot, but it now reaches the shell, which it never did
before, and interpreters inside the VM at once went from one to eight.
Four bugs were found and fixed on the way there, all of them wrong at
.CW parallelvm=0
too, where nothing read the state they corrupted:
.IP \(bu
A blocking Dis system call never reached a safepoint.
.CW isave()
published the registers but left
.CW inxec
set, so a context held its claim for the whole of an unbounded sleep;
.CW stoptheworld()
spun 5569345 times.
.CW isave()
is now entersyscall and
.CW irestore()
exitsyscall.
.IP \(bu
Freeing the running Prog cleared
.CW curprog
and left
.CW inxec
set, so that context never reached a safepoint again.  Named by
instrumenting
.CW Pctx
with its owner and the caller that last set the flag:
.CW "ctx 2 curprog 0x0 set by irestore from closeegrp+0xe, owner pid 9 Queueing" .
.IP \(bu
Two collectors could run at once.
.CW stoptheworld()
waits for contexts with a quantum open and a second collector has none.
.CW gclock()
does not prevent it \(em it is a counter, and both read it as zero.
.CW collect()
gates the whole sequence on a QLock.
.IP \(bu
.CW delrunq()
searched this context's queue and the global one, so a Prog killed on
another context's queue was freed while still linked.
.PP
A wakeup from a process with no context of its own now goes on the
global queue rather than onto whatever
.CW curP
happens to name, which is
.CW globrunqput
and is there for the same reason.
.PP
What is left is not diagnosed:
.CW "incref: bad r 0x300000003"
from
.CW fdtochan+0x63 ,
a corrupt Chan out of an Fgrp.  Two hypotheses were tested and
disproved on the way here \(em that context sharing at
.CW claimctx()
exhaustion was the cause (raising
.CW MAXPCTX
to 32 left five contexts claimed and changed nothing) and that the
compiler's register reservation had broken codegen (the same tree
boots clean with the fix and without
.CW DISCTXREG ).
Neither is written up as a cause anywhere, and neither should be.
.NH 2
Channels: a hazard by reading, not by measurement
.PP
.CW isend()
and
.CW irecv()
walk and edit the channel's send and recv queues, and read and write
the other Prog's
.CW ptr ,
which points into that program's stack.  None of it is locked.  It did
not need to be: the VM lock made every Dis instruction atomic with
respect to every other, and that is the lock
.CW parallelvm=1
removes.  Go's
.CW hchan
carries a mutex for exactly this.
.PP
That much is established by reading.  What reading cannot establish is
whether two executors reach the same channel at once in practice, so
the question was put to a probe \(em twice, because the first one was
wrong.
.IP "first attempt, rejected"
A per-channel nesting count, incremented on entry and decremented on
exit, reporting when it found a count already up.  Its
.CW parallelvm=0
arm fired, and under the VM lock a collision is impossible, so the
count was measuring something else.  It was: a Dis exception leaves
.CW isend()
by longjmp, the decrement never runs, and the count is stuck high for
the life of that channel.  This is the rule of this document's last
section applied to itself \(em a probe that can produce a spurious
reading needs a falsification arm, and this one needed it.
.IP "second attempt, sound and silent"
A stateless check: walk the queue on entry and report an entry that is
not a plausible Prog in a plausible state.  It holds nothing, so it
cannot leak, and it reports damage rather than suspicion.  Silent at
.CW parallelvm=0 ,
and silent at
.CW parallelvm=1
across three boots that all crashed \(em general protection violation
once, page fault twice, after six or seven shell loop iterations.
.PP
So the queues are intact at every entry to
.CW isend()
and
.CW irecv()
in boots that go on to die.  The unlocked channel operations are still
a hazard and a lock is still the right answer for them; they are not
what is breaking these boots, and a channel lock should not be written
up as the fix for a fault it has been measured not to cause.  The
probe is not left in the tree: it is silent, and it walks a queue on
every send and every receive, which is a cost the shipping
configuration should not pay for a detector that has never fired.
.NH 2
Where the remaining faults are, and the structural reason
.PP
The three faults left at
.CW *parallelvm=1
resolve, against the kernel that produced them, to
.CW frame+0x1a ,
.CW movp+0xf7
and
.CW string2c+0x17 .
All three are Dis instructions, and all three are dereferencing a bad
pointer out of the Dis heap.  Not the run queues, not the channels, not
the contexts: the heap.
.PP
Two things were checked first and are not the cause.  The pools are MP
safe \(em
.CW poolalloc()
and
.CW poolfree()
both take
.CW ilock(&p->l) ,
so the commented-out lock on the pool table is not a gap.  And the
tri-colour scheme tolerates a stale read of
.CW mutator :
an object born in the previous cycle's mutator colour is born in this
cycle's
.I marker
colour, which is not swept.
.PP
What follows is a hypothesis, and it has not been measured.  Three
before it were reached the same way -- by reading, after eliminating
something else -- and all three were wrong: context sharing at
.CW claimctx()
exhaustion, the
.CW fpuostate
field, and the channel queues.  This one is written down to be tested,
not because elimination has made it true.
.PP
The suspect is the shape of the safepoint.
.CW stoptheworld()
waits for contexts with a quantum open, and
.CW isave()
gives that claim up when a Dis program enters a blocking system call
\(em which it must, or the collector waits out an unbounded sleep.  But
a released program's system call runs in kernel context and goes on
touching the Dis heap: the builtins allocate,
.CW destroy() ,
.CW incref() ,
and drop the last reference to an object.  None of that is stopped by
stopping the interpreters, so the collector marks and sweeps against a
live mutator that it has been told is at a safepoint.
.PP
This is where the Go analogy stops paying.  Go's
.CW entersyscall
hands the P back and the GC does not care, because a syscall cannot
free anything: the collector owns freeing, and the G's stack stays
scannable.  Dis refcounts, so a system call
.I can
take an object to zero and free it, and "at a safepoint" has to mean
more than "not executing bytecode".
.PP
The Go reasoning above is sound whether or not the hypothesis is: a
refcounting runtime cannot borrow Go's definition of a safepoint
unchanged, because Go's rests on the collector owning every free.
That much is a property of the two designs and needs no boot.  What
needs a boot is whether it is what breaks these three.
.PP
The measurement is one counter: heap operations that happen while
.CW gcstw
is set, in a process that is not the one collecting.
.CW parallelvm=0
is not a control for it \(em
.CW stoptheworld()
returns before setting
.CW gcstw
there, so a zero is a zero for the wrong reason.  The control has to be
inside the probe: count the collector's own heap operations under the
same flag as a second bucket.  A non-zero own-bucket with a zero
foreign-bucket kills the hypothesis and proves the counter works; two
zeroes mean the counter is broken.
.PP
If it is the cause, the mechanism to fix it already exists.
.CW gclock()
raises
.CW gchalt ,
.CW rungc()
honours it by returning, and
.CW delprog()
and
.CW destroystack()
already use it.  What is missing is that the kernel side of a Dis
system call does not, and that
.CW stoptheworld()
does not wait on it.  Both halves are needed and neither is written
here.
.NH 2
The hypothesis, tested
.PP
It was true, and a counter said so rather than an argument.
.PP
The probe went through
.CW heapmonitor ,
the hook
.CW libinterp/heap.c
already calls on every birth and every sweep, so libinterp needed no
change and emu was untouched.  It counted heap operations performed
while
.CW gcstw
was set by a process that was not the one collecting, and it caught, in
three runs out of three:
.IP
.nf
gcstw: heap op 0 from <nil> pid 1, not the collector (dis pid 12)
gcstw: heap op 0 from dis pid 8, not the collector (dis pid 9)
gcstw: heap op 1 from dis pid 8, not the collector (dis pid 9)
.fi
.PP
.CW "op 1"
is heap.c's "about to free".  A mutator was returning a block to the
pool underneath the collector's own mark and sweep.
.PP
The fix is the handover
.CW destroy()
already performs when
.CW gcdepth
exceeds 64: the count is already zero, so nothing refers to the object
and the collector will find it unreachable.  Waiting instead would mean
sleeping in
.CW destroy() ,
which is reached from callers holding locks.  Gated on a
.CW gcstopped
hook that is nil unless a kernel sets it.
.PP
Confirmed by the same counter: across four runs afterwards
.CW "op 1"
is gone and only
.CW "op 0"
births remain, which the tri-colour scheme makes safe.  It is not the
whole of what is wrong \(em the boot still fails, at
.CW movp+0xf7
and
.CW destroy+0x2ca ,
still in the heap \(em but it is the first thing at
.CW parallelvm=1
whose fix the same measurement that found it can show stopped
happening.
.NH 2
Five hypotheses, one survivor
.PP
Worth writing down as a method, because the ratio is the point.
.IP "\f(CWclaimctx()\fP sharing" 
Contexts shared once the pool of eight is used up.  Dead:
.CW MAXPCTX
raised to 32 left five contexts claimed and changed nothing.
.IP "\f(CWfpuostate\fP"
Two Progs sharing an Osenv clobbering each other's FPU save area.
Dead by reading:
.CW "n->osenv = (Osenv*)((uchar*)n + sizeof(Prog))" ,
so every Prog owns its Osenv inline and nothing is shared.  No boot
spent.
.IP "channel queues"
.CW isend()
and
.CW irecv()
edit them unlocked.  Dead by measurement: a stateless queue-integrity
check was silent across three boots that all crashed.  Still a hazard,
still not this one.
.IP "the first channel probe"
Not a hypothesis about the kernel but about the measurement, and it
was wrong: a nesting count that leaks when a Dis exception longjmps
out.  Killed by its own
.CW parallelvm=0
arm.
.IP "the safepoint"
Alive.  Above.
.PP
The four that died all arrived the same way \(em by reading, after
eliminating something else.  The one that lived arrived the same way
too, and the difference is not how it was thought of but that it was
put to a counter before it was written down as a cause.  Four out of
five is the honest prior for the next one.
.NH 2
A third probe, rejected by its control
.PP
The question was direct: is the collector freeing an object that is
still referred to?  A stateless check in
.CW gc.c Ns 's
sweeper, immediately before the block goes back to the pool, reporting
any object arriving there with a non-zero count.  That is what
.CW movp+0xf7
and
.CW destroy+0x2ca
dereferencing bad heap pointers would look like from the other side.
.PP
It fired at
.CW parallelvm=1 ,
three to six objects a boot.  It also fired at
.CW parallelvm=0 ,
six in one boot \(em a configuration that is 192 of 192 clean, and one
where the VM lock makes a collector and a mutator overlapping
impossible.  So a non-zero count at the sweeper is an ordinary event in
this collector, not damage, and the probe cannot tell the two apart.
Removed.
.PP
Why it is ordinary is not established here.  The obvious reading is
that the tracing half of the collector exists precisely to reclaim what
the counts cannot \(em objects that refer to each other and so never
reach zero \(em which would make a non-zero count at the sweeper the
normal case rather than the exception.  That is a hypothesis about the
design and it has not been checked against the design; it is written
down as the thing to check, not as the answer.
.PP
Three probes now, and two of the three were wrong: the channel nesting
count, which leaked, and this one, which measures a normal condition.
Both were caught the same way, by an arm that had to be silent and was
not.  The one that held \(em the heapmonitor counter \(em was the one
whose control was built into it as a second bucket rather than bolted
on as a second configuration.
.NH 2
The livelock in the stop, and how it was hiding
.PP
.CW stoptheworld()
waited with "while another context has a quantum open,
.CW sched() ",
and
.CW enterquantum()
withdrew and retried the same way.  That is a spin.  With more than one
interpreter it livelocks: the collector yields, every other interpreter
yields, and the one process that has to finish its quantum to clear the
flag is the one that does not get a processor.
.PP
It was found by accident, while trying to answer a different question,
and the accident is the part worth keeping.  A twenty-eight boot
interleaved comparison of two kernels differing only in four
reference counts reported the one with the atomic counts failing less
often \(em five boots in fourteen against eight.  That looked like a
result.  It was not: the same kernel made no progress at all in eight
boots of fourteen and did a quarter of the work, because it was hanging
rather than crashing.  Forty-four of fifty-one stalls named the same
blocker, a context whose owner sat in
.CW Ready
with a quantum open, while the collector logged
.CW "stw: 200000 waits" .
.PP
Three separate mistakes had to be corrected before that was visible,
and all three are the same mistake in different clothes:
.IP 1.
The failure classifier keyed on
.CW panic: ,
and the kernel in question failed with
.CW "marklist: bad container"
and
.CW "destroy: bad v" ,
neither of which contains that word.  So "seven panics became one" was
mostly a change in how the failures were spelled.
.IP 2.
A boot that stalls before reaching the shell has nothing to report, and
was therefore scored a pass.  Silence is not success \(em the rule was
already written down in this document, about somebody else's probe.
.IP 3.
The A/B ran the same kernel first in every pair, so any varying
background load fell on the second slot.  Alternating the order left
the result standing, which is the only reason it can be believed.
.PP
The fix is a bound: two thousand tries, then
.CW gcstw
is cleared and the collection is abandoned.  A collection that does not
happen costs memory until the next one, and there is always a next one;
a collection that cannot start costs the boot.  Parking the waiter, as
Go parks an M, is the better answer and a larger change.
.PP
Measured at
.CW *parallelvm=1 ,
.CW "-smp 2" ,
fourteen boots against the two arms of that comparison:
.IP
.nf
                    failed  no-progress  iters  stalled
pre-fix, unbounded   8/14      2/14        52      4
atomic,  unbounded   5/14      8/14        14      9
bounded              8/14      1/14        60      2
.fi
.PP
It gives up eight times in fourteen, which is the mechanism working.
The boot fails as often as it ever did \(em the heap corruption is
untouched \(em but it now fails while running rather than while stuck,
and throughput is the highest measured on this configuration.
.NH 2
A false alarm this branch created
.PP
.CW "marklist: bad container ... ref 0"
is not a fault.
.CW destroy() Ns 's
handover leaves an object that has reached zero still allocated with
its type header intact, and that is exactly the shape
.CW checklistcell()
was calling bad.  Zero boots at
.CW parallelvm=0 ,
where the handover cannot trigger; zero at
.CW parallelvm=1
before it landed; six after.  The check now reports a negative count
and a wrong type, which is what it was written for.
.PP
Worth noticing as a class: a fix that changes an invariant has to go
looking for the assertions that rest on it.  Nothing pointed at this
one \(em it was found because the new message had not been seen before
and was chased rather than assumed to be the bug being hunted.
.NH 2
What is left: a double destroy, and the barrier it points at
.PP
Measured.
.CW "destroy: h->ref underflow"
fires at
.CW parallelvm=1
and in no boot at
.CW parallelvm=0 ,
and it fires both before and after this branch's
.CW destroy()
handover, so it is not something the handover created.  One capture
reaches
.CW "n -2"
on the same header, so it is repeated drops of one object rather than a
single mistake.
.PP
The two captured paths are both pointer teardown:
.IP
.nf
xec -> ret+0x91 -> destroy            a Dis function returning
xec -> scanframe -> freeptrs -> freemodlink -> destroy
.fi
.PP
Increments are not the gap.
.CW movp()
and
.CW incmem() ,
which are how a reference is taken on assignment, both use
.CW AINC .
.PP
.CW Setmark()
is the gap, or is the best remaining candidate for it:
.IP
.nf
#define Setmark(h) if((h)->color!=mutator) { (h)->color = propagator; nprop=1; }
.fi
.PP
That is the write barrier, and it is a non-atomic read-modify-write on
.CW h->color
plus a write to a global.  A mutator outside a quantum \(em a released
Dis system call, running in kernel context, which
.CW stoptheworld()
does not stop and by this branch's own design cannot stop \(em can mark
an object the collector has already scanned white.  The collector
sweeps it while it is live, and every later
.CW destroy()
through a stale pointer to it underflows, which is the shape the
captures have.
.PP
Labelled a hypothesis, and it is the sixth.  What supports it: the
underflow is real and configuration-specific, the increments are ruled
out by reading, and the counter this branch already has shows foreign
heap operations happening under a stopped world.  What does not
support it: nothing has yet shown a lost mark, which is the step the
argument needs and the one a probe should target.
.PP
The deferral idiom does not extend to it.  A free can be handed to the
collector because the object is already unreachable; a mark cannot be
deferred, because the whole point is that it must happen before the
sweeper looks.  The shapes worth considering, none of them small:
.IP \(bu
Abandon a collection in which any foreign heap operation occurred, the
way this branch's
.CW stoptheworld()
now abandons one it cannot start.  Conservative, and it reuses a
counter that already exists.
.IP \(bu
Make the barrier atomic and give the collector a re-scan phase, which
is the incremental-update barrier every concurrent collector has.
.IP \(bu
Stop treating a released Dis system call as a safepoint, which is where
this started and which cost an unbounded stall the first time.
.NH 2
The sixth hypothesis, refuted
.PP
.CW Setmark()
is not it.
.PP
The probe that settles it is not the one the previous section asked
for.  That one watched for the colour of a block changing between the
sweeper's test and the free, and it was silent across ten
.CW parallelvm=1
boots \(em which establishes nothing, because its only control is
.CW parallelvm=0 ,
where it cannot fire by construction.  A working probe and a broken one
look identical under that arrangement, and two of this branch's three
earlier probes died exactly there.  It was removed rather than
reported.
.PP
What settles it is asking a question at an event that is known to
happen.  The count underflow in
.CW destroy()
fires three times in about fifty
.CW parallelvm=1
boots and in none at
.CW parallelvm=0 ,
so printing the object's colour and type at that point needs no
positive control: the event arrives on its own.  It took twenty-two
boots to catch one, which is the rate the earlier captures predicted.
.IP
.nf
destroy: h->ref underflow, h 0x7936bd8 n -1 colour 0 (mutator 0) t 0x345700
.fi
.PP
Mutator-coloured, with a type pointer that is still a type.  The block
had not been swept.  So the corruption is not the collector reclaiming
a live object, and every version of "the write barrier lost a mark"
predicts a swept block.  Refuted, and the print stays in the tree so
the next reader does not spend a session arriving at it again.
.PP
What is left is narrower and harder: a genuine unbalanced drop.  The
counts are atomic in both directions, so this is not a lost update but
a reference released twice by two executors that each believed they
held it.  The two captured paths are
.CW "xec -> ret -> destroy" ,
a Dis function returning and tearing down its frame, and
.CW "xec -> scanframe -> freeptrs -> freemodlink -> destroy" .
Both are teardown of a structure that Progs of the same module share,
which is the direction to look and is not yet a hypothesis.
.PP
Six raised, five refuted, one confirmed and fixed.  The confirmed one
was the only one put to a counter before it was believed.
.NH 2
A note on the bench, because it invalidated a measurement
.PP
This machine runs other work.  Partway through a
.CW "-smp 2"
against
.CW "-smp 4"
comparison, a foreign
.CW qemu-system-aarch64
appeared at 299% of a core, and the boots on both arms slowed by about
half: 182 lines of console in thirty-five seconds where the same kernel
had produced 422, and shell loop iterations across sixteen boots
falling from about sixty to eleven.
.PP
The comparison duly reported
.CW "-smp 4"
failing less often, and it means nothing.  Fewer failures because less
happened.  It is the third time on this branch that a quieter number
has turned out to be a slower kernel rather than a better one \(em the
first was a probe that leaked, the second a kernel that hung instead of
crashing \(em and the shape is always the same: something that should
have gone up did not, and only the failure count was being read.
.PP
So a rule for anything measured here.  Record work done, not just
failures: shell loop iterations, console lines, whatever the workload
makes.  A run that fails less while doing less has not improved, and
the only way to see that is to have counted both.  The boot batch
counts
.CW noshell
separately for this reason and should have been the model for the
smaller experiments sooner than it was.
.PP
The corollary is scheduling.  A 192-boot batch and a sixteen-boot
comparison cannot share this machine; each makes the other's numbers
untrustworthy, and the batch is the one that matters, because it is
what guards the configuration that ships.
.NH 2
How many contexts a boot actually wants
.PP
Counted across 192 boots at
.CW parallelvm=0 ,
now that the pool is large enough to record the answer rather than
truncate it:
.IP
.nf
 7 contexts   102 boots
 8             56
 9             18
10             11
11              3
12              2
.fi
.PP
Thirty-four boots in 192 want more than eight.  The pool held eight, so
in those thirty-four the interpreters after the eighth were handed
pctxs[0] and ran on a register file somebody else was using.  With the
VM lock that is harmless and invisible, which is why it took
.CW parallelvm=1
to find it \(em but the pool was undersized in the shipping
configuration as well, and had been all along.
.PP
Worth stating because it inverts the obvious reading.  The context pool
looked like a parallel-mode concern, and the number that mattered was
sitting in the boots everyone had already run.
.NH 2
Verified, on the tree as it stands
.PP
192 boots at
.CW "-smp 2"
and 192 at
.CW "-smp 4" :
no panics, no tripwires, and no boot that failed to reach the shell.
A boot counts as passing only if it reached the shell, panicked
nowhere, and left every tripwire silent; the timeout was calibrated
first, five boots reaching 68 to 72 shell loop iterations inside a
45-second window, so a
.CW noshell
in the batch would mean the kernel and not the bench.
.NH 2
The noise floor, measured at last
.PP
Every comparison on this branch assumed one and none had measured it.
The same kernel, byte for byte, under two names, twelve boots each,
order alternating, at
.CW *parallelvm=1 :
.IP
.nf
selfa  53 iterations   2 4 7 9 5 2 5 5 4 3 5 2   gave up 6
selfb  47 iterations   5 5 2 3 5 6 3 7 5 4 1 1   gave up 3
.fi
.PP
Three things follow, and one of them is a warning about numbers this
document already contains.
.IP 1.
Totals differ by twelve percent between identical binaries.  So the
ratios acted on earlier \(em eighteen against two, thirty-six against
three, thirty-five against nothing \(em are far outside the spread and
those conclusions stand.
.IP 2.
Every one of the twenty-four boots reached the shell, between one and
nine times.  None produced nothing.  A kernel that produces a column of
zeroes is therefore different in kind, not unlucky, which is what makes
the trimmed kernel's zeroes evidence rather than variance.
.IP 3.
.B "Give-ups vary by a factor of two between identical binaries."
Six against three.  That number was read as a mechanism working \(em
"give-ups nine to three" \(em and at twelve boots it cannot carry that
weight.  The conclusion it supported is held up by the iteration counts,
which are outside the spread, and not by the give-ups, which are not.
.PP
The general form: a comparison needs its own control run before it
needs more samples.  Twelve boots of one kernel against itself costs
what one arm of an A/B costs, and it is the difference between a ratio
that means something and a ratio that is arithmetic.
.NH 2
Where parallelvm=1 stands
.PP
Nought failures in twenty-four boots, against eight in twenty earlier
in the branch, and every boot reaching the shell.  That is not "it
works" \(em the sample is small, the bench is shared, and the
underflow that started the last hunt appears about once in twenty-two
boots, which twenty-four cannot resolve.  It is the first measurement
on this configuration that does not have a failure in it.
.NH 2
parallelvm=1, measured over 96 boots
.PP
Scored as the shipping configuration is, except for one exclusion
explained below:
.IP
.nf
96 boots, -smp 2      2 failed, 0 reached no shell
shell loop iterations 303, mean 3.2, range 0 to 9
collections abandoned 54
.fi
.PP
Two failures in ninety-six, against eight in twenty earlier in the
branch.  Both are the same shape: a jump into the Dis heap,
.CW "PC 0x79174f0"
and
.CW 0x7917503 ,
nineteen bytes apart and so probably the same structure, with the
bad-xec tripwire silent \(em so not
.CW Prog.xec
but another function pointer, which leaves
.CW Type.mark ,
.CW Type.free
and
.CW Channel.mover .
.PP
The exclusion:
.CW "counts disagree"
fired in 96 boots of 96 and is not counted.  It is the
.CW maxnrunq
control, and it is sound with the VM lock and unsound without it \(em
the walk reads other contexts'
.CW nlocal
while their owners are writing it.  0 of 192 at
.CW parallelvm=0
and 96 of 96 at
.CW parallelvm=1
is the signature of a counter that races, not a queue that does.  The
first run of this batch counted it and reported 96 failures of 96,
which is what a classifier does when it is handed a control that only
holds in one of the two modes.
.NH 2
The remaining parallelvm=1 fault is an old one
.PP
It is the frame-type lifetime bug this document already describes, and
.CW xec.c
already carries the diagnosis above
.CW framerefs :
a frame stores
.CW R.M->type[]
in
.CW f->t
and takes no reference on it, because a frame is stack and its module
is meant to outlive it.  The shell drops a module while a frame of one
of its types is still on a stack,
.CW freemod()
frees the type, and the next reader walks it.
.PP
The captures match that and nothing else.  Three in sixty boots, all
one shape:
.CW f->t
still holding the pointer the frame always held, so the frame is
intact; the block it names no longer a Type;
.CW mark
inside the Dis heap at a constant
.CW t+0xA200 ;
.CW size
zero, which is where a freed block keeps
.CW reallocpc
and what malloc leaves there.
.PP
So this is not a parallelism bug.  It reproduces on virtarm64, which
has one scheduling processor, and
.CW parallelvm=1
only makes it likelier -- more interpreters, more module loading and
dropping, more frames alive across it.  That is worth saying plainly,
because a fault found while chasing parallelism invites being blamed on
it.
.NH 2
What the framerefs switch measured, and what it did not
.PP
Turning it on, sixty boots each at
.CW *parallelvm=1 :
.IP
.nf
framerefs=0   3 bad frames in 60
framerefs=1   1 bad frame  in 60
.fi
.PP
That is not an improvement, and it should not be read as one.  Against
an expected three, seeing one or fewer happens about a fifth of the
time by chance; at sixty boots the two numbers are the same number.
Separating them needs a few hundred boots an arm, which is the
measurement to run, not another sixty.
.PP
The switch stays off regardless, and its own comment says why: it
counts the reference at
.CW OP(ret)
only, so a process killed with frames on its stack leaks type
references, and the JIT's
.CW freeptrs()
paths are untouched.  It was built to test the diagnosis, not to ship,
and the diagnosis is now supported by the captures instead.
.NH 2
framerefs, measured properly, does nothing
.PP
120 boots an arm, interleaved, order alternating, at
.CW *parallelvm=1 :
.IP
.nf
framerefs=0   2 bad frames in 120   0 underflows   470 iterations
framerefs=1   2 bad frames in 120   0 underflows   477 iterations
.fi
.PP
The same number, and the work done within one and a half percent.  The
release side was completed first \(em OP(mcall) and destroystack() as
well as OP(ret) \(em so this is the complete switch and not the partial
one, and no count underflow appeared in either arm, which is what the
two added releases had to be shown not to cause.
.PP
That is a negative result and it is informative, because
.CW leaktypes
is not.  An earlier session measured that one: eight boots leaking
showed no freed or garbage Type, six not leaking showed twelve
occurrences.  Both switches prevent the same
.CW freetype()
call in
.CW freemod() ,
which does respect the count \(em so preventing the free works and
holding a reference does not.
.PP
The difference says where to look next.  If a frame's reference cannot
save its type, the frame may not be alive when
.CW rootset()
walks it:
.CW OP(ret)
has already run and released, and the walk is covering a frame that has
been popped.  That is a bug in the range
.CW rootset()
walks \(em
.CW sx->reg.tos.fu
down to
.CW sp
\(em rather than in the type's lifetime, and it would explain why
leaking types hides it and counting references does not.  Untested, and
written down as the next thing to test rather than as the answer.
.NH 2
The fault rate depends on the bench
.PP
The same
.CW framerefs=0
kernel measured 3 bad frames in 60 boots earlier in the day and 0 in
89 later.  If the rate were constant, the second is about a one percent
event.  It is not constant: the machine was carrying other virtual
machines during the first and was quieter during the second, and a race
gets more chances when the host preempts more.
.PP
So every rate in this document is conditional on the bench, and two
runs taken at different times cannot be compared \(em including the
"2 failures in 96 boots" above.  Only an interleaved A/B within one run
holds, which is why the later comparisons are built that way.
.NH 2
The frame walk's bound, and eight hypotheses that were not it
.PP
The
.CW *parallelvm=1
fault that outlasted everything else is not what any of its symptoms
suggested.
.CW rootset()
assumes a stack extent's frames tile
.CW tos.fu..sp
and steps by
.CW t->size .
Frames also link through
.CW f->fp ,
and that chain says which are live.  Printing both at a failure ends the
argument:
.IP
.nf
frame 7 of 0x7a81358..0x7a819b8 at 0x7a81770, size 0, from f->t
fp chain from 0x7a81358: 0x7a81358 (0 shown)
.fi
.PP
.CW rr->FP
is
.CW tos.fu ,
the bottom of the extent, and that frame's
.CW fp
is nil.  One live frame.
.CW sp
is 0x660 above it, so the walk covers eight frames' worth of address
range, reads stale frame data that tiles for six steps because the
sizes happen to be plausible, and then does not.
.PP
So the bound is wrong and the memory is not.  Every symptom this hunt
chased is downstream of that: the bad frame type, the nil
.CW t ,
the zero size, the
.CW mark
inside the Dis heap, the jump through
.CW t->mark ,
the "panic: invalid opcode" at a heap address.  It also explains the
geometry repeating across captures with different pids and extents --
one program's stack layout against a bound that does not fit it, not a
race window landing twice in the same place.
.NH 2
What was eliminated, and how
.PP
Eight, each by measurement rather than by argument.  The ratio is the
point: the symptom was three layers from the cause, and every layer had
a plausible story attached to it.
.IP "a freed Type"
.CW dtype()
mallocs every Type into the kernel pool; the captured pointer is in the
Dis heap, so it was never a Type.  This retired
.CW freetype() Ns 's
deferral, the completion of
.CW framerefs
across all three teardown paths, and a 120-boot-an-arm A/B that showed
2 bad frames in 120 either way.
.IP "a misaligned walk"
Frames 0 to 6 tile exactly, so the walk keeps its place.
.IP "a stale context register file"
.CW progreg()
returned
.CW p->reg ,
not a context's.
.IP "two executors on one Prog"
A mark on Prog recording the context inside
.CW xec() :
0 in 45 boots, with tile failures in the same run.
.IP "a context missed by \f(CWprogreg\fP"
It scans
.CW "i < npctx"
and
.CW claimctx()
publishes with
.CW "pctxs[npctx++] = c" ,
unordered and read unlocked.  The whole array is scanned at the failure
and no context claims the Prog.
.IP "a stack freed under \f(CWgclock\fP"
.CW progexit()
holds it across
.CW destroystack() ,
and
.CW stoptheworld()
waits on
.CW inxec
and never on
.CW gchalt ,
so a process freeing its stack is invisible to it.  Worth testing for
that reason;
.CW gchalt
is 0 at every capture.
.IP "a freed or recycled extent"
.CW unextend()
and
.CW unframe()
free one back to mainmem during ordinary
.CW OP(ret) ,
outside
.CW gclock .
The block header says
.CW MAGIC_A :
allocated.
.IP "the write barrier"
Covered earlier; a lost
.CW Setmark
predicts a swept block and the object was mutator-coloured.
.NH 2
Where it goes next
.PP
Two things, neither done.
.PP
.CW propex()
is the last writer of the snapshot in every capture of this class, and
its prologue has a path that leaves
.CW R.SP
alone:
.CW "freeframe(R.EX+OA(Stkext, reg.tos.fr), 0)"
passes
.CW setsp
as 0, where the other branch passes 1.  Whether that branch ran in
these captures is not established and should not be guessed at -- this
document has eight entries above explaining why.
.PP
The collector's own repair is to follow the
.CW f->fp
chain rather than assume tiling.  A chain cannot be made wrong by a
stale
.CW SP ,
and walking it marks the frames that are live rather than the address
range that ought to hold them.  It is a change to what the root set
is, so it wants the 192-boot batch and a
.CW parallelvm=1
rate against the current 2 in 50, not a spot check.
.NH 2
The fault, found: a torn register snapshot
.PP
.CW vmachine() Ns 's
.CW waserror()
block clears
.CW inxec
at the top, so
.CW stoptheworld()
stops waiting for that process, and then calls
.CW handler() ,
whose
.CW "memmove(&p->reg, &R, sizeof(R))"
rewrites the Prog's saved registers.  The collector could walk
.CW p->reg
while that memmove was partway through it.
.PP
Measured, with a probe comparing
.CW rr->SP
against itself \(em an earlier one compared it against the walk's loop
variable and had to be retracted:
.IP
.nf
rr->SP first 0x7a80738 now 0x7a80170 CHANGED; FP 0x7a800d8
rr->SP first 0x7a755b8 now 0x7a74ff0 CHANGED; FP 0x7a74f58
rr->SP first 0x7a75738 now 0x7a75170 CHANGED; FP 0x7a750d8
.fi
.PP
Five of seventy boots, every one changed, every new value
.CW FP
plus 152 \(em the live frame's size, the right answer arriving after the
walk had taken a stale one.  Claiming the quantum around
.CW handler()
takes that to one of seventy, and that one reports the pair
.I unchanged ,
which is a different fault.
.PP
The chain reads backwards cleanly.  A torn
.CW SP
gives a bound over popped frames; stale frame data tiles for six steps
because the sizes it holds happen to be plausible; the seventh block is
not a frame, so its
.CW t
is not a Type; calling
.CW t->mark
jumps into the Dis heap; "panic: invalid opcode" at a heap address.
Eleven eliminated hypotheses were all downstream of one unprotected
write.
.NH 2
Two corrections this cost, and they are the lesson
.PP
The first fix went around
.CW propex() ,
which is exception propagation to a process group and writes no
registers at all.  It changed nothing over seventy boots, as it could
not have.  The
.CW regsrc
tag saying "propex" was my own mislabel: the write is in
.CW handler() ,
and I named the tag after the call I had been reading in dis.c rather
than the function the memmove sits in.  An instrument that names the
wrong thing will keep confirming it.
.PP
The first torn-read probe compared the walk's
.CW sp
\(em a loop variable, reassigned to
.CW sx->reg.SP
at the foot of every extent \(em against a fresh read of
.CW rr->SP .
For any extent after the first those are different fields, and I read
their difference as one field changing.  Same error as reading console
lines as progress earlier in this document: a value that was in scope
got used as the value that was meant.
.NH 2
A rare one, and not a regression
.PP
A
.CW "math emu ... pc _fxsave+0x0"
panic appeared once in 96 boots at
.CW parallelvm=0 ,
where the two previous batches were 192 of 192.  doc/inferno-ports.ms
documents that signature and records it as rare \(em 880 boots once
passed before it first showed.  The guard it describes is intact:
.CW matherror()
and
.CW simderror()
both
.CW _clts()
before
.CW fpsave() .
.PP
Tested rather than assumed, the kernel before the
.CW handler()
claim against the kernel after it, sixty boots each, interleaved: 0 and
0.  Rarer than one in sixty on both, so there is no evidence the change
introduced it, and a single occurrence is what a low-rate fault looks
like.
.NH 1
The channel region
.PP
Two hazards were found by reading rather than by a failing boot, and
neither can be exhibited at
.CW parallelvm=0 :
.CW OP(movp) 's
read-modify-write on memory two Progs of one module share, and the
channel send and recv queues, which nothing locked.
.PP
The first is small.
.CW movp
reads the pointer it is about to displace, stores the new one, then
destroys what it read.  Module-level variables live in the Modlink's
.CW MP ,
and every Prog of a module shares one Modlink, so two Progs assigning
the same variable both read the old value, both store, and both destroy
it: one heap block released twice, the other leaked.
.CW aswap()
is
.CW XCHGQ
on a memory operand, which is atomic on amd64 without a
.CW LOCK
prefix, so each executor destroys exactly what its own store displaced.
It is behind
.CW ASWAPOK
so only ports with the instruction take that path.
.NH 2
What the queues get wrong
.PP
A channel operation reads a channel's send and recv queues, takes a prog
off one of them, moves the value between the two progs' operands, and
puts the woken prog on a run queue.  With one interpreter that needs no
lock, because nothing else can be inside a channel operation at the same
time.  With more than one:
.IP \(bu
two interpreters on the same channel both find
.CW c->recv->prog
nil, both queue themselves to send, and the second's
.CW "(*q)->prog = p"
in
.CW cqadd()
overwrites the first \(em a prog queued on nothing, never woken;
.IP \(bu
one hands a value over while the other is unmarking the same alt, and a
prog is put on a run queue twice.
.PP
A Prog on two queues is the shape three separate faults in this tree
resolved to.  It gets freed while still linked, and the context that
picks it calls through
.CW r->xec
into freed memory:
.CW "panic: invalid opcode" .
.NH 2
One lock, not one per channel
.PP
.CW chanlock() /\c
.CW chanunlock()
in
.CW os/inferno/port/dis.c
take a single
.CW Lock
for every channel in the system.  An alt spans every channel in the alt
at once, so per-channel locks would need an ordering to take them in,
and the handoff touches two progs' queues besides.  One lock is the
version whose correctness can be read off the code.  Making it
per-channel is a separate change and wants a measurement to justify it.
.NH 2
Three longjmps, removed rather than handled
.PP
It is a
.CW Lock ,
not a
.CW QLock ,
so nothing in the region may sleep or
.CW error() .
Plan 9's answer to a longjmp in a critical region is the
.CW waserror()
idiom \(em
.CW "lock(&l); if(waserror()){ unlock(&l); nexterror(); } ... poperror(); unlock(&l);"
\(em which works because
.CW error()
longjmps to a label on the erroring process's own stack, so the handler
is ordinary code that can release the lock before passing the error on.
The kernel has about fourteen hundred of these;
.CW chan.c:1288
is typical.  A sleeping
.CW QLock
survives that idiom; a spin
.CW Lock
should not be held across anything that can block at all, which is why
.CW qlock()
prints a complaint when
.CW up->nlocks
is non-zero.
.PP
Where the allocation can be hoisted, the better answer is the one that
removes the longjmp, and here all three could be:
.IP \(bu
.CW cqadd() 's
.CW malloc() /\c
.CW error(exNomem)
became
.CW cqfill() ,
which takes the cells the operation can possibly need before the region
opens.  A channel's queue head is allocated with the channel; only a
second prog queueing on the same channel needs another cell.
.CW cqdel() /\c
.CW cqdelp()
return cells to the same per-executor list instead of freeing them, so
the region is out of the allocator in both directions and the usual
operation finds its cell already waiting.
.CW cqtrim()
gives back what a large alt left over.
.IP \(bu
.CW altrdy() 's
.CW error(e)
for a nil or self-referencing channel became a string returned to
.CW xecalt() ,
which raises it after the unlock.
.IP \(bu
.CW isend() /\c
.CW irecv() 's
.CW error(exNilref)
moved into the wrappers, ahead of the lock.
.CW isendx() /\c
.CW irecvx()
are the operations proper and take the channel as an argument, which is
also what
.CW altcomm()
needs: it is already inside a region, so it calls those directly.
.PP
.CW altcells()
counts what
.CW altrdy()
can spend.  It has to walk the same channels in the same shape \(em an
array channel on the recv side expands to one cell per element \(em or
.CW cqadd()
panics on an empty pool.  The two are kept adjacent for that reason, and
.CW cqadd()
panics rather than erroring because an empty pool there is a caller bug,
not a runtime condition.
.PP
.CW altcells()
counts before the lock and
.CW altrdy()
spends after it, so the panic is only sound if neither number can change
in between.  Both were checked rather than assumed.
.CW ac->c
is a frame-local copy: the compiled code builds the
.CW Alt
structure on the prog's own frame, from the prog's own operands, before
the alt instruction runs, and no executor writes another prog's frame.
.CW Array->len
is immutable for a given Array object \(em every
.CW "a->len ="
in
.CW libinterp
is at creation, and
.CW OP(slicea)
builds a
.I new
Array header rather than shortening the one it slices.  Had either been
mutable, the panic would have turned a rare race into a crash where the
old code merely called
.CW malloc() .
The
.CW +1
for
.CW altcomm()
is slack rather than necessity \(em it only sends or receives on a
channel it has just found ready under the lock, so it takes the handoff
or the buffer path and never queues \(em and is kept anyway.
.NH 2
Why a recursive lock would have been wrong
.PP
The re-entrant path is
.CW movtmp
\(->
.CW freeptrs
\(->
.CW destroy
\(->
.CW freechan
\(->
.CW killcomm ,
reached when a handoff displaces the last reference to a Channel.
.CW killcomm()
wakes every prog queued on the dying channel, and for a prog in an alt
that means
.CW altgone()
\(->
.CW altdone() ,
which walks that prog's whole alt and unmarks it from
.I every
channel in it \(em not just the dying one.
.PP
A recursive lock would let that through without deadlocking, and that is
the trap: it would be mutating the very queues the outer
.CW isend()
is midway through, after the
.CW cqdel()
and before the
.CW addrun() .
Not deadlocking is not the same as being correct.  So the free is
deferred instead.
.CW destroy()
asks
.CW chandefer()
before freeing a Channel; inside a region that takes a reference, parks
the block on a small per-\c
.CW Pctx
list, and
.CW chanunlock()
frees it once the region is closed.  The reference is taken
.I before
the block is parked, because a count of zero is sweepable and the
collector runs on another CPU.  The list is 64 entries, which is
.CW destroy() 's
own
.CW gcdepth
recursion bound; if it ever overflows, the block is left to the
collector \(em the same handover the
.CW gcdepth
and
.CW gcstopped
arms next to it already do, and a counter says so.
.PP
The hook is installed in
.CW disinit() ,
not in
.CW stoptheworld()
where
.CW gcstopped 's
is.  A channel operation takes the lock whatever
.CW parallelvm
says, so a Channel freed inside one must be deferred whatever it says
too; installing it under
.CW parallelvm
would have made
.CW freechan
\(->
.CW killcomm
\(->
.CW chanlock
a Lock taken twice by its own holder at
.CW parallelvm=0 .
.PP
.CW killcomm()
therefore opens a region itself: its callers \(em
.CW chanunlock() 's
drain, or the collector's sweep \(em are all at depth 0.  It drops the
region around
.CW swiprog() ,
because that posts a note and
.CW postnote()
qlocks.  Dropping it there is safe because the channel's count has
already reached zero: nothing can reach it to queue on it while the lock
is down.
.CW exprog()
and
.CW killprog()
take the region around their
.CW Palt /\c
.CW Psend /\c
.CW Precv
arms only, which leaves their
.CW Prelease
arm's
.CW swiprog()
outside it.
.NH 2
The audit, not the hope
.PP
"Nothing in the region sleeps or errors" is checkable, so it was
checked rather than asserted.  A transitive walk of the region's callees
across
.CW libinterp
and
.CW dis.c ,
rooted at
.CW isend ,
.CW irecv ,
.CW xecalt
and the movers (which are reached through
.CW c->mover() ,
an indirect call no walker can see, so they are named as roots), reports
sixty-two functions and finds:
.CW error()
in exactly the three places listed above,
.CW malloc()
in exactly one, no
.CW sleep() ,
no
.CW qlock() ,
and
.CW lock(&isched.l)
reached through
.CW addrun() /\c
.CW gput() .
That last is a nesting, so the reverse edge matters: no
.CW lock(&isched.l)
region in
.CW dis.c
reaches
.CW cqdelp ,
.CW altdone ,
.CW addrun ,
.CW killprog ,
.CW exprog
or
.CW swiprog ,
and nothing outside
.CW dis.c
can take that lock \(em
.CW isched
is static to the file.
.PP
The first version of that walk reported a clean region and was wrong.
Its function-body extractor tried a general
.CW "name(" 
pattern before the
.CW "OP(name)"
one, so every
.CW OP()
in the interpreter was recorded under the name
.CW OP
and
.CW isend 's
and
.CW irecv 's
bodies were never scanned at all.  A tool that reports "nothing found"
because it looked at nothing reads exactly like a tool that found
nothing.
.PP
With the deferral in place, the scary part of that subtree is not in the
region at all:
.CW destroy()
returns early, so
.CW freechan ,
.CW freetype ,
.CW freemod
and
.CW freejitcode
are unreachable from inside one.
.NH 2
The stress, and what makes it evidence
.PP
.CW appl/cmd/chantest.b
\(em which already carried four cases written before this locking landed,
so that "still passes" would mean something now \(em gained four more,
and is embedded in the pc64 image and run three times concurrently from
.CW /dis/init ,
because one prog doing channel operations on its own never puts two
executors inside a channel operation at the same time, which is the
thing being tested.  Each part asserts something a broken channel
operation gets wrong rather than running traffic and hoping a panic falls
out:
.IP \(bu
The four that were already there:
.I two-senders-one-channel
(every value sent arrives exactly once \(em a lost or duplicated handoff,
which is what the
.CW cqadd()
overwrite produces, fails it),
.I alt-against-send ,
.I two-alts-opposite-order
and
.I buffered-two-senders .
.IP \(bu
.I channel-over-channel :
a channel sent over a channel of channels, with the receiver's variable
displaced each time and the sender dropping its own reference, so the
displaced Channel's last reference goes while a channel operation is in
progress.  This is the path that reaches
.CW killcomm()
from inside the region.
.IP \(bu
.I channel-in-adt :
the same, with the channel inside an adt sent by value, so it is the
type's pointer map and not a bare channel operand that gets freed.
.IP \(bu
.I alt-over-array :
alt over an array of channels with an ordinary channel alongside \(em
the one shape that queues a prog on one cell per element, which is what
.CW altcells()
has to count element-wise.  Every value carries the index it was sent
from, so a mis-counted or mis-unmarked array alt shows up as a wrong tag
rather than as silence.
.IP \(bu
.I alt-on-buffered :
an alt whose arms are buffered channels, which is
.CW CANPUT() /\c
.CW CANGET()
in
.CW altrdy()
and
.CW cputb() /\c
.CW cgetb()
reached through
.CW altcomm()
\(em the buffered branches of
.CW isendx() /\c
.CW irecvx() .
Found by asking which shapes the other eight cases miss rather than by a
failure: one case had a buffered channel with no alt, three had alts with
no buffer, and nothing reached both at once, which is precisely the
combination the split rearranged.
.IP \(bu
.I kill-while-blocked :
progs killed while blocked in send, in recv and in alt, then the
channels used again afterwards.  This is what drives
.CW cqdelp() /\c
.CW altdone()
from
.CW exprog() /\c
.CW killprog() ,
and
.CW killcomm() 's
own arms when a killed prog's stack drops the last reference to a
channel another prog is still queued on.
.PP
The first version of
.I kill-while-blocked
gave the recv-blocked and send-blocked progs the same channel.  They
rendezvoused with each other and were gone before the kill, so two
thirds of the kills reported "open /prog/N/ctl failed" and the arm
tested nothing.  Each blocked prog now gets a channel nothing else uses.
.PP
Two one-shot prints are the positive controls, and they matter more than
the PASS line.  A clean
.CW parallelvm=1
run says nothing about whether the lock mattered unless something says
two executors were really inside a channel operation at once, so
.CW chanlock()
reads the lock word without the lock \(em deliberately racy, and it can
only under-report \(em and prints
.CW "chanlock: first contention"
the first time it finds it taken.
.CW chandefer()
prints
.CW "chanlock: first channel free deferred past the region"
the first time the deferral fires.  Without those, a passing run cannot
be told from a run where neither path was ever reached.
.PP
.CW *chanlock=0
on the boot line keeps all the restructuring \(em the cell pool, the
split operations, the deferral \(em and drops only the lock, so the two
halves of the change can be measured apart from one kernel.  Temporary,
like
.CW *parallelvm .
.NH 2
What the region measured
.PP
Interleaved, order alternating, thirty boots each of the kernel before
the region and the kernel after it, at
.CW parallelvm=0
on
.CW -smp 2 :
.TS
center;
l r r r r r.
	reached shell	iterations	panics	tripwires	chantest
before	30 of 30	2386	0	0	\(em
after	30 of 30	2190	0	0	90 of 90
.TE
.PP
The iteration counts are not comparable and are printed only so nobody
later reads their absence as concealment: the kernel after the change
runs three concurrent
.CW chantest
instances on every boot that the kernel before it does not, so it is
doing strictly more work for a slightly lower count of the thing being
counted.  The columns that compare are the other three, and they are
equal.
.PP
The deferral fired on all thirty boots after the change, which is what
makes the chantest column mean something: the path being tested was
reached every time, not merely present.
.PP
The kernel before the change carries no
.CW chantest.dis
at all, so its chantest column is zero by absence and not by failure.
Reading it as eight failing cases would be wrong.
.NH 2
A comparison that measured the wrong thing
.PP
The commit that landed the region said of one stalled
.CW parallelvm=1
.CW "-smp 4"
boot that "the per-context queue dump says it is not this", on the
strength of
.CW "chan regions 156, contended 0" ,
.CW inchan
zero on all seven contexts, three procs queued at
.CW collect+0x13
and
.CW "stw waits 5400" .
That reasoning is fine and the counters are real, but it was one boot
with no baseline arm, which is not enough to attribute anything.
.PP
The baseline arm, twelve boots each interleaved, said the opposite:
.TS
center;
l r r.
	reached shell	iterations
before	4 of 12	6
after	0 of 12	0
.TE
.PP
Read at face value that is a regression.  It is not, and the reason is a
confound this document should have caught before the batch ran rather
than after: the kernel after the change runs three concurrent
.CW chantest
instances
.I before
the shell loop, and the kernel before it runs none.  Checking what those
runs actually did settles it \(em across twelve boots exactly one case,
.I two-senders-one-channel ,
ever completed, four times.  The new kernel never reached the shell loop
at
.CW parallelvm=1
.CW "-smp 4"
because it was still inside the extra work, not because it stalled.
"Reached the shell" measures the workload here, not the kernel.
.PP
Two lessons, both already written down elsewhere in this document and
both ignored anyway.  A metric has to be checked against the thing it is
standing in for before a batch is run on it, not after the numbers look
wrong.  And an arm that carries extra work is not a control for an arm
that does not.
.PP
The comparison that does isolate the lock is one kernel against itself:
.CW *chanlock=1
against
.CW *chanlock=0 ,
same binary, same workload, the switch put there for exactly this.  The
metric is how far the three chantests get \(em
.CW ok
lines completed out of twenty-four \(em because at this configuration
neither side finishes them inside the timeout, so progress is the
measurement and completion is not.
.NH 1
The collector parks instead of spinning
.PP
.CW "stw waits"
reached 56500 in a single
.CW parallelvm=1
.CW "-smp 4"
boot, and the counter is turns round
.CW stoptheworld() 's
wait loop, each of which is a
.CW sched()
\(em a context switch.  The wait was costing more than the collection it
was waiting for.
.PP
How much more is not a single number and should not be written as one.
The shell loop runs at 73 iterations a boot at
.CW parallelvm=0
.CW "-smp 2" ,
at about 2.5 a boot at
.CW parallelvm=1
.CW "-smp 2"
across a sixty-boot run, and at 0.5 a boot at
.CW parallelvm=1
.CW "-smp 4"
across twelve \(em between one thirtieth and one hundred and fiftieth,
depending which pair is compared, and those were not all measured on the
same kernel or the same machine load.  What is solid is the order of
magnitude and the direction.
.PP
The comment on that loop already named the answer and deferred it:
"parking rather than spinning, as Go does with an M, is the better
answer and a larger change".  It is not that much larger.  The collector
parks on a
.CW Rendez
with a 20ms timeout, and a context that closes a quantum while
.CW gcstw
is set wakes it.
.PP
The handshake is the same publish-then-recheck that
.CW enterquantum()
already uses, in the other direction: the closer clears
.CW inxec ,
fences, then tests
.CW gcstw ;
.CW stoptheworld()
sets
.CW gcstw ,
fences, then reads
.CW inxec .
Neither order lets both miss.  The timeout is what keeps the wake an
optimisation rather than a requirement \(em a quantum closed on a path
that does not call
.CW safepoint()
costs 20ms, not the boot \(em and the
.CW HZ/4
give-up is unchanged.
.PP
.CW inxec
is cleared in seven places: five in
.CW dis.c ,
which call
.CW safepoint()
directly, and two in
.CW libinterp/xec.c
\(em
.CW isave() ,
which is entersyscall, and
.CW xec() 's
exit \(em which reach it through a hook, because
.CW gcstw
lives in the kernel and
.CW libinterp
is shared with emu.  The hook is nil in emu, which has no
stop-the-world.  None of the seven holds
.CW isched.l
or any other spin lock, which
.CW wakeup()
requires.
.NH 2
The longjmp this one could not hoist
.PP
.CW collect()
holds
.CW gcsema
across
.CW stoptheworld() ,
and
.CW tsleep()
raises the note that interrupts a sleep \(em its own body is a
.CW waserror() /\c
.CW nexterror()
pair for exactly that.  So this change hands
.CW collect()
a way to leave by longjmp that it did not have when it spun, and without
a handler that leaves
.CW gcsema
held forever and the world stopped: every future collection deadlocked
and every other interpreter parked in
.CW enterquantum() .
.PP
Here the allocation cannot be hoisted out of the region, because the
sleep
.I is
the region.  So this is the other idiom, the ordinary one:
.CW "if(waserror()){ starttheworld(); qunlock(&gcsema); nexterror(); }"
before the sleep and
.CW poperror()
after it.  The two halves of the channel work and this one are the same
question answered both ways, which is the point:
.I remove
the longjmp where the thing that raises it can be moved out, and
.I handle
it where it cannot.
.PP
.CW rungc()
itself was checked for the same hazard and has none \(em
.CW libinterp/gc.c
has two
.CW error()
calls, one in a comment and one in
.CW ptradd() ,
which only
.CW keyring.c
calls.  The handler guards the sleep and nothing else, which is worth
saying rather than claiming a pre-existing bug it does not fix.
.NH 2
Two things the counters will not say
.PP
.CW stwwaits
changed units.  Before this change it counted
.CW sched()
spins; after it, it counts 20ms naps.  "stw waits 56500" on the old
kernel and "stw waits 12" on the new one are not the same quantity, and
comparing them as though they were would make a change that removes
waiting look like a change that removes work.  Throughput is the metric;
the counters are colour on the new side only.
.PP
The watermark starts at zero, so the first successful
.CW stoptheworld()
prints a
.CW stw:
line even when the collector never had to wait at all.  The presence of
the line is not evidence that anything parked \(em the parks count inside
it is.
.PP
One thing this does not touch: a context waiting in
.CW enterquantum()
for
.CW gcstw
to clear still spins on
.CW sched() .
A Plan 9
.CW Rendez
holds exactly one sleeper, so parking those needs one per context, and
that is a second change with its own measurement.  What is measured here
is the collector's own wait, which is what
.CW stwwaits
counts.
.NH 2
The lock, isolated
.PP
One kernel against itself at
.CW parallelvm=1
.CW "-smp 4" ,
sixteen boots each, interleaved,
.CW *chanlock=1
against
.CW *chanlock=0 :
.TS
center;
l r r r r r.
	chantest lines	panics	tripwires	stall dumps	contention
lock on	0 of 384	0	0	5	3
lock off	0 of 384	0	0	6	0
.TE
.PP
No difference, and the reason the table is worth printing anyway is that
it says so in a form that cannot be mistaken for a result: the metric is
on the floor on both sides.  This configuration makes no progress
whether the lock is there or not, so the lock is not what stops it \(em
which is the question the batch was run to answer, and it is answered in
the negative.  It says nothing about whether the lock is
.I right ,
only that it is not what is costing this configuration its throughput.
.PP
The contention column is the control behaving as it should: with the
lock off nothing ever reads the lock word, so zero there is the absence
of the instrument rather than the absence of the race.
.PP
The arm where the metric has room is
.CW "-smp 2" ,
where all three chantests complete inside the timeout.  That one is what
decides whether the lock costs anything when the system is actually
running.
.NH 2
The give-up bound was reading the wrong clock
.PP
The bound on
.CW stoptheworld() 's
wait was changed once already, from a count of tries to elapsed time,
and this document records why: a count measures how fast the loop goes
round, which is whatever the compiler and the console happen to make it.
What it did not record is that the elapsed time was being read from the
wrong clock.
.PP
.CW m
is the per-CPU Mach, and each CPU's clock handler increments its own
.CW ticks
\(em
.CW portclock.c
line 146 is
.CW "m->ticks++" ,
and nothing shares it.  The wait loop reschedules every turn, so the
process can read the clock on a different CPU from the one it set
.CW start
on, and then
.CW "m->ticks - start"
subtracts two unrelated counters.  One tick behind comes out as
.CW 0xffffffff ,
which is comfortably greater than
.CW HZ/4 ,
and the collection is abandoned on the first migration instead of after
a quarter of a second.
.PP
The give-up print is what caught it, and only because it printed the
elapsed value rather than just the fact of giving up:
.TS
center;
l r.
elapsed printed	times
4294967295	10
26	8
4294967294	3
.TE
.PP
Twenty-one give-ups across the
.CW parallelvm=1
batches; thirteen of them are this bug and eight are honest.  Nearly two
thirds of the collections the collector abandoned, it abandoned for no
reason \(em and an abandoned collection is heap that stays allocated
until the next one, at a configuration whose whole problem is that it is
slow.
.PP
.CW MACHP(0)->ticks
is the system-wide count, which is what
.CW proc.c
uses where it needs one.
.PP
Worth saying plainly: this was visible in every batch run this session
and went unread until a give-up line was looked at directly rather than
counted.  A diagnostic that prints a number nobody reads is not much
better than one that does not print it.
.NH 2
One boot is an existence check, not a result
.PP
Before spending half an hour of machine on the clock fix, one boot each
at
.CW parallelvm=1
.CW "-smp 2" :
.TS
center;
l l l l.
	give-ups	elapsed printed	chantest
before	0	\(em	18 lines, 1 of 3
after	1	26 ticks	23 lines, 3 of 3
.TE
.PP
The column that means anything is the middle one.  It says the give-up
that did happen was an honest quarter second and not a migration \(em
which is the fix working, confirmed by the only evidence that can
confirm it, the value the print carries.  The chantest column is one
boot against one boot and is recorded here so that nobody, including
whoever writes the next section, mistakes it for a measurement.
.PP
A prediction worth writing down before the batch rather than after it,
so that it can be wrong: with the clock fixed the collector will now
actually wait its full quarter second rather than bailing on the first
migration, and a context wanting to enter a quantum still spins in
.CW enterquantum()
for that whole time.  If the clock fix does not help, or hurts, that is
the first place to look, and it is an argument for parking the mutator
side too rather than against fixing the clock.
.NH 2
What parking measured
.PP
Sixteen boots each, interleaved with the order alternating, at
.CW parallelvm=1
.CW "-smp 2" :
.TS
center;
l r r r r r r.
	shell iters	chantest lines	completed	FAIL	panics	parks
spins	11	373 of 384	40 of 48	0	2	0
parks	442	358 of 384	42 of 48	0	1	65395
.TE
.PP
Shell loop iterations went from 11 to 442 across the same sixteen boots.
That is the whole result and it is not subtle: the collector's spin was
the cost.  Per boot it is 0.7 against 27.6, against about 73 at
.CW parallelvm=0
\(em so this configuration went from running at roughly one percent of
the single-interpreter kernel to roughly forty percent of it.
.PP
The chantest columns barely move, and that is consistent rather than
puzzling: the three chantest instances run first, finish early, and are
channel-bound rather than collector-bound.  The shell loop is what comes
after them, spawns modules, allocates, and therefore collects.  It is
the workload the collector's wait was strangling, and it is the one that
moved.
.PP
.CW parks
is a lower bound, being the last watermark each boot printed rather than
the true count.  It is there to confirm the path was taken rather than
to be compared with anything.
.PP
The print that
.CW b17
carries and
.CW b15
does not was flagged beforehand as the first confound to rule out if the
result came back ambiguous.  It did not: a print can only slow a kernel
down, so it cannot manufacture a forty-fold gain, and the mechanism \(em
not calling
.CW sched()
tens of thousands of times \(em accounts for the direction and the size
directly.
.NH 2
A column that was measuring the opposite of its name
.PP
The batch scripts carried a
.CW stalldump
column, counting boots whose log contained the scheduler dump, read as
"boots that stalled".  It is not that.
.CW portclock.c
calls
.CW disdump()
unconditionally at
.CW "m->ticks == 40*HZ" ,
which is forty seconds of uptime and nothing else.  The column counts
boots that
.I survived
to forty seconds.
.PP
So the parking kernel's 14 against the spinning kernel's 9 is the good
direction, not the bad one, and reading it the other way would have been
reading a health check as a fault count.  Renamed to
.CW alive40s
in every script that had it.
.PP
This is the third metric this session that had to be checked against the
thing it was standing in for \(em after "reached the shell" at
.CW parallelvm=1
and the iteration counts across kernels with different workloads.  The
pattern is consistent enough to state as a rule: before a column is put
in a table, read the code that produces the line it counts.
.NH 2
What is left failing at parallelvm=1
.PP
The lock A/B answered a second question it was not run to answer.  Both
arms panicked at the same rate with the same signature \(em two boots of
sixteen with the lock on, three with it off \(em and in every case a
.CW "panic: page fault"
preceded by the
.CW "registers for"
report.  Resolved against the kernel that produced it, the faulting PC
is
.CW rootset+0x87 ,
with
.CW rungc ,
.CW collect
and
.CW vmachine
above it: the collector faulting in its own root-set walk.
.PP
Two things follow.  The channel lock neither causes it nor fixes it,
which is what a fault appearing at the same rate on both arms means.
And chantest reported
.I no
wrong values on either arm \(em 0 FAIL in 32 boots \(em so the channel
semantics are right whether or not the lock is there; what the lock
prevents is the corruption that does not announce itself as a wrong
value.
.PP
This is the same family as the rootset fault this document spends a
chapter on, whose cause was found and fixed.  The residue is the one
recorded there as undiagnosed: a stable mismatched SP/FP pair rather
than the torn one that
.CW handler()
produced.  It is now the largest remaining
.CW parallelvm=1
fault and it is next.
.NH 2
Retraction: the 40x, and the regression that was not one
.PP
Two claims in the sections above are wrong and are withdrawn here rather
than quietly edited, because how they went wrong is the useful part.
.PP
.B "The forty-fold parking gain is not supported."
The table records 11 shell iterations against 442 across sixteen boots
each and reads that as a ratio.  It is not one.
.CW /dis/init 's
loop is exactly 300 iterations, so the count a boot can produce is
essentially 0, a small partial, or 300 \(em bimodal, not continuous.
Broken out per boot:
.TS
center;
l r r r r.
	ran all 300	partial	never got there	total
spins	0	7	9	11
parks	1	1	14	442
.TE
.PP
The 442 is one boot that got through the loop and one that got part way.
The spinning kernel had
.I more
boots make some progress and none finish.  One boot of sixteen is not a
throughput measurement, and "40x" was a ratio of two numbers that a
single boot moves by a factor of thirty.
.PP
What the batch does support is narrower: no parking boot and no spinning
boot differed on correctness \(em 0 FAIL, chantest near saturation on
both at 373 and 358 lines of 384 \(em and one parking boot completed a
loop no spinning boot completed.  That is suggestive and it is not a
multiplier.
.PP
.B "The clock fix is not a regression."
That was announced from an interim read of a running batch, at six boots,
where the fixed-clock arm happened to show 0.  At seven and eight boots
the two arms are 300 and 300, with chantest slightly ahead on the fixed
side (182 lines and 20 completions against 140 and 14).  Same bimodal
metric, same trap, and this time acted on: the batch was stopped and a
change was written on the strength of it.
.PP
The change written on that strength \(em parking the mutator side of the
handshake \(em still removes a real spin and is kept, but its
justification is now "enterquantum() spins while a collection runs",
which is true from the code, and not "the clock fix regressed", which
was not measured.
.NH 2
The metric was never checked against what it stands for
.PP
This document has now caught four metrics measuring something other than
their name, and wrote a rule after the third: read the code that
produces the line before counting it.  The fourth was the rule's own
author not applying it to the column he had been quoting all session.
The check takes one command \(em what values can this count actually
take? \(em and it was never run on
.CW "sh: true"
until the numbers stopped making sense.
.PP
The fix for the measurement, not just for the record: the shell loop is
only continuous if it gets time to run, and chantest eats the window
first.  Throughput comparisons need a timeout long enough for the loop
to be the thing being measured, and the per-boot distribution has to be
printed rather than the total.
.NH 2
Re-checking the conclusions that were kept
.PP
A retraction is worth little if the same test is not then run on
everything else the document claims.  The two surviving comparisons were
re-read as per-boot distributions rather than totals.
.PP
The lock A/B at
.CW parallelvm=1
.CW "-smp 2" ,
chantest lines per boot, out of 24:
.QP
.CW "lock on:  24 23 23 18 24 19 16 24 24 21 21 24 0 24 23 24"
.br
.CW "lock off: 24 23 24 0 23 23 22 22 18 23 22 24 24 24 24 0"
.PP
Fifteen of sixteen boots on each side clear 16, the distributions sit on
top of each other, and no single boot carries the total.  "No difference
detected" is what this says, and it is not the artefact the parking
number was.
.PP
The
.CW parallelvm=0
comparison, shell iterations per boot over thirty boots each, ran 66 to
89 before the change and 60 to 81 after \(em both continuous, both far
from the 300 ceiling, so the bimodality that wrecked the
.CW parallelvm=1
numbers never applied here.  The distributions are tight and offset by
about seven percent, consistently rather than through outliers, which is
the three concurrent chantest runs the new kernel carries and the old one
does not.  That was the reading given at the time and it survives the
re-check.
.PP
So of the four numeric claims this document has made about the channel
and stop-the-world work, two stand on distributions that support them
and two were withdrawn.  The two that stand are both negative results.
.NH 2
Parking, measured on a metric that discriminates
.PP
Ten boots each, interleaved, at
.CW parallelvm=1
.CW "-smp 2" ,
with the timeout raised to 120 seconds so the shell loop would have room.
It did not help: seven of ten boots produced zero iterations on
.I both
sides, and the full/partial/none split was 1/2/7 on both.  Raising the
timeout does not make that metric continuous, because the three chantest
runs still consume the window first.  The fix for the metric was
insufficient and the shell loop still says nothing here.
.PP
The metric that does discriminate was already in the table.  chantest
lines per boot, out of 24 for the three concurrent runs:
.QP
.CW "before: 0 24 0 2 23 24 23 23 24 24"
.br
.CW "after: 24 24 24 24 24 24 20 24 24 21"
.PP
229 of 240 against 167 of 240, and the shape is the point rather than the
sum: every boot after the change clears 20, while three boots before it
failed to run the stress at all.  This is not one boot carrying a total.
.PP
It is also near its ceiling, so it says the stress now completes
reliably and cannot say how much faster anything is.  That is the honest
limit of it.
.NH 2
The panic count, which is the part that needs more boots
.PP
Three of ten boots after the change panicked; none of ten before it did.
Read alone that is alarming, so: the faulting PC is
.CW rootset+0x87 ,
the same offset, in the same function, as every one of the panics the
kernel before the change produced in earlier batches.  Not a new failure
mode \(em the residual root-set fault this document already names as the
largest remaining one.
.PP
Pooled across every batch it appears in, the kernel before the change
faults in 7 boots of 58, about twelve percent.  Three of ten is thirty.
At these sample sizes the two are not separable \(em Fisher puts it
around
.CW p=0.15
\(em and the kernel after the change completes half again as much
chantest per boot, so it runs more collections and has more exposure to a
fault that lives in the collector.  That is a reason the rate could rise
without anything being more broken, and it is not evidence that it did
not rise.  The question needs boots, not argument, and it is recorded
here as open.
.PP
One thing that is settled: no boot printed
.CW "double sleep" .
The one-Rendez-per-context design depends on
.CW claimctx()
handing each interpreter its own context, and nothing in these ten boots
violated it.
.NH 1
The residual root-set fault
.PP
The largest remaining
.CW parallelvm=1
failure was a
.CW "panic: page fault"
at
.CW rootset+0x87 ,
two or three boots in sixteen, present with the channel lock on and off
alike.  It is solved, and the thing that solved it was reading the
register dump instead of the stack trace.
.PP
Eight captures, two different kernels:
.TS
center;
l l l l.
	CX	DX	CR2
every one	ffffffffffffffe7	ffffffffffffffff	ffffffffffffffe7
.TE
.PP
The faulting address is the same value every time, and
.CW CR2
equals
.CW CX ,
so the dereference is through it.  A constant faulting address is not
corruption; it is arithmetic.  And
.CW "H is ((void*)(-1))"
while
.CW Heap
is two ints and two pointers, 24 bytes on amd64 \(em so
.CW D2H(H)
is
.CW -1-24 ,
which is
.CW -25 ,
which is
.CW 0xffffffffffffffe7 .
.CW DX
holding
.CW -1
is
.CW H
itself, still in a register from the comparison that was not made.
.PP
.CW rootset()
had:
.QP
.CW "ml = rr->M;"
.br
.CW "h = D2H(ml);"
.br
.CW "Setmark(h);"
.br
.CW "mp = ml->MP;"
.br
.CW "if(mp != H) {"
.PP
The
.CW MP
is guarded against
.CW H
three lines below.  The Modlink it came from is not.
.NH 2
Why a Prog on that list can have no module
.PP
.CW destroystack()
ends with
.CW "reg->M = H" ,
and both callers \(em
.CW progexit() 's
teardown and
.CW vmachine() 's
error handler \(em run it before
.CW delprog()
unlinks the Prog, so there is a window in which a Prog on
.CW isched.head
has no module.  Both wrap it in
.CW gclock() ,
which was enough when there was one interpreter.
.PP
It is not enough now, for two separate reasons.
.CW gclock()
only increments
.CW gchalt ,
which
.CW rungc()
tests when it starts \(em it cannot stop a collection already running on
another CPU.  And
.CW vmachine() 's
handler clears
.CW inxec
before it reaches the teardown, so
.CW stoptheworld()
counts that context as already stopped and never waits for it.  The
world is "stopped" while one context is dismantling a Prog.
.PP
This is the same shape as the fault this document spends a chapter on \(em
.CW handler()
rewriting
.CW p->reg
after
.CW waserror
cleared
.CW inxec
\(em one step further along the same teardown path.  The earlier fix
claimed the quantum around
.CW handler() ;
it did not extend to what runs after it.
.NH 2
The guard, and what it does not do
.PP
.CW rootset()
now skips a Prog whose
.CW rr->M
is
.CW H
or nil.  That loses nothing:
.CW destroystack()
nils
.CW reg->EX
before it frees a single extent and only sets
.CW "M = H"
at the end, so a Prog with no module has no stack roots either.  nil as
well as
.CW H
because
.CW addprog() 's
placeholder Prog is zeroed rather than filled with
.CW H ,
and
.CW D2H(nil)
would fault at
.CW -24
by the same arithmetic.
.PP
What this does not do is stop the collector walking a Prog that is being
dismantled.  It stops the crash that walk causes, which is the
measurable part; whether any other field read during that window can be
inconsistent is a separate question and is not answered here.  Claiming
the race is closed because the panic stopped would be the same mistake
as reading a metric without checking what it counts.
.NH 2
The window the guard does not close
.PP
Skipping a Prog whose
.CW M
is
.CW H
stops the crash that was measured.  It does not stop the race that
produced it, and the orders say so exactly.
.PP
.CW destroystack()
writes in this order:
.CW "ex = reg->EX" ,
.CW "reg->EX = nil" ,
then a
.CW free(sx)
per extent, then
.CW "reg->M = H"
.I last .
.CW rootset()
reads in this order:
.CW rr->M ,
then
.CW rr->SP ,
then
.CW rr->EX ,
then it walks.
.PP
So the guard catches a teardown that has already finished.  The
dangerous case is one that has just begun: the collector reads
.CW M
before it becomes
.CW H
and passes, reads
.CW EX
before the nil, and then walks Stkexts that
.CW free()
is handing back underneath it.  That is a use-after-free, and "bad frame
type", "frames do not tile" and a jump into the Dis heap through
.CW t->mark
are what it looks like from the far end \(em which is to say it is
probably the same root cause as several faults this document has already
chased.
.PP
Neither existing guard covers it.
.CW gclock()
sets
.CW gchalt ,
which
.CW rungc()
tests at entry and which cannot stop a collection already running on
another CPU.
.CW inxec
would, but
.CW vmachine() 's
handler clears it before reaching the teardown, so
.CW stoptheworld()
counts the context as stopped
.I while
it dismantles a Prog.
.NH 2
Excluding the teardown, and only the teardown
.PP
.CW entertear() /\c
.CW leavetear()
set a flag that
.CW othersrunning()
counts alongside
.CW inxec ,
with the same publish-then-recheck
.CW enterquantum()
uses so that neither ordering can miss.  A separate flag rather than
reusing
.CW inxec ,
so it composes with whatever claim the caller already holds.
.PP
It waits with
.CW sched()
rather than
.CW tsleep() ,
deliberately: one of the two sites is inside
.CW vmachine() 's
error handler, and a note interrupting a sleep there would longjmp out
of a path that is delicate enough already.  A Prog dying is rare and a
collection is short, so a spin in that one place is the cheaper risk \(em
the opposite call from the one made for the collector's own wait, and
for the opposite reason.
.PP
It covers
.CW destroystack()
and not
.CW delprog() .
.CW delprog()
releases and reacquires the interpreter, so making the collector wait for
it would make every concurrent collection give up \(em the give-up path
this document spent a chapter measuring.
.CW destroystack()
itself does not block.
.NH 2
Two checks the exclusion rests on
.PP
.CW entertear()
waits for
.CW "gcstw == 0"
and then makes
.CW othersrunning()
count this context.  That is only sufficient if every mark runs with
.CW gcstw
set, and only safe if it cannot nest.  Both were checked rather than
assumed.
.PP
.B "Every mark runs under stoptheworld."
In this kernel
.CW rungc()
has exactly one caller,
.CW collect() ,
and
.CW stoptheworld()
sets
.CW gcstw
before it.  There are three other calls in
.CW devbench.c ,
which call
.CW rungc()
directly with no stop at all \(em and
.CW devbench
is not in the pc64 configuration, so they do not apply here.  Recorded
because they are a live exception to the invariant the exclusion depends
on: enabling that device on a multicore kernel would break this without
touching any of the code that assumes it.
.PP
.B "It cannot nest."
The two sites are
.CW killprog()
and
.CW progexit() .
.CW delprog() ,
which runs immediately after each, reaches neither, and nothing on the
.CW destroystack()
\(->
.CW destroy()
\(->
.CW freechan()
\(->
.CW killcomm()
path reaches them either \(em
.CW killcomm()
posts notes, wakes progs and unmarks alts, and kills nothing.  Two
contexts tearing down at once is not nesting: the flag is per-context.
.NH 2
The stress test turned out to be the reproducer
.PP
.CW chantest 's
.I kill-while-blocked
arm kills three progs a round, each blocked in send, recv or alt.  A
killed prog goes through
.CW killprog() ,
which is one of the two
.CW destroystack()
sites this fault lives at \(em so the test written to stress the channel
region is also what drives Prog teardown hard enough for the collector to
meet one in progress.
.PP
That is why the fault shows up in boots where chantest runs and why it
was rare before: nothing else in a boot kills progs in a loop.  It was
not designed as a GC reproducer and works as one, which is an argument
for stress tests that kill things rather than only exercising the happy
path.
.PP
It also means the measured fault rates are rates
.I under this workload ,
not rates in general, and that raising the kill count would raise them.
Left alone deliberately: changing the workload now would make every
batch in this document incomparable with every other.
.NH 2
The guard fires with the exclusion on, and that is correct
.PP
Twenty boots each,
.CW parallelvm=1
.CW "-smp 2" :
.TS
center;
l r r r r.
	panics	guard fired	boots that gave up	chantest lines
without	0 of 20	\(em	3	436 of 480
with	0 of 20	3 of 20	13	445 of 480
.TE
.PP
Three things, and the second is a correction.
.PP
.B "The guard is doing work."
It fired in three of twenty boots, and the print says which case:
.CW "(M H)"
all three times, never nil.  Every one of those is a
.CW D2H(H)
that would have been a page fault, so this is three prevented faults in
twenty boots \(em fifteen percent, against the twelve percent the old
kernel faulted at across fifty-eight boots.  That is far better evidence
than a panic count, and it is why the control was worth adding: the
panic columns are zero on both sides and say nothing at all.
.PP
.B "The prediction attached to *tearlock was wrong."
It said that with the exclusion on the guard should never fire, so a
silent guard would prove the exclusion was what prevented the case.  The
guard fired anyway, and the reason is that the two cover different
windows, which the commit that introduced them should have separated:
.IP \(bu
.CW destroystack()
freeing extents while
.CW rootset()
walks them.  The exclusion covers this.
.IP \(bu
The Prog sitting on
.CW isched.head
with
.CW "M == H"
after
.CW destroystack()
returns and before
.CW delprog()
unlinks it.  The exclusion deliberately does
.I not
cover this \(em
.CW delprog()
blocks, and waiting for it would make every concurrent collection give
up.  Only the guard covers it, and it is unavoidable without holding the
collector across a blocking call.
.PP
So a firing guard is the expected steady state, not a sign the exclusion
failed.  The reasoning that produced the prediction conflated the two.
.PP
.B "The exclusion costs collections."
Boots that abandoned a collection went from 3 of 20 to 13 of 20, one
give-up each.
.CW intear
makes
.CW othersrunning()
non-zero for the length of a
.CW destroystack() ,
and a long stack takes long enough for the collector's quarter second to
run out.  chantest throughput did not move \(em 445 lines against 436 \(em
so nothing was measurably lost, but four times as many abandoned
collections is a real cost for a window whose benefit this batch did not
measure.  It is kept because the use-after-free it closes is read
directly off the orders in the two functions, and it is flagged here
because "reasoned from the code, cost measured, benefit not" is the
honest description and not "verified".
.NH 2
A rate that moved without the code moving
.PP
The kernel without the guard faulted in 3 of 10 boots in one batch and 0
of 20 in this one, same binary.  Pooled with the rest that is 7 of 78.
Either the earlier ten were unlucky or this twenty were, and with
.CW p
around 0.05 between them the honest statement is that the fault rate is
not stable enough at this sample size to compare batches run at different
times on a shared machine.  The guard's own count does not have that
problem, which is the argument for instrumenting the mechanism rather
than counting the symptom.
.NH 2
A cheaper shape for the same exclusion
.PP
If the window turns out to be real, the current exclusion is not the way
to close it.  It holds the collector out for the whole of a
.CW destroystack() ,
which is why abandoned collections quadrupled: a long stack outlasts the
quarter second the collector is willing to wait.
.PP
The exposure is narrower than that.
.CW destroystack()
nils
.CW reg->EX
as its
.I second
statement and only then frees anything, so a collector that starts after
that nil sees no extents at all and is never at risk.  The only collector
that can be hurt is one that already read
.CW EX
\(em and a collector that has read
.CW EX
is inside
.CW rootset() ,
which is inside
.CW rungc() ,
which runs only with
.CW gcstw
set.
.PP
So the wait can be one-shot and go inside
.CW destroystack() ,
between the nil and the first
.CW free() :
.QP
.CW "ex = reg->EX;"
.br
.CW "reg->EX = nil;"
.br
.CW coherence();
.br
.CW "wait while gcstw != 0;	/* only for a collector already reading */"
.br
.CW "... free the extents ..."
.PP
A collector arriving afterwards sees
.CW "EX == nil" ;
one already running is waited for exactly once.  Neither needs
.CW othersrunning()
to count anything new, so no collection is ever abandoned on account of a
teardown, and the give-up cost goes away entirely.
.PP
The cost is a hook, because
.CW destroystack()
is in
.CW libinterp
and
.CW gcstw
is the kernel's \(em the same arrangement
.CW atsafepoint
and
.CW chandefer
already use, nil in emu.
.PP
Not built.  It is written down now because the batch that decides whether
the window is real is running, and if it is not real the right change is
to delete the exclusion rather than to make it cheaper.  Designing the
replacement before knowing which of those is true would be the same
mistake as the prediction two sections up.
