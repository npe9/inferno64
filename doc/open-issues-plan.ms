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
1  C1  the rig's ELF hazard      cheap, and it fakes failures
2  A4  do the 32-bit back-ends narrow?    cheap, bounds A
3  A3  audit what the 7c fix changed      a risk I introduced
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
A3.  What the 7c fix changed, unreviewed
.LP
.B Established.
Where a narrowing used to be dropped it now happens.  The aarch64 kernel grew
from 2537672 to 2540712 bytes, about 3KB of restored truncations across the
whole tree, and no site was reviewed individually.  The symptom to expect is
the mirror of the original: a value that used to keep its high word and now
loses it.
.PP
.B "What has been checked."
.CW libinterp/comp-aarch64.c ,
the one place flagged in advance, is clear: its sixteen
.CW (ulong)
casts are all
.CW "con((uvlong)(ulong)off, RCON)"
in
.CW mem() ,
whose
.CW off
is a
.CW long ,
and
.CW SZ_LONG
is 4 on
.CW 7c ,
so they never narrowed 64 bits.  The kernel boots on silicon and passes every
self-check it makes;
.CW virtarm64
boots under QEMU to a shell.  That is evidence against gross breakage, not
against a cold path.
.PP
.B "The audit, which is mechanical."
Build the aarch64 kernel twice, once with
.CW 7c
at
.CW dcca478dd
and once with its parent, keeping
.CW -S
output per object.  Diff.  Every hunk is a site where a truncation appeared;
there should be on the order of a few hundred, and each needs one question
answered: is the value being narrowed one whose high bits mattered?  The
interesting ones will be pointers and addresses cast through
.CW long
or
.CW int ,
and
.CW SZ_LONG
being 4 makes those genuinely dangerous.
.PP
.B "What would falsify the fix."
Any site where the truncation is wrong, which means the cast was written
sloppily and relied on being ignored.  The repair there is to fix the cast,
not to revert the compiler: a compiler that silently ignores what the source
says is not a position to retreat to.
.NH 2
A4.  Do the 32-bit back-ends narrow?  Probably, but it is unverified
.LP
.B Established.
A first pass reported
.CW 5c ,
.CW 8c ,
.CW qc ,
.CW vc
and
.CW kc
as affected.
.B "That was wrong"
\(em the test grepped for
.CW MOVWU
and
.CW AND ,
mnemonics those architectures do not use, so every one of them read as a
failure.  Reading the output instead,
.CW 8c
emits
.P1
MOVL	lo+12(FP),AX
MOVL	$0,CX
MOVL	hi+4(FP),BX
MOVL	$0,DX
ORL	AX,DX
ORL	CX,BX
.P2
and that
.CW "MOVL $0,CX"
is the zero extension, done correctly.  The 32-bit back-ends route 64-bit
values through
.CW utils/cc/com64.c
as register pairs, which is a different mechanism entirely.
.PP
.B Suspected.
That all five are correct.  Only
.CW 8c
was actually read.
.PP
.B "The check."
A C program that computes
.CW "(LONG)(u32)v"
for a
.CW v
with its low word's top bit set, prints the result, and is
.I run
rather than inspected \(em under QEMU for the targets that can be booted, or
compared against the host's answer where a kernel exists.  Inspection of
generated assembly is how the first pass went wrong; a number that comes back
from a running program cannot be misread.
.PP
.CW jc
and
.CW 0c
emit
.CW MOVWU
and are correct.  They are the reference: when in doubt about what a back-end
should do here, read
.CW utils/jc/txt.c .
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
