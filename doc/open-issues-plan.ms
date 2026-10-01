.TL
What is still open, and how each piece gets closed
.AU
.LP
This is the work left after the narrowing-cast hunt of 1 October 2026.  It
spans three areas that have nothing to do with each other except that one bug
joined them: a compiler defect that looked like a filesystem bug for three
sessions.  The history is in
.CW doc/raspi3b-completion-plan.ms ;
this file is only what remains, in the order it should be done.
.PP
Each item says what is
.I established
and what is merely
.I suspected ,
because this tree has withdrawn five claims in two days and the difference is
the only thing that stops that happening again.  An item with no verification
step is not ready to be worked on.
.NH 1
Order, and why
.LP
.P1
1  C1  the rig's ELF hazard      DONE a1e2e12a0
2  A4  do the 32-bit back-ends narrow?    DONE, answered below
3  A3  audit what the 7c fix changed      DONE, and it found A5
4  B2  one namehash, not two              cheap, prevents a bad class
5  A1  fix 6c                             blocked on A2
6  B1  efs's quadratic allocation         the real remaining bug
7  D1  w4/w8, D2 close the bind section   housekeeping
.P2
.CW C1
goes first because an instrument that lies costs more than the bug it hides:
three false "did not come up" reports nearly buried the evidence that the
.CW big
literal bug predated
.CW Fs.reserve .
.CW A3
comes before
.CW A1
because it is about damage this session may already have done, and that
outranks extending the fix to another architecture.
.NH 1
A.  The kencc narrowing-cast class
.NH 2
A1.  6c drops the same narrowing; the cause is NOT yet located
.LP
.B Established.
.CW 6c
compiles
.CW "(LONG)hi << 32 | (LONG)(u32)lo"
to
.P1
MOVQ	BP,AX
SALQ	$32,AX
MOVQ	lo+8(FP),CX
ORQ	CX,AX
.P2
with no truncation: the same defect
.CW 7c
had, by inspection of the generated code.  It affects
.CW pc64
and any amd64 kernel, exactly as it affected aarch64.
.PP
.B "Not established: where it is."
A first draft of this plan said the cause was found, in a
.CW /* ... */
block spanning
.CW utils/6c/txt.c
759 to 815 that contains the narrowing pairs including
.CW CASE(TVLONG,TUINT) .
That was wrong, and wrong in the way this tree keeps paying for: a cause
inferred from reading code and not tested.  The comment opens immediately after
.CW default: ,
and the live body of that
.CW default
is
.P1
	switch(CASE(ft,tt)) {
	default:
/*
 * integer to integer
 ********
		a = AGOK;	break;
	... fifty-six lines of case labels ...
 *****/
		a = AMOVL;
		break;
.P2
so an unhandled pair gets
.CW AMOVL ,
which on amd64 moves 32 bits and zero-extends \(em the correct truncation.
Nothing about that block prevents it.  And the
.CW samaddr
guard does not drop it either:
.CW "a == AMOVL && ewidth[ft] == ewidth[tt]"
is false when the widths differ, which is the narrowing case.
.PP
So
.CW gmove
is never reached for this conversion, and the cast is being elided earlier \(em
which is what happened in
.CW 7c
too, by a route the tree dumps could not show.  The structural oddities above
are worth noting when the time comes (a
.CW default
that silently picks an opcode, fifty-six commented-out cases, and the guard's
own
.CW "/* TO DO: check AMOVL */" ),
but they are context, not the diagnosis.
.PP
.B "How to locate it, the method that worked."
Not by reading.
.CW "6c -t"
dumps the tree after each front-end phase; if both casts survive to
.CW "x complex"
the defect is in the back-end.  Then instrument: a print at the top of
.CW cgen 's
.CW OCAST
reporting
.CW l->type ,
.CW n->type
and
.CW nn->type
with their widths, a print at the
.CW nocast
elision, and a print in
.CW gmove
reporting
.CW ft ,
.CW tt ,
the chosen opcode and
.CW samaddr .
That sequence took
.CW 7c
from symptom to one-line cause in three builds, and
.CW 6c
is the same shape of back-end.
.PP
.B Verification.
The same sequence that verified
.CW 7c ,
and nothing less: the probe emits a truncation for
.CW (uint) ,
.CW (ulong) ,
.CW (int) ,
.CW (ushort)
and
.CW (uchar)
of a 64-bit value; a full rebuild of the amd64 kernel from touched sources;
and that kernel boots and runs Dis.  The last step is blocked \(em see A2 \(em
and
.B "the fix must not be committed as verified until it is unblocked" ,
because a code-generator change that has never run is not a fix.
.NH 2
A2.  pc64 does not link, which is what blocks A1
.LP
.B Established.
.P1
consdebugchar: undefined: archreboot in consdebugchar
.P2
.CW libinterp
builds clean for amd64; the missing symbol is in the port.  The tree has
untracked
.CW os/inferno/pc64/pc64dev.c ,
.CW ipc64dev
and
.CW ipc64.acid ,
so this is work in progress belonging to someone else, and nothing here should
edit it.
.PP
.B "Three ways out, in preference order."
Ask whoever owns that work to land or revert it.  Failing that, verify A1
against a different amd64 target that does link, if one exists \(em this is
worth five minutes with
.CW mk
before assuming it does not.  Failing that, and only to unblock verification,
build a kernel with a local
.CW archreboot
stub that panics if called, boot it under QEMU, and
.I do not commit the stub .
The third way proves the code generator, which is the point, and leaves the
port's own breakage to its owner.
.NH 2
A3.  DONE.  The 7c fix changed 100 files; nine sites need a source repair
.LP
.B Method.
Two compilers were built from
.CW dcca478dd
and its parent and confirmed to differ on the probe, then every
.CW .c
file in
.CW libinterp ,
.CW os/port ,
.CW os/ip ,
.CW os/inferno/raspi3b
and the eight libraries the kernel links was compiled by both with
.CW -S
and the same flags, and the output diffed.  389 files compiled, none skipped,
.B "100 changed" .
.PP
.B "What the raw diff is not."
12551 diff lines, whose histogram is dominated by
.CW B ,
.CW BCASE
and
.CW BEQ
\(em branch targets and switch tables renumbering because inserting one
instruction shifts everything after it.  Counting diff lines would have
reported ten thousand semantic changes.  Counting narrowing instructions per
file instead, which is immune to renumbering, gives
.B "645 added" ,
and 468 of those are in
.CW comp-386.c ,
.CW comp-amd64.c ,
.CW comp-arm.c ,
.CW comp-mips.c ,
.CW comp-power.c ,
.CW comp-sparc.c
and
.CW comp-spim.c
\(em files this kernel never links, since
.CW libinterp/mkfile
takes only
.CW comp-$OBJTYPE.c
and the archive holds
.CW comp-aarch64.7
alone.
.PP
.B "And os/port and os/ip did not change at all,"
which is worth saying plainly: the portable kernel is untouched.  The 100 are
.CW libinterp
32,
.CW libkern
23,
.CW libdraw
8,
.CW libtk
8,
.CW libmemdraw
5,
.CW libmath
3,
.CW libkeyring
3,
.CW libsec
1, and
.CW os/inferno/raspi3b
17.
.PP
.B "Most of it is a cast finally being obeyed."
.CW convS2M
and
.CW convD2M
gained 25 and 17: they write fixed-width Styx wire fields, where truncating is
the definition of the job.
.CW xec.c 's
.CW cvtwb
is "convert word to byte".
.CW math.c 's
are
.CW Math_bits32real ,
.CW Math_FPcontrol
and
.CW Math_FPstatus ,
all of which narrow to 32 bits on purpose.
.CW draw.c 's
are
.CW Display_rgb ,
.CW Display_colormix
and
.CW Draw_setalpha ,
packing colour channels.  And the JIT's
.CW con()
masks each field with
.CW "& 0xFFFF"
before passing it to
.CW MOVZ ,
whose body stores into a 32-bit
.CW *code++ ,
so its four new truncations narrow a value that was about to be stored as 32
bits regardless.
.PP
.B "The scan that matters, and the two ways it was wrong first."
The question is whether any narrowed value is then used as an address.  A first
scan looked only at added lines for the dereference and found one hit, in
.CW math.c ,
which was a false positive:
.CW bits32<>+0(SB)
is a destination symbol, not a register base.  A second scan looked at the
following lines in the whole file and found 104 \(em almost all of the form
.P1
MUL	R4,R0
ADD	$32,R0
MOVW	R0,R0		<- narrows the SIZE argument
BL	,nheap+0(SB)
MOV	R0,dh-16(SP)	<- R0 is now the RETURNED POINTER
MOV	R2,8(R0)
.P2
where the window crossed a call and paired a truncated argument with an
unrelated returned pointer.  With a branch or call ending the window \(em which
is the correct dataflow boundary for an analysis this crude \(em 859 added
register-to-register narrowings in the 93 linked files yield
.B "nine suspects" ,
540 windows having been closed by a branch.
.PP
.B "The nine, and what they are."
.P1
comp-aarch64.c  punt, commframe, commcall, comp, compile   7
xec.c           slicela                                    1
libtk/textw.c   tktdoubleclick                             2
.P2
Each is a
.CW "MOVW Rn,Rn"
\(em which did not occur once in the old output of those files \(em followed by
a dereference of
.CW Rn .
The JIT's come from one idiom:
.P1
long _off = (long)((code) - (ptr));
off = ((long)(IA(patch, dispc)) - (long)(code + codeoff)) >> 2;
.P2
a pointer cast through
.CW long ,
and
.CW SZ_LONG
is
.B 4
in kencc.  Before the fix that cast was dropped and the arithmetic happened in
64 bits, accidentally correct.  Now it truncates.
.PP
.B "Why nothing breaks, and why that is not a defence of the code."
These are
.I differences
between addresses that are close together, so truncating both and subtracting
preserves the result inside any 4GB region;
.CW MOVW
sign-extends, and every address on these boards is far below 2GB, so the
extension is the identity.  That is why the kernel boots, passes every
self-check, runs the JIT, and why
.CW virtarm64
boots too.  But the source says
.CW long ,
and
.CW long
is four bytes here; the code was relying on the compiler ignoring what it was
told.
.PP
.B "So the repair is the cast, and it is item A5."
Not a revert: a compiler that silently ignores a narrowing is not a position to
retreat to.  Nine sites, listed above, want
.CW uintptr
rather than
.CW long
\(em and the
.CW off
variables they feed want the same, or the change buys nothing.  It is a
separate, small, verifiable piece of work on the JIT, and it is deliberately
not being done at the end of the session that found it.
.NH 2
A5.  Nine pointer-through-long casts, from A3
.LP
.B Established.
The sites and the idiom are in A3.  They are latent, not active: correct on
every board in this tree because its addresses fit in 31 bits.
.PP
.B The work.
Change
.CW (long)
to
.CW (uintptr)
at those casts, and the
.CW long off
declarations that receive them to
.CW uintptr
or
.CW vlong ,
whichever the arithmetic wants.  Rebuild, confirm the nine
.CW "MOVW Rn,Rn"
sites are gone from the
.CW -S
output, and boot: the JIT is exercised by anything that runs Dis, so
.CW DRAW-OK
and the efs checks cover it.
.PP
.B "What would make this urgent."
A board whose kernel or JIT buffer sits above 2GB.  None here does, which is
why this is A5 and not A1.
.NH 2
A4.  CLOSED.  Only 6c and 7c were affected
.LP
.B "The first table was wrong, and this is what it should have said."
A first pass reported
.CW 5c ,
.CW 8c ,
.CW qc ,
.CW vc
and
.CW kc
as affected.  That test grepped for
.CW MOVWU
and
.CW AND ,
mnemonics those architectures do not use, so every one of them read as a
failure.  Read properly, all five are correct, by three different mechanisms:
.P1
5c, vc, kc   call _v2ui then _ui2v, runtime helpers
8c           MOVL the low word, then MOVL $0 to the high word
qc           stores REGZERO to the high word (R0ISZERO is set)
6c           MOVQ lo; ORQ -- no truncation.  AFFECTED
7c           was MOV with no truncation.  AFFECTED, fixed dcca478dd
jc, 0c       MOVWU.  correct
.P2
.CW qc 's
case needed one more step than reading: it emits
.CW "MOVW R0,0(R3)"
for the high word, and
.CW R0
is not obviously zero \(em a constant zero elsewhere compiles to an immediate
.CW $0 ,
not to
.CW R0 .
.CW utils/qc/txt.c
settles it:
.CW "if(R0ISZERO && a.type == D_CONST && a.offset == 0)"
substitutes
.CW REGZERO ,
so that store really is a zero.
.PP
.B "And the bound A4 was actually for."
A 32-bit target cannot have the
.CW load.c
bug at all, whatever its compiler does.
.CW WORD
is
.CW intptr ,
so on those machines
.CW hi
and
.CW lo
are 32 bits and
.CW (u32)lo
is not a narrowing \(em the line is correct by construction.
.CW armv7 ,
the one 32-bit board here that boots under QEMU, loads
.CW /dis32/*.dis ,
a
.CW DISWORD=4
build, which is the same thing said from the other side.
.PP
.B "What this is and is not."
Inspection, not execution, which the plan asked for and does not get.  The
justification for stopping at inspection is the paragraph above: there is no
victim to run.  Each reading is unambiguous in a way the first grep was not \(em
an explicit zero store or a named runtime helper, not an absence \(em and the
one ambiguous case was chased into the compiler's own source.  If a 64-bit
.CW big
constant ever does misbehave on one of these, this is the note to disbelieve.
.NH 1
B.  efs
.NH 2
B1.  The quadratic per-operation allocation
.LP
.B Established.
.CW efs
allocates more heap per operation the more entries the
.I filesystem
holds \(em not the directory, which was measured and falsified.  With the
written file's parent held at two entries:
.P1
fs 2 entries	 328.5 alloc/op
fs 62 entries	1370.7 alloc/op
fs 242 entries	2000.8 alloc/op
.P2
.CW memfs
mounted the same way is flat, 151.4 against 151.7, which is what puts the term
in
.CW efs
and not in the mount or Styx path.  The total is quadratic, which is why four
times the heap buys fewer than twice the files.  It is
.I not
a leak: live blocks fall during the work, so the ceiling is the high-water of
garbage the collector has not reached.
.PP
.B "Not established: which allocation."
.CW Fs.cblk / cnode
is bounded by
.CW Ncache
and cleared at commit;
.CW Fs.groups
caps at 2MB;
.CW Fs.freed
is emptied by commit.  Reads cost about what writes do, so the term is in the
path both share.
.CW Fs.range
collects every entry for an inode into an array on each call and has the right
shape \(em but reading the code already produced one falsified hypothesis
here, so it is a candidate and not an answer.
.PP
.B "How to find it, measuring not reading."
.CW /dev/memheap
names the live type and produced nothing in this emu, which is worth ten
minutes to fix because it answers the question directly.  Failing that,
.CW mprof(1)
names the line.  Failing both: bisect by instrumenting
.CW Fs.range
to count the entries it collects per call and comparing that count against
.CW nalloc
per operation across the three filesystem sizes above.  If the ratio is
constant,
.CW range
is the term; if it is not, it is somewhere else and the next candidate is
.CW pathto .
.PP
.B "The measure, which matters more than the fix."
.CW nalloc
per operation, from
.CW /dev/memory 's
heap row
.CW ( "cursize maxsize hw nalloc nfree nbrk poolmax name" ).
Live blocks are not the measure: the same arm gave 94 per operation in one emu
and 858 in another.
.CW tests/efs-leak.sh
holds the arms and the figures.
.PP
.B Done when.
.CW alloc/op
no longer grows with filesystem size, and
.CW tests/efs-limits.sh 's
fill arm reaches the end of a 4MiB filesystem instead of running out of
memory first \(em which is B3, and closes with this.
.NH 2
B2.  One namehash, not two
.LP
.B Established.
.CW namehash
exists twice, in
.CW appl/cmd/disk/efs.b
and
.CW appl/cmd/disk/mkefs.b ,
and the code's own comment says so: "Written in both places is one place too
many, and it moves to the library the moment anything else needs it."
.PP
.B "Why it is worth doing now rather than when something needs it."
A divergence between those two functions makes every name in an image created
by
.CW mkefs
unfindable by the server, silently \(em which is, precisely, the failure the
.CW big
literal bug produced, and it took three sessions to recognise.  Leaving a
second way to cause the same symptom is the expensive kind of tidiness to
skip.
.PP
.B The move.
Into
.CW appl/lib/efs.b
as
.CW Efs->namehash ,
declared in
.CW module/efs.m ,
with both callers using it.  Verification is that an image made by
.CW mkefs
with files in it still reads back under
.CW disk/efs
\(em which
.CW tests/efs-format.sh
already does, so it is a rebuild and a suite run.
.NH 2
B3.  efs-limits.sh's memory arm
.LP
Fails by design, and says so in its own comment.  It closes with B1 and needs
no separate work; it is listed only so that a reader who runs the suite and
sees
.CW EFS-LIMITS-FAIL
knows it is recorded rather than new.
.NH 1
C.  The rig
.NH 2
C1.  alive and where lie about a kernel from another build
.LP
.B Established.
.CW tools/jtag/boot.sh
took
.CW IMG
for the image to load but read the build stamp out of the tree's
.CW kernel8.img ,
so booting any other build reported "did not come up" three times over a
kernel that was running.  Fixed in
.CW 26b62cb13
by making
.CW ELF
travel with
.CW IMG .
.CW tools/jtag/alive
and
.CW tools/jtag/where
have the same hazard and were
.I not
fixed: they name
.CW os/inferno/raspi3b/iraspi3b
outright, so against a kernel built from another commit
.CW alive
reports
.P1
dead (ticks 0 -> 0, not advancing)
.P2
about a board that is running perfectly, because
.CW mach0
is at a different address in that build.
.PP
.B The fix.
.CW ELF=${ELF:-$ROOT/os/inferno/raspi3b/iraspi3b}
in both, as
.CW boot.sh
now has.  Verification: JTAG-boot a kernel built from an older commit, and
.CW alive
must report it alive when given the matching ELF and must
.I say it cannot tell
rather than report "dead" when given a mismatched one.  That second half is
the part worth building \(em this file's own history is five false failures
from instruments that returned a value instead of admitting they could not
see.
.NH 1
D.  Housekeeping
.NH 2
D1.  libinterp/w4 and libinterp/w8 are untracked
.LP
Both hold the same eleven headers
.CW ( runt.h ,
.CW sysmod.h
and the rest), and the kernel is built with
.CW -I$ROOT/libinterp/w$DISWORD .
So they are load-bearing and untracked, which is a combination that breaks a
fresh clone.  Establish which: if they are generated, find what generates them
and add them to
.CW .gitignore ;
if they are hand-written, they belong in the repository.  Do not commit them
without knowing \(em they may be another session's work in progress, which is
also why this is the last item and not the first.
.NH 2
D2.  Close the bind-create section
.LP
.CW doc/raspi3b-completion-plan.ms
carries a section on creates through a
.CW bind
of the
.CW efs
mount failing silently and poisoning the name.  The poisoning was the
.CW big
literal bug, and that is now fixed and verified.  What remains unexplained is
only the
.I bind
half, and the host already answers it: a create through a bind made without
.CW -c
fails
.I loudly ,
"mounted directory forbids creation".
.PP
So one board check closes it: on the fixed kernel, bind the efs mount without
.CW -c
and create through it, then with
.CW -c
and create again.  If the first fails loudly and the second succeeds, the
section folds into one paragraph saying the symptom was two bugs \(em a
namespace rule working as intended, and a VM defect \(em and neither is open.
If anything still fails silently, that is a new finding and the section stays.
