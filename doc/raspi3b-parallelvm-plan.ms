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
That is the single largest risk in this plan and it is not reducible by reading:
the JIT emits reference-count updates inline, and whether its LDXRW/STXRW loops
are right under two executors is a question only two executors can answer.  It
argues for measuring phase 5 with
.CW cflag=0
first, to separate "the parallel VM works" from "the parallel VM works with this
generator", and for keeping
.CW jitskip
close to hand.
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
