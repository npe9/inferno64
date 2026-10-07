.TL
Integrating the parallel VM and the parallel collector into the Pi 3B port
.AU
.PP
This is the plan for bringing
.CW multicore 's
parallel Dis VM and its stop-the-world collector onto
.CW raspi3b-port ,
where processes now run on all four processors but Dis still does not.  It
exists because the first scoping of this work, written into
.CW doc/raspi3b-completion-plan.ms ,
was wrong in two ways that would have cost a session each.
.NH 1
What the first scoping got wrong
.PP
.B "It is not primarily about locks."
The note said the work was the safepoint discipline, the collector change and
the group locking.  Those are real, but they sit on a foundation the note did
not mention:
.CW DISCTXREG .
On this branch there is one global
.CW "REG R"
in
.CW libinterp/xec.c ,
so the JIT's
.CW ctxreg()
bakes
.CW con((uvlong)&R) ,
a constant that is correct for ever because there is only ever one register
file.  On
.CW multicore ,
.CW R
is
.CW curP->reg
with
.CW curP
in a machine register, and
.CW ctxreg()
emits a move out of that register instead;
.CW REG
is the first member of
.CW Pctx
so
.CW &R
is
.CW curP
with no arithmetic.  Per-context register files are the parallel VM.  The locks
are how it is kept correct afterwards.
.PP
This branch's
.CW comp-aarch64.c
says so already, in the comment above
.CW ctxreg() ,
including the failure mode: copying the multicore generator onto a kernel
without
.CW DISCTXREG
gives code that loads whatever the context register happens to hold, which is
nothing, and faults on first entry
.I "looking exactly like a cache-flush bug" .
That sentence is the reason this document exists before any code.
.PP
.B "And the groundwork is not absent."
The completion plan says "this branch has none of that groundwork", which is
false and is corrected there.  What is present, deliberately:
.CW jitrefsatomic
and
.CW jitpresent
in
.CW comp-aarch64.c ,
with
.CW Heap.ref
updated through LDXRW/STXRW retry loops at all four sites and
.I kept
rather than stripped, precisely so the generator does not drift from
multicore's;
.CW ctxreg()
factored out as a function for the same reason; and
.CW gclock
and
.CW gchalt
already in
.CW dis.c ,
.CW heap.c
and
.CW gc.c .
Absent:
.CW vmlock ,
.CW gcdepth ,
.CW inxec ,
.CW stoptheworld ,
.CW gcstw ,
.CW enterquantum .
.NH 1
The shape of the divergence, in numbers
.PP
Common ancestor
.CW df62c4dc1 ,
510 commits on
.CW multicore
since it and 777 here.  Per file, added/deleted lines since that ancestor:
.P1
file                       here    multicore
port/dis.c                254/0     3143/238
libinterp/gc.c             17/0       691/11
libinterp/heap.c           21/0       388/19
libinterp/xec.c            36/1       441/61
include/interp.h            1/0        291/4
libinterp/alt.c             0/0       104/32
port/alloc.c                0/0      241/138
port/devprog.c              0/0       123/52
port/exception.c            0/0         59/4
port/allocb.c               0/0        78/10
port/proc.c               282/4        166/7
port/taslock.c             94/1         63/0
libinterp/comp-aarch64.c 3134/17     2949/17
.P2
That table decides the method.  Where this branch's delta is zero there is
nothing to merge: take multicore's file.  Where it is small and purely
additive, take multicore's file and re-apply the named hunks.  Only three files
need judgement, and one of them is hard.
.NH 1
Method, and why not a branch merge
.PP
.B "Not git merge multicore."
510 commits would drag in that branch's pc64, virtarm64, NVMe and NIC work and
put the conflicts inside a stop-the-world collector.  The asymmetry in the table
says the merge that is actually wanted is the other direction, per file.
.PP
.B "Phase 1, the free files."
.CW alt.c ,
.CW alloc.c ,
.CW devprog.c ,
.CW exception.c
and
.CW allocb.c
have a zero delta here.  Take multicore's versions whole.  This is mechanical
and has no judgement in it, but it is
.I not
a no-op: multicore changed those files for reasons beyond the parallel VM, so
the phase is gated like any other.
.PP
.B "Phase 2, the per-context register file."
.CW interp.h 's
.CW Pctx ,
.CW R
as
.CW curP->reg ,
the context register, and
.CW ctxreg() .
This is the foundation and the largest correctness risk, because it changes how
every generated instruction reaches the register file.  It lands with the
context register in use but still exactly one executor, so the only thing being
tested is that indirect addressing of the register file is correct.
.PP
.B "Phase 3, vmlock and parallelvm=0."
Note what this is not.  The ancestor's
.CW dis.c
had no
.CW vmlock
at all \(em multicore introduced
.CW "static QLock vmlock"
inside
.CW acquire() /
.CW release() ,
and this branch still serialises through the
.CW isched
idle/creating dance instead.  So "parallelvm=0 is the old behaviour, and
therefore inert" is true on
.CW multicore
and
.B false
here: at 0 this branch would be running multicore's serialisation, not its own.
That is a behaviour change to be proved, not assumed, and it is the reason this
phase is separate from phase 4.
.PP
.B "Phase 4, safepoints and the stopped world."
.CW inxec ,
.CW enterquantum() ,
.CW stoptheworld() ,
.CW gcstw ,
.CW gcdepth ,
and the collector changes in
.CW gc.c
and
.CW heap.c .
A context is at a safepoint when no quantum is open on it, which is
.CW "curP->inxec == 0" :
.CW isave()
has written the registers back so
.CW p->reg
can be trusted.  A context blocked in a system call is already at one.
.PP
.B "Phase 5, the flip, and only then."
.CW parallelvm=1 ,
measured.  Never combined with phase 4's install: one install has already
failed in this tree because two variables moved at once.
.NH 1
The hard file is not hard
.PP
.CW comp-aarch64.c
looked like the worst of it: both branches rewrote the same generator from the
same ancestor, 3134 lines added here and 2949 there, and it is the file this
port depends on most, because this board ships
.CW cflag=1
and
.CW libinterp.a
contains
.CW comp-aarch64.7 ,
so this generator is what runs on the Pi.
.PP
Diffed rather than assumed, the two files are
.B "nine hunks and 330 lines"
apart.  Somebody kept them in sync on purpose, which is what the comment above
.CW ctxreg()
was for.  The whole functional delta is four things.
.PP
multicore has, and this branch needs:
.CW "RCTX = 25"
in the register enum, and
.CW ctxreg()
emitting
.CW "MOV_REG(rd, RCTX)"
in place of
.CW "con((uvlong)&R, rd)" .
X25 is free here \(em it appears in this file only inside comments \(em and the
seven call sites are already annotated
.CW "RREG = &R, out of the context register" ,
so a previous session prepared this file for this exact change.
.PP
This branch has, and must keep:
.CW jitskip
with
.CW skipmod() ,
the per-module bisecting tool that earned itself on the Pi by isolating
.CW Etherusb ;
and
.CW icharge(n) ,
which charges a backward branch the real length of its loop, clamped to
[1,4095], where multicore charges 1.  That second one is this port's quantum
fix and losing it in a merge would be silent.
.NH 1
The risk this board takes on alone
.PP
multicore's native boards ship
.CW "cflag = 0" :
.CW virtarm64
and
.CW pc64
both.  This board ships
.CW "cflag = 1" .
So although
.CW disinit()
on that branch deliberately
.I permits
the combination \(em it disables the JIT only when
.CW "cflag != 0 && parallelvm != 0 && jitrefsatomic == 0" ,
and this generator sets
.CW jitrefsatomic
to 1 \(em nothing has ever actually run the JIT and the parallel VM together on
hardware.  The Pi would be the first.
.PP
.B "Overstated, and corrected from that branch's own documents."
All four cells of
.CW parallelvm
crossed with
.CW cflag
reach a shell on
.CW virtarm64 ,
one kernel per architecture with nothing relinked between cells \(em the boot
line overrides
.CW *cflag ,
which is why the configured 0 did not mean untested.  Their ship plan calls
.CW "parallelvm=1 cflag=1"
"legitimate rather than tolerated", because
.CW comp-aarch64.c
sets
.CW jitrefsatomic=1
and
.CW disinit()
has nothing to refuse.  And the reason it is only one instruction is stated and
measured there:
.CW REG
is the first member of
.CW Pctx ,
so
.CW &R
is
.CW curP
with no arithmetic \(em
.CW "long p(void){return (long)&R;}"
through
.CW "7c -DDISCTXREG -S"
is exactly
.CW "MOVW R25,R0" .
The generator allocates X0-X5 and X19-X22, so it cannot touch X25, X26 or X27.
.PP
So this board is not the first to run the combination; aarch64 is the
.I only
architecture where it is done, and this board is the first to
.I ship
it as the configured default.  Keeping
.CW jitskip
close to hand still costs nothing.
.NH 1
Gates
.PP
Every phase: build, boot on silicon from the card, and eleven cold boots with
the poller answering, which is the bar the
.CW smpsched
work set and the harness already automates.  Two rules learned the hard way in
this tree apply to all of them.
.PP
QEMU is not a gate for this work.  The parallel VM is about two executors
touching one reference count, and QEMU
.CW raspi3b
has no caches, so it cannot fail the way silicon fails.  It is still worth
running first to catch the crashes that are not about coherency at all.
.PP
And a JTAG boot is not a gate either, for the opposite reason:
.CW jtagrestart
holds cores 1 to 3, so a JTAG-loaded kernel is a one-processor machine and
cannot exercise any of this.  It remains the cheapest
.I control
arm, which is how the four-processor payoff was measured.
.NH 1
The foundation, scoped against the real tree
.PP
.B "multicore already did the aarch64 groundwork, including for this board."
.CW include/disreg.h
on that branch declares
.CW m ,
.CW up
and
.CW curP
together as R27, R26 and R25, and it exists because kencc allocates external
registers
.I "per file, in declaration order" :
a file declaring only
.CW curP
gets the first register, one declaring all three gets the third, so libinterp
and the kernel agree only if both declare the same set in the same order.  The
measured failure without it is in that header \(em libinterp's
.CW curP
was the kernel's
.CW m ,
and booting printed
.CW "cpu3318001: registers for kernel" .
.PP
Its comment says amd64 opts in, and that is stale:
.CW mkfiles/mkfile-Inferno-aarch64 ,
.CW mkfiles/mkfile-os-aarch64 ,
.CW os/inferno/virtarm64/mkfile ,
.CW os/inferno/pc64/mkfile
and
.CW os/inferno/raspi3b/mkfile
all carry
.CW -DDISCTXREG
there, and that branch's
.CW raspi3b/dat.h
includes the header with a comment saying every aarch64 board must declare the
same three.  So the plumbing does not have to be invented, only brought over.
.PP
.B "And this board is ready for a third register."
.CW vectrap
here already saves and restores R25:
.CW "UR_R25 200"
in
.CW l.s ,
stored at
.CW l.s:1372
and reloaded at
.CW l.s:1439 ,
like every other general register.  Nothing in the trap path needs changing.
.PP
.B "Four traps, from that branch having hit them."
Its documents name things that are not deducible from the design, and each cost
it a debugging session.
.PP
One: an aarch64 board
.I cannot
opt out.  The flag that turns this on for
.CW libinterp
lives in
.CW mkfiles/mkfile-Inferno-aarch64 ,
which is every aarch64 board's
.CW libinterp ,
so a board that does not declare the three registers fails to link with
.CW "dbgxec: undefined external: curP in dbgxec" .
.PP
Two: a kernel compiles its own files through the board mkfile but its libraries
through
.CW mkfiles/mkfile-os-aarch64 ,
which
.I also
needs the flag, or the link says
.CW "secmain: undefined: disctxinit" .
Theirs "had been linking because the archive was older than that path", which is
the kind of thing that passes once and fails on a clean build.
.PP
Three: the register has no initialiser.
.CW "Pctx* curP = &_pctx"
is compiled out under
.CW DISCTXREG
and nothing else writes it, so
.CW machinit()
must call
.CW disctxinit()
\(em on every processor, which on this board means the secondaries too, in
.CW cpustart() .
.PP
Four, and the subtlest:
.CW sched()
sets
.CW curP
beside
.CW up ,
and must
.I not
do it by pre-filling
.CW Proc.pctx ,
because
.CW vmachine()
reaches
.CW claimctx()
through
.CW "if(up->pctx == nil)" .
Filling the field gave them "one context per boot instead of seven, with the
register mechanism working and nothing using it" \(em a silent performance
floor, not a crash.
.PP
.B "And this board's trap path has to be looked at again, not waved through."
Earlier in this document R25 being saved and restored by
.CW vectrap
was called sufficient.  On amd64 that exact thing was a bug: their
.CW _intrestore
restored the context register from the trap frame on a kernel-mode return, and
had to stop, because
.CW trap()
can reach
.CW sched()
and a process resumed on another processor must keep the value the scheduler
left, not the one its frame carries.  Their aarch64 comment says saving and
restoring all three "like every other general register" is right, and 192 boots
at
.CW "-smp 2"
and 192 at
.CW "-smp 4"
back it.  Both cannot be taken on faith at once, so this is a thing to verify on
this board rather than to assume in either direction.
.PP
.B "A naming note."
Their knob for a scheduling secondary is
.CW secsched ;
this board's is
.CW smpsched .
Same thing.  And with a
.I global
.CW curP
and a scheduling secondary they measured 10 panics in 10 boots, because "both
processors shared one Dis context pointer, which is the single thing the
per-executor design exists to prevent".  Phase 1a here keeps one context and
.CW isched
still serialises Dis, so one pointer is still one executor's \(em but that is
the sentence to re-read before phase 1b lands on a board that already ships
.CW smpsched=1 .
.PP
.B "The scope is three boards, not one."
.CW -DDISCTXREG
in
.CW mkfiles/mkfile-Inferno-aarch64
is what makes
.I libinterp
expect a register
.CW curP ,
and this branch has three aarch64 boards \(em
.CW raspi3b ,
.CW raspi4
and
.CW virtarm64 .
All three must declare the same three registers or their links have no
definition for libinterp's
.CW curP .
That is the ripple, and it is small: each board's two
.CW "extern register"
lines become one include.
.NH 2
So the foundation splits in two, and the order is multicore's
.PP
.B "Phase 1a: pure indirection, no register."
.CW Pctx
in
.CW interp.h ,
.CW curP
as an ordinary global,
.CW R
becoming
.CW curP->reg ,
and exactly one context.  multicore's own comment calls this "pure indirection
\(em there is exactly one Pctx, curP is constant, and this is the same program
it was".  The build stays green throughout and no
.CW -DDISCTXREG
is involved, so the JIT still bakes a constant
.CW &R
and is still correct, because there is still only one register file.
.PP
.B "Phase 1b: the register."
.CW disreg.h ,
.CW -DDISCTXREG
in the two mkfiles and the three boards,
.CW disctxinit() ,
and
.I "in the same change"
.CW "RCTX = 25"
and
.CW ctxreg()
in
.CW comp-aarch64.c .
Those last two cannot lag, because this board ships
.CW cflag=1 :
the moment
.CW R
is reached through a register, a generator that bakes the address is emitting
the wrong one.  On multicore they could lag, and did, because every native
board there has
.CW cflag=0 .
That is the one place this port cannot follow that branch's staging.
.NH 1
The destination is not parallelvm=1, and that is from the source branch's own numbers
.PP
"Integrate the parallel VM" reads as "end with
.CW parallelvm=1 ",
because that is that branch's default.  Its own documents say the switch is not
safe, and this section exists so the goal is not set by the default.
.PP
.B "What is measured against it."
On
.CW pc64 ,
eight boots an arm, same kernel, same recipe: three of eight bad at 1 and none
of eight at 0; a second run of the same comparison gave none of eight on both
arms, and both are recorded rather than one chosen, "the lesson is the sample
size, not a contradiction".  Pooled, three failures in sixteen at 1 and none in
sixteen at 0.  The three were
.CW "panic: lost pid"
and twice
.CW "vmachine: error with no current prog" ,
and two of those three "are one shape \(em an error raised with no current
.CW Prog ,
which is the register-file desync this plan's Phase E describes, seen from the
other end".  Separately, "bad frame", a frame whose type pointer is a heap
address, on 11 boots of 16 at 1.  And a
.CW pooloverlap
check that its own comment said had never fired now fires, though only on a
machine with memory above 4GiB.
.PP
.B "And what is unfixed by design, not by accident."
Phase 4, the lock per channel, is not landed:
.CW isend()
and
.CW irecv()
"walk and edit the channel's send and recv queues, and read and write the other
.CW Prog 's
.CW ptr ,
which points into that program's stack.  None of it is locked.  It did not need
to be: the VM lock made every Dis instruction atomic with respect to every
other, and that is the lock
.CW parallelvm=1
removes."  Their note on it ends "Still a hazard, still not this one."
.CW claimctx()
exhaustion is called "the next wall", with
.CW ctxcap=256
"a mitigation with no ceiling, not a bound".  And
.CW "incref: bad r 0x300000003"
is undiagnosed with two hypotheses explicitly disproved.
.PP
.B "So the destination here is the infrastructure, with the switch at 0."
Phases 1a, 1b and 2a are landed there and verified \(em 192 boots at
.CW "-smp 2"
and 192 at
.CW "-smp 4"
\(em and they are what "the work on parallelising the GC" actually rests on:
per-context register files,
.CW progreg() ,
the safepoint, and a stop-the-world collector that can be correct because
.CW inxec
means "this context's register file is live".  Bringing those over is a real
integration and leaves this board where it is today: booting.
.PP
Flipping the switch would import three failures in sixteen onto a board that
boots eleven in eleven, and would do it with the channel hazard still open.  So
.CW parallelvm
arrives defaulting to 0, the way
.CW bootwdog
and
.CW smpsched
did, and the thing that would justify 1 is not more boots of it here but Phase
4 landing there.  That is a statement about sequencing, not about the work being
wrong: the collector half is sound and the register-file half is proven, and it
is the channel queues that are not.
.NH 1
The one prerequisite that landed early, and its numbers here
.PP
.CW gchalt
was two things in one counter on this branch, and splitting it is a
prerequisite for the collector work rather than part of it, so it landed first.
It was both "do not collect now" \(em a property of the heap, raised by
.CW libprefab
while it builds a Prefab and read by the collector \(em and
.CW destroy() 's
nested recursion depth, which
.CW libinterp/heap.c
read at line 505 to stop before it runs out of C stack:
.CW "if(n > 0 || gchalt > 64) return" ,
and that
.CW return
does not free the object.
.PP
One processor makes that harmless, because the only thing nested inside a
destroy is another destroy.  Two make it fail in both directions: one
processor's recursion depth would suppress another's collector, and one
processor building a Prefab would make another believe it was 64 destroys deep
and quietly stop freeing.
.CW gclock()
now raises both,
.CW gcunlock()
gives the depth back first,
.CW libprefab
keeps raising
.CW gchalt
alone, and
.CW heap.c
reads
.CW gcdepth .
.PP
.B "And the numbers are this board's, not that branch's."
Nothing in this tree printed the collector's counters, so
.CW "echo sched >/dev/sysctl"
prints
.CW GC-COUNTS
now, with
.CW gcdepthmax
in it for exactly this question.  Two samples from one boot on the board, the
first where
.CW schedlat()
already writes that sysctl and the second after the whole boot has run \(em SD,
USB, draw, wifi, efs:
.P1
             runs  sweeps  epochs  halted  depthmax  inspects
early         913      88      44       0         1     42580
late      1108957   11799    2448       4        14  47112719
.P2
That is not multicore's result and should not be reported as it.  There the
depth ran to
.I exactly
65 against the guard of 64, three times per storm, while the suppression never
fired at all \(em "the worst arrangement a multiprocessor could inherit,
because the counter already sits on its boundary".  Here the depth reaches 14,
with fifty of headroom, and the suppression
.I does
fire, four times.  So the hazard that motivated the split upstream is not the
hazard this board has, and the split is a correct change that is currently
harmless here either way.
.PP
Which is still worth having done, for two reasons.  A guard at 64 that is read
through a counter another processor can raise is wrong whatever the current
margin is, and the margin is a property of the workload rather than of the code
\(em 14 is what this boot does, not a bound.  And
.CW GC-COUNTS
is now there: 1.1 million collector runs and 47 million heap inspections in one
boot were numbers nothing in this tree could report before.
.NH 1
What landed, and why the register is deferred
.PP
Four steps are on the board or on their way to it, in multicore's own order
except for one deliberate reordering.
.PP
.B "The rename."
.CW Prog.R
is
.CW Prog.reg ,
111 sites in 20 files, because an object-like macro expands after
.CW ->
too and
.CW p->R
would become
.CW p->(*curR) .
Their Phase 1a hit the same thing and renamed it the same way.
.PP
.B "Phase 1a."
.CW "static REG _R; REG* curR = &_R;"
and
.CW "#define R (*curR)" ,
so all ~1900
.CW R.field
references go through a variable.  The generator needed nothing:
.CW ctxreg() 's
.CW "con((uvlong)&R, rd)"
becomes
.CW curR 's
value, a constant while there is one register file, which is why this board
took it with
.CW cflag=1
untouched.
.PP
.B "Phase 2a."
.CW "struct Pctx { REG reg; }" ,
one instance,
.CW curP
pointing at it,
.CW curR
now
.CW &_pctx.reg .
Not moved: the context's run queue, which would mean taking
.CW runhd /
.CW runtl
out of both
.CW isched
structs, 39 sites here and 34 in emu's, and has nothing to do with the register
file.  Never to be moved:
.CW isched.head /
.CW tail .
.PP
.B "Phase 5a, the seam."
.CW Pctx
gains
.CW curprog ,
.CW xec.c
gains
.CW pctxs[] ,
.CW npctx
and
.CW progreg() ,
and
.CW gc.c 's
root walk asks
.CW progreg(root)
instead of taking
.CW &root->reg .
With one context the first test returns the pointer the old code took, so it is
behaviour-identical.  Both
.CW delprog() s
clear
.CW curprog
before freeing the Prog: the function only ever compares Prog pointers and never
follows one, so a dangling
.CW curprog
is not a fault in itself, but the allocator hands the address out again and a
new Prog there would be answered for with another program's register file.
.NH 2
Phase 1b is deferred, and that is a decision rather than a pause
.PP
Making
.CW curP
a machine register is the next step in multicore's order.  It is deferred here
for two reasons that only appeared on contact with this tree.
.PP
.B "It is not needed for the collector."
.CW progreg()
and the stopped world depend on
.CW Pctx ,
.CW curprog
and
.CW inxec ,
and none of them on how
.CW curP
is reached.  With
.CW parallelvm
at 0 \(em which is where this integration ends, for the reasons two sections up
\(em one executor runs Dis at a time and a global
.CW curP
is correct.  The register is what makes per-executor access cheap when there
really are two; it buys nothing before that.
.PP
.B "And it ripples into two boards that cannot be tested here."
.CW -DDISCTXREG
has to go into
.CW mkfiles/mkfile-Inferno-aarch64 ,
which is every aarch64 board's
.CW libinterp ,
so every aarch64 board must then declare the same three external registers in
the same order or its link has no definition for
.CW curP .
This branch has three:
.CW raspi3b ,
.CW raspi4
and
.CW virtarm64 .
And only
.CW raspi3b
declares
.I any
\(em the other two carry
.CW m
and
.CW up
as plain globals, so switching them is not an include but a change to how each
starts, with its
.CW l.s
setting registers before any C runs.
.CW virtarm64
can at least be booted under QEMU here;
.CW raspi4
has no hardware on this desk.
.PP
So the sequence changes: the collector work first, because it is testable on the
board that exists, and the register when there is a reason to pay for it.  The
one thing that must not drift in the meantime is
.CW comp-aarch64.c :
its
.CW ctxreg()
is still correct only because there is one register file, and the day
.CW DISCTXREG
lands it must change in the same commit, for the reason its own comment gives.
.NH 1
The collector half, landed and measured
.PP
Three more pieces are in, and between them they are what "parallelising the
collector" means \(em the mechanism by which a collection can be correct when
something else is running.
.PP
.B "The safepoint."
.CW Pctx.inxec
is "a quantum is open on this context", raised and lowered with
.CW curprog
at the four boundaries:
.CW xec() 's
entry and tail, and
.CW isave() /
.CW irestore() ,
which are where a blocking system call hands the registers back and takes them
again.
.CW rungc()
checks the invariant that no context has one open, because
.CW rootset()
reads live registers through
.CW progreg()
and a collection taken with a quantum open walks registers the mutator is still
writing.
.PP
.B "And the check earned itself twice, immediately."
A QEMU boot printed
.CW "rungc: context 0 has a quantum open (prog 0x0)" ,
and the nil program beside a set flag is what named the paths: something was
clearing one and not the other.  First, an exception leaves a quantum by
.CW longjmp
and reaches neither
.CW xec() 's
tail nor
.CW isave() ,
so
.CW inxec
stayed set for the rest of the boot and the guard would have read "open" for
ever and meant nothing.  Second, a program that exits from inside its own
quantum reaches
.CW delprog()
through
.CW progexit() ,
which cleared
.CW curprog
while
.CW xec()
never reached the tail.  Both closed; the guard fires zero times across a full
boot on silicon, with the collector running 1238464 times and inspecting 52
million objects.
.PP
.B "The stopped world."
Both collector call sites bracket
.CW rungc()
with
.CW stoptheworld() /
.CW starttheworld() .
What it waits for is that no
.I other
context has a quantum open, and that is all: a context outside
.CW xec()
can mutate the heap, which the write barrier handles by design, and can queue a
program, which cannot cost a root because roots come from
.CW isched.head .
Bounded by wall-clock time rather than by a count of tries, for the reason
multicore measured \(em the same two thousand tries either spanned long enough
or elapsed too quickly depending on whether a print sat in the loop \(em and
abandoning a collection is safe in a way waiting is not.  At one executor it is
satisfied the moment it is asked:
.CW "stw 1274"
against
.CW "runs 1274" ,
waited 0, gave up 0.  It is in so the precondition is enforced by code rather
than by the accident of there being one executor.
.PP
.B "The process-group lock."
The one piece that is a bug fix rather than groundwork, and the one whose
measurement is multicore's rather than this board's: 18 and 17 detections of
Progs written into freed memory on two guests of three without it, 0 on three of
three with it, at the same throughput.  It cannot happen here while one executor
runs Dis; it is in because the failure is a torn list and a
.CW g->tail
naming a freed Prog, which becomes the allocator's problem and then somebody
else's panic.
.NH 2
What remains, and why it is the last thing rather than the next
.PP
.CW parallelvm
itself.  Adding the switch is not the work; making its 1 position mean something
is, and that means replacing this branch's serialisation \(em
.CW isched 's
idle/creating dance in
.CW acquire() /
.CW release()
\(em with multicore's explicit
.CW vmlock ,
which at 0 is taken and at 1 is not.  Two sections up says why that is a
behaviour change to prove rather than assume: the ancestor had no
.CW vmlock
at all, so "parallelvm=0 is the old behaviour" is true there and false here.
.PP
A switch whose 1 position is unimplemented would be worse than no switch, so
there is none yet.  What is here is everything the collector needs in order to
be correct once there is one, each piece measured on the board, and a
.CW GC-COUNTS
line that reports whether the invariants hold.
.PP
.B "And the gate is passed."
.CW "GCBOOTS: 11 booted, 0 failed, of 11 cold boots of the collector build" ,
each proved by a per-run tag coming back through the poller rather than by a
ping \(em which once reported five clean boots of a loop that rebooted nothing.
Twelve cold boots in all counting
.CW kinstall 's
own verification of the same build.  Afterwards the board reports
.CW "nmach 4"
with context switches on every secondary, 1418758 collections, 61 million heap
inspections, and the safepoint invariant violated
.B zero
times.
.PP
Two things that reading would not have given, for the record.  Each cycle takes
about twenty minutes on this rig, so eleven is four hours and the loop has to be
left alone rather than watched.  And the script's own log lags its progress by
two runs, because
.CW sh
buffers a redirected stdout in blocks and these lines are short: twice during
this gate the log said 8 while
.CW board.out
already held run 10's reboot.  The board's own output is the truth; the
harness's log is a convenience.
.NH 1
An open, intermittent QEMU fault, recorded rather than attributed
.PP
While testing the run-queue move a QEMU boot ended in
.CW "panic: trap" ,
a data abort with
.CW "esr 0x9600004e"
at
.CW main+0x58 ,
.CW far 0x400000 ,
preceded by seven
.CW COMVECCODE
lines \(em this port's own
.CW comveccheck
reporting that words 8 and 9 of the JIT's
.CW comvec
trampoline differ from its snapshot, a baked constant reading
.CW 0x03a13e54
where the snapshot has zero.
.PP
.B "It is intermittent, and that is the whole finding."
The first instinct was that the run-queue move had caused it.  It had not: the
change was reverted, HEAD rebuilt, and HEAD panicked too.  The second instinct
was then that something in this session's eight commits had caused it, and that
does not survive either \(em the same image booted clean twice immediately
afterwards, and four QEMU boots of the same committed code earlier the same day
were clean with no
.CW COMVECCODE
at all.  One panic in about seven boots.
.PP
.B "And it does not appear on the board."
The same build passed eleven cold boots from the card with the poller answering
on every one, plus
.CW kinstall 's
own verification, and the safepoint invariant was violated zero times across
1.4 million collections.  So on the evidence this is QEMU-only, or rare enough
that twelve board boots did not catch it.
.PP
.B "And then the likely cause turned out to be the measurement."
Every attempt to get a rate leaked emulators: the loops backgrounded
.CW qemu.sh
and killed the wrong thing, so instances accumulated \(em thirteen processes
matching
.CW qemu
at one point.  The panic has been seen
.I only
during those periods.  With the host cleared and one emulator running alone,
boots are clean: no panic, no
.CW COMVECCODE ,
the safepoint invariant at 0.  That is now five solo boots clean against one
panic taken while an unknown number of emulators competed for the machine.
.PP
So this is most likely host contention perturbing a timing-sensitive boot, not a
kernel fault \(em which puts it in the same category as the other harness
mistakes in this file, and is why it is being corrected here rather than left as
a finding.  Stated carefully: the correlation is strong and the mechanism is
plausible, but "concurrent emulators cause it" is not proven either, and the
honest position is that there is no evidence of a kernel fault and no clean
measurement of one.
.PP
.B "What it is NOT safe to say."
That it is pre-existing, that this session introduced it, or \(em now \(em that
it is a kernel fault at all.  Establishing
either needs the pre-integration commit built and booted enough times to
compare rates, and a single panicking run on either arm proves nothing \(em
which is the same trap multicore's own pc64 numbers fell into and then recorded:
three of eight bad on one run, none of eight on a repeat of the same
comparison, "the lesson is the sample size, not a contradiction".  Two attempts
to measure a rate here died, and the cause was not mysterious once looked at:
they exited 144, killed by a later
.CW pkill
of mine that was meant for a stray emulator and matched the measuring loop's own
process tree.  A rate measurement has to be left entirely alone, including by
the person taking it.
.PP
.B "The first thing to look at, when it is looked at."
The
.CW COMVECCODE
lines, because they are not obviously a symptom of the trap and may be the
cause's neighbour.  Phase 1a changed what
.CW ctxreg()
materialises \(em
.CW con((uvlong)&R, rd)
is now
.CW curR 's
value rather than a link-time constant.  It is still a constant, and it is the
same constant, so the generated code should be identical; but
.CW comveccheck
comparing against a snapshot whose words are
.I zero
says the snapshot was taken before that constant was written, and that is worth
understanding before anything is concluded from it.
.NH 1
Where this closes, and the dependency that closes it
.PP
.B "parallelvm=1 needs Phase 1b, which the section above did not say."
"What remains" presents
.CW vmlock
and
.CW parallelvm
as the last step.  That is incomplete.  At
.CW parallelvm=1
two kernel processes are inside
.CW xec()
at once, and each reaches its register file through
.CW curP
\(em which on this branch is a single global pointing at one
.CW Pctx .
Two executors would therefore share one register file, which is precisely the
thing the per-context design exists to prevent and which multicore names in
.CW claimctx() 's
own diagnostic:
.CW "sharing (unsafe while parallelvm=1)" .
So the chain is
.CW parallelvm=1
depends on Phase 1b, and Phase 1b ripples into
.CW raspi4
and
.CW virtarm64 ,
neither of which declares an external register today and one of which has no
hardware on this desk.
.PP
.B "And parallelvm=1 is not the destination anyway."
Three failures in sixteen upstream against none at 0, "bad frame" on 11 boots of
16, an undiagnosed
.CW "incref: bad r" ,
and Phase 4's per-channel lock not landed, with
.CW isend()
and
.CW irecv()
still writing another
.CW Prog 's
.CW ptr
into its stack unlocked.
.PP
Put together: the switch needs a change that ripples to boards that cannot be
tested here, in order to reach a state its own branch measures as worse than
where this board already is.  So this integration is finished at the
infrastructure, which is what it set out to do.
.NH 2
What is in, and what a later session would need
.PP
In, each built, QEMU-booted and \(em except the last two, which the rig blocked
\(em cold-booted from the card and gated at eleven boots:
.CW Prog.reg ;
.CW R
through a pointer;
.CW Pctx
with the register file, the current program, the safepoint flag and the run
queue;
.CW progreg() ;
.CW gcdepth
split from
.CW gchalt ;
.CW stoptheworld() ;
the process-group lock; the multi-context unlink; and
.CW GC-COUNTS
to report all of it.
.PP
Not in, and each for a reason rather than for lack of time:
.CW parallelvm
and
.CW vmlock ,
per the chain above; Phase 1b, per the same; Phase 4's channel lock, which is
upstream's open hazard and not this port's to close first;
.CW killprog() 's
queue-head test, which asks a different question than
.CW delrunq()
does;
.CW propex() 's
unlocked walk, which needs a snapshot taken on an exception path; and
.CW claimctx()
with a context pool, which only has a purpose once contexts outnumber one.
