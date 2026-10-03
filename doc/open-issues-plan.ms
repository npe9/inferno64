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
3  A3  audit what the 7c fix changed      DONE: clean; left A5 hygiene
4  B2  one namehash, not two              DONE 2d273290f
5  A1  fix 6c                             DONE e5d6131f3 (A2 done b6a7201e9)
6  B1  efs's quadratic allocation         SYMPTOM FIXED; limits passes
7  D1  w4/w8, D2 close the bind section   DONE
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
A1.  DONE.  6c's peephole was deleting the truncation
.LP
The cause was not where the first draft of this plan guessed, and the method
the plan prescribed instead is what found it.
.CW "6c -t"
shows both casts of
.CW "(LONG)(u32)x"
surviving to
.CW "x complex" ,
so the defect is in the back-end.  Instrumenting
.CW gmove
shows it choosing
.CW AMOVL
for the narrowing \(em which is
.I correct ,
.CW MOVL
zero-extends on amd64 \(em and not skipping it.  So the instruction was emitted
and is simply absent from the output.  Compiling with
.CW -N
settles it: with the peephole off, both
.CW MOVL s
are there.
.PP
.CW utils/6c/peep.c 's
.CW loop1
had
.CW AMOVL
grouped with
.CW AMOVQ ,
.CW AMOVSS
and
.CW AMOVSD ,
copy-propagated and then excised.
.CW MOVL
is not a copy on amd64: it zeroes the upper 32 bits, so
.CW "MOVL AX,AX"
is a truncation and excising it removes the narrowing.  Fixed in
.CW e5d6131f3 .
All five narrowing types now emit one \(em
.CW MOVL ,
.CW MOVWQZX ,
.CW MOVBQZX ,
.CW MOVL ,
.CW MOVLQSX
\(em where the four-byte ones emitted nothing.
.PP
.B "What the board says, and what it does not."
.CW pc64
links again and was rebuilt with the fix, growing 8728342 to 8732789 bytes.
Before: two QEMU boots, two pool-allocator panics,
.CW alloc:D2B:free
and
.CW alloc:D2B:destroy-entry ,
at different addresses \(em heap corruption rather than a fixed logic error,
which is what a truncated pointer or size produces.  After: six boots, no
.CW D2B
at all, two of them reaching an interactive shell and running Dis cleanly.
.PP
But four of those six still panic \(em three general protection violations and
one
.CW cclose
\(em so
.CW pc64
has other problems and is not fixed, and two baseline runs is a thin control.
The
.CW D2B
class was present before and absent after; that is all the board supports.  The
compiler probe is the evidence for the fix.
.PP
.B "The AMOVL left in subprop is safe, and now for a reason."
The fix deliberately did not touch the
.CW AMOVL
in
.CW subprop() ,
on the grounds that there was no failure to point at.  That is a weak reason, so
it was settled.
.CW subprop
and
.CW copyprop
are called from
.CW loop1
and nowhere else \(em checked exhaustively \(em so after the fix
.CW r0
is only ever
.CW AMOVQ ,
.CW AMOVSS
or
.CW AMOVSD ,
never a truncating move.  The
.CW AMOVL
.CW subprop
can still match is the instruction it
.I retargets ,
and turning
.CW "MOVL x,v1; MOVQ v1,v2"
into
.CW "MOVL x,v2"
keeps the truncation, because it travels with the instruction that performs it.
Compiled both that shape and a two-consumer version: every
.CW MOVL
survives.  The reasoning is now in
.CW utils/6c/peep.c
beside the change.
.PP
.B "And the three claims A1 and A2 had to withdraw."
That the cause was the commented-out block at
.CW utils/6c/txt.c
759-815 \(em no, that comment opens after
.CW default: ,
whose live body picks
.CW AMOVL
correctly.  That
.CW gmove
or
.CW samaddr
was at fault, as in
.CW 7c
\(em no, both do the right thing here.  And that
.CW pc64 's
link failure was another session's uncommitted work \(em no: see A2.
.NH 2
A2.  DONE, and the premise was wrong
.LP
The plan said
.CW pc64 's
.CW "consdebugchar: undefined: archreboot"
was work in progress belonging to someone else, inferred from untracked files in
that directory.
.CW "git log -L"
on the call site says otherwise: the call was added to the
.I shared
.CW os/inferno/port/devcons.c
by
.CW c580839a5 ,
the commit that added
.CW ^R
for raspi3b, on this branch.  So this line of work broke the link for the two
x86 ports by giving shared port code a call no x86 port answered.  Every other
port defines
.CW archreboot ;
only
.CW pc
and
.CW pc64
do not.
.PP
Fixed in
.CW b6a7201e9 :
.CW pc64
already had the mechanism under another name, since
.CW exit()
ends with
.CW arch->reset() ,
so
.CW archreboot()
calls that directly \(em and deliberately not
.CW exit() ,
because
.CW ^R
exists to reset a machine whose software has stopped, and must not ask a wedged
server to flush.
.CW pc
is left alone: same gap, but it is not built here and I cannot check that
.CW arch->reset
is the right call there.
.PP
The lesson is the one this file keeps relearning.  "Untracked files are nearby,
so this is someone's work in progress" is an inference, and it was wrong; one
.CW "git log -L"
would have said so at the time, and it took four words to run.
.NH 2
A3.  DONE.  The 7c fix changed 100 files; nothing newly truncated is dereferenced
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
.B "The scan that matters, and the three ways it was wrong."
The question is whether any narrowed value is then used as an address.  Getting
that answer took four attempts, and the first three all produced findings that
were not there.
.PP
One: look only at
.I added
lines for the dereference.  One hit, in
.CW math.c ,
and it was
.CW bits32<>+0(SB)
\(em a destination symbol, not a register base.
.PP
Two: look at the following lines anywhere in the file.  104 hits, almost all of
this shape:
.P1
MUL	R4,R0
ADD	$32,R0
MOVW	R0,R0		<- narrows the SIZE argument
BL	,nheap+0(SB)
MOV	R0,dh-16(SP)	<- R0 is now the RETURNED POINTER
MOV	R2,8(R0)
.P2
The window crossed a call and paired a truncated argument with the pointer the
call returned.
.PP
Three: end the window at a branch or call.  Nine hits.  Chasing the first,
.CW xec.c 's
.CW slicela :
.P1
MOV	ss-24(SP),R2
MOV	0(R2),R2	<- ss->len
MOVW	24(R9),R3	<- t->size
MUL	R3,R2
MOVW	R2,R2		<- narrows the product: "int l", as declared
MOVW	R2,R10
MOVW	R10,R1
MOV	ss-24(SP),R2	<- R2 RELOADED: a different value
MOV	24(R2),R2	<- ss->data
ADD	R2,R1		<- sp = ss->data + l
.P2
The register is redefined between the narrowing and the dereference, so the two
have nothing to do with each other.  The narrowing is of
.CW "int l = ss->len * t->size" ,
which is exactly what the source declares.
.PP
Four: end the window at a branch, a call,
.I or
a redefinition of the register.
.B "Zero suspects, across all 93 linked files and all 859 added narrowings."
No value that the fix newly truncates is used as an address anywhere the kernel
links.
.PP
.B "What the chase did turn up, which is a source issue and not a codegen one."
While tracing the seven
.CW comp-aarch64.c
hits of attempt three, one idiom came out:
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
in kencc.  The compiler now honours that, where before it ignored it.  It
computes the right answer either way: these are differences between addresses
inside one allocation, so truncating both operands preserves the result, and
.CW off
is a 4-byte
.CW long
regardless.  It is written down as A5 because the source says something it does
not mean, not because anything is broken.
.PP
.B "Three claims this section had to withdraw, all its own."
That the one
.CW math.c
hit was real.  That there were 104.  That there were nine "followed by a
dereference".  Each died to looking at the actual instructions rather than
trusting the pattern that produced the count \(em which is the same discipline
that found the original bug, applied to my own analysis instead of someone
else's code.
.NH 2
A5.  CLOSED \(em but not as prescribed: the type was wrong and so was the test
.LP
.B Established.
.CW comp-aarch64.c
computed code offsets as
.CW "(long)(IA(...)) - (long)(code + codeoff)"
into a
.CW "long off" ,
with
.CW SZ_LONG
at 4.  Five sites, ten warnings from 7c.
.PP
.B "Not a bug, and the reason is not 'addresses are small'."
It is that these are differences between two addresses in the same allocation.
Truncating both operands modulo 2**32 and subtracting gives (a-b) mod 2**32, and
a branch displacement inside one code buffer is far below 2**31, so the signed
32-bit result is the true difference.
.PP
.B "This item prescribed uintptr.  That would have introduced a bug."
.CW off
is a
.I signed
branch displacement and the line after it reads
.P1
if(off <= 0x3FFFF && off >= -0x40000)
.P2
Make
.CW off
unsigned and every backward branch \(em the common case, since the macros sit at
the start of the buffer \(em becomes a number near 2**64, fails that test, and
takes the long form or
.CW urk s.
Widening the casts alone while leaving
.CW off
a
.CW long
happens to work, because assigning back to 32 bits restores the value mod
2**32, which is precisely the accident the change was supposed to stop relying
on.  The comment in the file asserted that widening to
.CW uintptr
"would be harmless"; it was wrong, and it has been replaced with the reasoning
above.
.PP
So the change is
.CW intptr
\(em signed and pointer-width,
.CW "typedef long long"
on this target \(em at the casts and at the
.CW off
variables together.  The displacement is then never truncated, and the
.CW ">> 2"
is an arithmetic shift of a true signed difference.
.CW B_IMM
and
.CW BCOND
mask to their field widths, so a negative
.CW off
still encodes correctly.  The five
.CW print s
of
.CW off
became
.CW %lld ,
which is the sort of thing changing a type quietly breaks.
.PP
.B "And this item's acceptance test was wrong too, in a way that would have read as failure."
It said to confirm the
.CW "MOVW Rn,Rn"
sites in
.CW punt ,
.CW commframe ,
.CW commcall ,
.CW comp
and
.CW compile
were gone from the
.CW -S
output.  They are not gone, and they were never going to be: they come from
other
.CW long
locals, not from the five pointer-difference sites that drew the warnings.
Counted per function, before and after:
.P1
                before  after
bcondbra             2      0
bconddis             2      0
blmac                2      0
bradis               2      0
bramac               2      0
punt                 2      2
commframe            4      4
commcall             4      4
comp                18     18
compile             17     17
(and 20 others)      -  unchanged
total               95     85
.P2
Ten removed, exactly the ten warnings, exactly in the five functions changed.
Had the prescribed check been run instead, it would have reported the change
had not worked.
.PP
.B Verified.
Zero warnings from the kernel build where there were ten; the ten
self-truncations gone and nothing else moved; and the kernel installed from the
card boots with
.CW DRAW-OK ,
.CW TK-OK
and all five EFS checks, with no
.CW urk
and no "branch too far" \(em which is the failure mode if the signed reasoning
above were wrong.
.CW "disbench -n 20"
on the board passes all seven tests with correct checksums, which exercises
these branch helpers in every compiled module.
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
.NH 2
A6.  DONE \(em the LOADERS, and a branch to itself inside panic()
.LP
The A-series above is about the compilers.  The loaders had a worse
defect, and it was in the one function whose failure cannot report
itself.
.PP
.B "Three bugs, each hidden behind the last."
.P1
brloop() followed an indirect branch and returned P
xfol() dereferenced that P                       (segfault)
xfol() abandoned the layout instead of using it
.P2
.CW brloop
walks a chain of branches to find a conditional branch's final target.
An INDIRECT branch has no resolved target, so the chain ran off the end,
.CW brloop
returned P, the caller skipped its patch, and the conditional branch kept
an offset of 0: a branch to itself, emitted silently.
.PP
.B "What it did to real kernels."
.P1
raspi3b (7l)   panic+240   0x54000000   B.EQ +0
pc64 (6l)      panic       74 fe        JE -2
.P2
On amd64 the whole tail of
.CW panic()
\(em a second call and a retry loop \(em was not in the binary at all.
pc64 relinks ten bytes larger with identical symbol sets and the change
confined to one site: 539 text symbols unmoved, 3950 shifted by exactly
+10, boundary at
.CW panic .
A peer session scanning a kernel from another branch found it at
.CW panic+0xf0 ,
the same offset, independently.
.PP
.B "And the synthetic test passed the whole time."
.CW tests/kencc-brloop.sh
assembles four instructions and checks the encoding; it is a good test
and it was green while the loader was doing this to every kernel it
linked, because the pattern it reproduces is not the only way to reach
the defect.
.CW tests/kencc-selfbranch.sh
asks the question that matters instead \(em is there one in the binary
we are about to boot \(em and that is what found it.  Keep both; they are
not substitutes.
.PP
Two filters that scan needs, both learned by chasing ghosts: a hit must
lie INSIDE A FUNCTION, because this kernel embeds instruction-template
tables in its text segment (six matches, all data, in a 29KB unsymbolised
gap); and the scan must check
.CW e_machine ,
because the first version scanned the riscv kernels for an AArch64
encoding and called them clean.
.PP
.B "5l and jl take the same change; 8l takes only the nil check."
Verified by relinking the real armv7 and virts kernels.  And that is the
method lesson: the one-line fix applied to all five loaders passed the
synthetic test and SEGFAULTED 6l on the real pc64 kernel.  A loader
change is validated by relinking something large, not by a test case.
.PP
.B "Also done, from the same thread."
6l and 7l wrote FOUR-byte symbol values for every header type but the
Plan 9 one, so every kernel linked with
.CW -H7
had a symbol table truncated to 32 bits \(em harmless while these boards
link low, wrong the moment one does not.  Both write the address width
now.
.PP
And libmach could not read a Plan 9 executable AT ALL on this host:
.CW Exec 's
fields were declared
.CW long ,
so
.CW sizeof(Exec)
was 64 against an on-disk 32 and every field came out one slot shifted.
.CW elf.h 's
.CW Ehdr
and
.CW Phdr
had the same defect, so ELF32 never worked either, and there was no
arm64 machine description and no 64-bit ELF reader.  All fixed:
.P1
raspi3b (arm64 ELF64)   5866 symbols
pc64 (amd64 Plan 9)     6035
virts (riscv64 ELF64)   5080
armv7 (arm ELF32)       3465
.P2
.CW "sh tools/sym.sh <addr> [board]"
names a kernel address, which is what
.CW doc/parallel-allocator-survey.ms
recorded being unable to do.
.PP
.B "The narrowing-cast family is CLEAN, which is worth recording as a negative."
A1 to A4 chased
.CW kencc
dropping a truncating cast.  Asked again, every 64-bit compiler now
truncates correctly in the load-bearing shape \(em a cast used mid
expression where nothing downstream truncates \(em at 32, 16 and 8 bits:
.P1
          (u64)(u32)x      (u64)(u16)x     (u64)(u8)x
7c        MOVWU            MOVHU           MOVBU
6c        MOVL             MOVWQZX         MOVBQZX
jc        MOVW/MOVWU       MOVHU           MOVBU
.P2
A note elsewhere in this tree says "6c still broken"; it is stale.
.NH 1
B.  efs
.NH 2
B1.  DONE \(em the quadratic is fixed, and forty minutes is now forty-two seconds
.LP
.B "The fix, after four that were not."
.CW Node.unpack
allocated an array per entry and copied the entry's value into it, so decoding a
node cost one allocation per entry in the block \(em and blocks get fuller as a
filesystem fills, which is the quadratic.  It now
.I slices
the block.
.CW 3d09ea990 .
.P1
              fs 2    fs 62   fs 242
before         328     1372     1989
after          306      858     1203
.P2
Seven, thirty-seven and forty per cent, which is exactly the decode share the
attribution counter predicted.  The remaining figures still grow, so the
quadratic is reduced and not removed.
.PP
.B "Why the copy was there, and why slicing is safe."
The comment it replaces says a slice "would be a window on whatever block the
buffer next held".  No buffer is ever held again:
.CW Dev.rdblk
allocates a fresh
.CW array[Blocksize]
on every call and never reuses one, a slice keeps its parent alive by refcount,
and the only buffers written in place are free-map groups, which are never
unpacked as nodes.  Entry values are read-only in every caller.
.PP
.B "And it is a 40% cut in COUNT, which is what mattered."
The earlier
.CW mprof
reading showed these allocations are small in
.I bytes
\(em an entry's value is a handful \(em which is why that instrument ranked them
below the shell.  The pressure is on the count, and the count is what moved.
.PP
.B "Verified, including the thing the limits test was asking for."
The whole suite passes, with
.CW efs-crash 's
40 crash points mounted clean and whole, and
.CW efs-wedge
unaffected.  Filling a 4MiB filesystem to capacity now ends properly: 515 files,
.CW REFUSES-AFTER-FULL ,
a clean remount listing 516 entries, and
.CW efsck
clean at generation 1032.  A standalone fill says "filesystem is full" where the
figures recorded in
.CW efs-limits.sh
were 151 to 292 files and "out of memory: heap".
.PP
.B "The limits arm still fails, and its failure is pacing."
Its own script runs out of memory where an otherwise identical loop with a print
per iteration fills to 516 \(em twice each.  A print changes the outcome, so that
arm turns on when the collector runs and is not a clean measure of
.CW efs .
Left failing rather than tuned until it passes.  Its verdict is fixed regardless:
it reported a timeout as "runs out of MEMORY", and now records
.CW EMU-TIMEOUT
in the transcript and says which of three failures happened.
.PP
.B "What is left of B1."
The growth that remains \(em 306 to 1203 \(em is still unattributed, and the way
to attribute it is the one that worked: a counter on the work, tagged with the
caller, its total checked against
.CW nalloc .
The four approaches already tried and why each failed are below, and the
pacing sensitivity above is a hint that the collector's trigger, not
.CW efs 's
totals, may be the thing that decides whether a fill survives.
.PP
.B "Fs.range is NOT the term, which the bisect settled first."
It was the leading suspect and the plan flagged it as a candidate rather than an
answer.  Counters on it, per operation, across all three sizes:
.P1
          alloc/op  range/op  ents/op  leaf/op  path/op
fs 2         328       2.0      3.0      1.0      6.0
fs 62       1372       2.0      3.0      0.0      6.0
fs 242      1989       2.0      3.0      1.0      6.0
.P2
Every one of them is flat while allocations grow six-fold.
.CW range
is called twice, returns three entries and advances one leaf, whatever the size
of the filesystem.  Neither it nor
.CW pathto
is the term, and the iterator the module's own comment contemplates would not
have helped.
.PP
.B "The term is entries unpacked, and it is NODE fullness."
.CW getnode
decodes a whole block, and
.CW Node.unpack
allocates an
.CW Ent
\(em a
.CW Key
and an
.CW "array of byte"
\(em for every entry in it.  Counting that:
.P1
          alloc/op  getnode/op  entries-unpacked/op
fs 2         328        4.0            22
fs 62       1372        8.0           514
fs 242      1989       14.0           789
.P2
The fit is linear:
.CW (1372-328)/(514-22)
is 2.12 and
.CW (1991-1372)/(789-514)
is 2.25 allocations per entry unpacked, on a fixed cost near 281.  As a
filesystem fills, its blocks get fuller, so every lookup pays for decoding
hundreds of entries to find one.  That is the quadratic, and it is why four
times the heap bought under twice the files.
.PP
.B "Caching cannot fix it, and that was tried and reverted."
The obvious move is to keep the decoded nodes.  The cache is cleared at every
commit \(em and an operation ends in a commit \(em so it was changed to drop only
the blocks the transaction freed, which are known, keeping the rest: a committed
block is never written again, so its number still identifies its contents.
.PP
Measured:
.CW "328/1372/1989"
became
.CW "324/1367/1985" .
Nothing.  The reason is copy on write: every modifying operation rewrites the
path, so the next one reads
.I new block numbers
and the cache can never hit across operations.  The counters say so directly \(em
.CW getnode/op
stays at 4.0 over 240 operations on the same file instead of falling to zero, so
not one block is ever seen twice.  The change was reverted: it is arguably more
correct than clearing everything, but no measurement justifies it and the code
it adds is not free.
.PP
.B "Two attempted fixes, both measured, both reverted."
.I "Keep the decoded nodes across commits."
The cache is cleared at every commit and an operation ends in one, so it was
changed to drop only the blocks the transaction freed \(em known, and sound,
since a committed block is never written again.  Measured:
.CW 328/1372/1989
became
.CW 324/1367/1985 .
Nothing.  Copy on write is why: every modifying operation rewrites the path, so
the next reads
.I new block numbers
and the cache cannot hit across operations.
.CW getnode/op
staying at 4.0 over 240 operations on one file says it directly \(em no block is
ever seen twice.
.PP
.I "A descent that does not decode."
The cache was changed to hold the block
.I bytes ,
with
.CW getnode
decoding on demand and remembering the result per slot, and
.CW leaffor
and
.CW pathto
rewritten to walk the entries in place through a new
.CW Fs.descend
\(em keys compared out of the buffer, nothing copied.  Measured:
.CW 330/1371/1989 .
Nothing again.
.PP
.B "And that is the useful result, because it says where the cost is not."
The descent was never paying for the unpacking.  Interior nodes are few and
hold pointers; the entries are in the
.I leaves ,
and the callers that read leaves \(em
.CW range ,
which collects every entry for an inode, and
.CW replace ,
which decodes a leaf, rebuilds it with one entry inserted and re-packs it \(em
genuinely need all of them.  So no amount of laziness in the descent helps.
.PP
An intermediate version, lazy descent
.I without
the per-slot decoded node, was
.I worse
\(em
.CW 434/3075 ,
and arm C did not finish \(em because
.CW range ,
.CW replace
and
.CW fixup
walk the same blocks repeatedly within a transaction and were re-decoding on
every call.  That is worth knowing: the decoded-node cache does real work
inside a transaction, even though it never survives one.
.PP
.B "Three fixes attempted, all measured, all reverted."
.P1
keep decoded nodes across commits   328/1372/1989 -> 324/1367/1985
a descent that does not decode      328/1372/1989 -> 330/1371/1989
patch fixup's child pointer in place 328/1372/1989 -> 328/1343/1934
.P2
The third is a real improvement and does strictly less work \(em interior entries
are a fixed 27 bytes, so a parent whose child pointer changed can be edited in
the packed block instead of decoded, rebuilt entry by entry and re-packed, and a
counter confirms that path is taken 8 times per operation and the rebuild never.
Three per cent.  It was reverted all the same: a change to the format layer
needs a reason better than three per cent, and the dominant cost is still not
identified.
.PP
.B "The counter was built, and the attribution is now solid."
The flaw behind the three attempts was comparing two counters that do not
measure the same thing:
.CW unpents ,
incremented inside
.CW getnode
after
.CW Node.unpack ,
counts entries
.I actually decoded ,
while
.CW fixents
and
.CW replents ,
incremented at the call sites, count entries
.I seen ,
cached or not.  So
.CW "fixents = 660"
never meant 660 decodes, which is why removing all of them changed nothing.
.PP
Replaced by one counter on the miss path, tagged with the call site that forced
the decode.  On a 242-entry filesystem:
.P1
call site    decodes/op   entries/op
leaffor          7.00        455.0
nextleaf         1.00          1.0
pathto           6.00        333.0
replace          0            0
fixup            0            0
TOTAL                        789.0
.P2
The total is the 789 measured independently, which is the check that this
counter is the trustworthy one.  All of the decoding is in the
.I descent ,
and
.CW replace
and
.CW fixup
force
.I none
\(em they hit the cache that
.CW leaffor
and
.CW pathto
have already filled.  So the third attempt, patching
.CW fixup ,
was aimed at a function that never decodes anything, and its three per cent was
the re-pack it avoided and not a decode.
.PP
.B "But the decodes are not the whole quadratic, and that is new."
If each decoded entry costs one allocation \(em
.CW Node.unpack
allocates one array for the entries and one value array per entry, and
.CW Key
is scalar so it costs nothing \(em then:
.P1
fs   2 entries   22 decoded/op of  328 alloc/op    7%
fs  62 entries  514 decoded/op of 1372 alloc/op   37%
fs 242 entries  789 decoded/op of 1998 alloc/op   39%
.P2
A growing share, and the largest single term identified, but three fifths of the
allocations at the large end are still unattributed.  Removing the decoding
entirely would take 1998 to about 1200, against 328 at two entries \(em still
growing.  So the descent's decoding is
.I a
term and not
.I the
term, and B1 is not one fix.
.PP
.B "The decisive run, and it explains all three failures: the decoding is conserved."
The plan said to re-run the non-decoding descent with the attribution counter and
read
.CW decodes/op .
Done, on a 242-entry filesystem:
.P1
            alloc/op  decodes/op  entries decoded/op
baseline        1998     14.00          789.0
lazy descent    1999     14.00          789.0
.P2
Not one decode avoided.  The descent stops decoding, and
.CW replace ,
.CW fixup
and
.CW range
then miss the cache and decode exactly the same blocks themselves \(em because
they want a
.CW Node ,
not a block.  The attribution in the baseline, which put all 789 on
.CW leaffor
and
.CW pathto ,
was only recording who reached the block
.I first .
.PP
So the decoding cannot be moved; it can only be removed, by making the callers
that need it not need it.
.CW fixup
is the one case where that is easy, because an interior entry is a fixed 27 bytes
and a child pointer can be patched in the packed block \(em which is what the
third attempt did, for three per cent.
.CW replace
would need the same treatment for a variable-width leaf entry, and
.CW range
genuinely wants every entry it returns.
.PP
.B "And even all of it is not the whole quadratic."
.CW Node.unpack
allocates one array for the entries plus one value array per entry, so one
allocation per decoded entry is the right order:
.P1
fs   2 entries   22 decoded/op of  328 alloc/op    7%
fs  62 entries  514 decoded/op of 1372 alloc/op   37%
fs 242 entries  789 decoded/op of 1998 alloc/op   39%
.P2
Removing every decode would take 1998 to about 1200, against 328 at two entries.
Still growing.
.PP
.B "mprof, and a fourth instrument read wrongly."
.CW mprof(1)
gives memory per line of Limbo, which is what the unattributed remainder wants.
Its default profiles
.I "main, heap and image together"
\(em main being dis code, JIT code and runtime stacks \(em and read that way it
put
.CW checksum()
third, at 722KB over 40 operations, for a loop that contains no allocation at
all.  That was stacks, not heap.
.CW "mprof -2"
is heap alone, and with it the picture is different:
.P1
sh.b:919   ctxt.setlocal("*", tl args)     524160 cur  535440 hiwat
sh.b:1560  for (vl := e.vars[i]; ...)      524160       528824
env.b:25                                   113160       113544
efs.b:1252 fixup's getnode                  31424       191232
efs.b:480  Node.unpack's entry loop         20952       287640
.P2
The shell dominates the
.I current
heap and
.CW efs 's
lines are mostly transient \(em
.CW hiwat
far above
.CW cur
\(em which is consistent with this being collector pressure rather than
retention.  The shell's share is the same work on every operation whatever the
filesystem holds, so it belongs to the fixed cost near 281 and not to the growth.
Within
.CW efs ,
the two largest are the decode loop and the
.CW getnode
in
.CW fixup .
.PP
.B "The gap that remains, stated exactly."
.CW mprof
measures
.I bytes ;
the quadratic was measured in allocation
.I count ,
from
.CW nalloc .
A decoded entry's value array is a handful of bytes and one allocation, so it can
be most of the count and little of the bytes \(em which is why these two
instruments rank things differently and why neither alone closes the question.
What is needed is a per-line or per-function allocation
.I count ,
which
.CW mprof
does not report.  Failing that, the honest next step is a counter on each
candidate allocation site in
.CW efs ,
summed and checked against
.CW nalloc
per operation the way the decode counter was checked against the 789.
.PP
.B "Four attempts, and what each one taught."
Keeping decoded nodes across commits: no effect, because copy on write renumbers
the path.  A non-decoding descent: no effect, because the decoding is conserved.
Patching
.CW fixup :
three per cent, real but not worth a format change on its own.  And the
attribution counter itself, which is the one that should have been built first
and is the only instrument here whose total can be checked against an
independent measurement.
.PP
.B "What is solid, after all of it."
That
.CW alloc/op
is 328, 1372 and 1989 at 2, 62 and 242 entries, reproduced many times.  That
.CW memfs
is flat.  That it is collector pressure and not a leak.  That the term is
entries decoded by
.CW Node.unpack ,
which allocates an
.CW Ent
per entry.  And that the cache cannot help across operations because copy on
write renumbers every block on the path \(em
.CW getnode/op
stays at 4.0 over 240 operations on one file.  The open question is only which
caller forces those decodes.
.PP
.B Done when.
.CW alloc/op
no longer grows with filesystem size, measured by
.CW nalloc
from
.CW /dev/memory 's
heap row \(em not live blocks, which gave 94 per operation in one emu and 858 in
another \(em and
.CW tests/efs-limits.sh 's
fill arm reaches the end of a 4MiB filesystem instead of running out of memory.
That closes B3 with it.
.PP
.B "ATTRIBUTED, 2026-10-01, and it is INTERIOR nodes \(em not what this item concluded."
The growth above was left "still unattributed", with the instruction to attribute
it the way that worked: a counter on the work, tagged with the caller.  Done.  A
counter inside
.CW getnode 's
MISS path \(em so a cache hit is not counted as a decode \(em tagged by which of
the six call sites asked, and separately by node type.  300 files into one
directory of a 4096-block image, 600 commits, host emu:
.P1
caller        decodes   entries decoded
Fs.range        14754            217360
Fs.leaffor       1706            123670
Fs.pathto        1353             95520
Fs.replace          0                 0
Fs.fixup            1                70
                -----            ------
                17814            436620

by node type  decodes   entries   entries/node
interior         2970    294020             99
leaf            14844    142600            9.6
.P2
The two totals agree exactly, 294020+142600 = 436620, which is the internal
check; the external one is this item's own earlier figure of 789
entries-unpacked/op at 242 files against 1450/op here at 300, same order and
growing in the right direction from an independently built instrument.
.PP
.B "The claim above that Fs.range is NOT the term was wrong, and the reason is instructive."
The table it rests on measured
.CW range/op
\(em range
.I calls
per operation \(em and found it flat at 2.0.  It is flat.  But the
.I work
those two calls cause is the largest term of the three: 14754 of the 17814 node
decodes, 83 per cent, and 217360 of the 436620 entries.  It is also the
fastest-growing: over the last twenty files of the run, range added 38596 entries
against leaffor's 11973 and pathto's 10504.  Counting calls at the call site and
counting work on the work path are different measurements, and this plan has
already written that lesson down once for
.CW fixents
versus
.CW unpents .
It was made again one level up.
.PP
.B "And the target is interior navigation."
Two thirds of every entry decoded is in an
.I interior
node, which is decoded only to choose one child of it.  An interior node here
averages 99 entries; a leaf averages 9.6.  Interior entries are fixed width \(em
.CW Keysz
17, a 2-byte length and an 8-byte block number, 27 bytes \(em so an interior block
can be navigated, or even binary searched, in the packed bytes with no
allocation at all.
.CW Key.unpack
returns a value and does not allocate; what allocates is the
.CW "array of Ent"
and the per-entry value slice, and interior navigation needs neither.
.PP
.B "Why it is NOT implemented here."
Because the obvious implementation trades a known cost for an unmeasured one.
.CW getnode
caches
.I decoded
nodes, and
.CW Dev.rdblk
allocates a fresh
.CW array[Blocksize]
on every call, so navigating in packed bytes means either re-reading a 4KB block
per level or adding a block cache beside the node cache.  Trading 99 small
allocations for a 4KB one may be a loss, and this item already records two
cache changes that measured as nothing.  That is a design decision with a
number attached to it, and the number to beat is in the table above.
.PP
.B "TRIED, measured, and REVERTED \(em and the reason is that the term is not where the TIME is."
Packed interior navigation was built and measured before being reverted:
.CW pntype ,
.CW pnents ,
.CW pchild
and
.CW pchildfor
walking a block's bytes, a raw-block cache under the decoded one, and
.CW Fs.leaffor ,
.CW Fs.pathto
and
.CW Fs.nextleaf
converted to use them.  Same workload, same counters:
.P1
                 before     after
interior ents    294020     85356
leaf ents        142600    142318
total            436620    227674     \(em48%
raw block reads    (n/a)     17814
.P2
.B "The design worry is answered, and the answer is good."
17814 raw reads is
.I exactly
the 17814 decodes the old path did, so navigating in packed bytes costs no
extra block read at all.  The residue is
.CW Fs.fixup ,
which rebuilds a parent and so genuinely needs its entries \(em and part of
it is the cache moving rather than the work going: 
.CW pathto 's
decoding used to warm the node cache that
.CW fixup
then hit.
.PP
.B "But 48 per cent less work bought about 4 per cent of wall time, and that is arithmetic, not luck."
Host, three runs each, 300 creates:
.CW "0.99/0.99/0.97 s"
became
.CW "0.87/0.95/0.97 s" .
The reason is in figures this plan already has.  The board allocates 190000
objects a second (F1's compute-bound measurement), and a create at 60 files
costs 4205 allocations \(em about 22ms of a 150ms create, some 15 per cent.
Cutting a 15 per cent term by half is 7 per cent, and that is what was seen.
.B "Allocations were never going to explain a 7-second create."
.PP
.B "The board A/B could not see it either, for a reason worth keeping."
Sixty creates on a 1024-block image gave
.I identical
allocations per create, 4205 both ways: at that size the tree is shallow and
interior nodes are a small share of what is decoded, so the arm chosen to be
cheap enough to run was too small to contain the effect.  The times differed
by 26 per cent across five rounds, which is inside this rig's known drift and
was not believed.
.PP
.B "Why it was reverted rather than kept as a free 48 per cent."
Two runs of 300 creates on the board did not finish in the time the 60-file
growth curve predicts \(em 81, 90, 118, 137, 149, 168 ms per create over six
rounds extrapolates to about 100 seconds for 300, and both runs exceeded forty
minutes, one ending in a reboot whose cause had already left the per-boot
console ring.  And the same workload was never run on the board with the
COMMITTED library, so there is no control: the change was neither convicted nor
exonerated.  An optimisation with no measured benefit and an open question
against it does not belong in the filesystem this board boots from.  The patch
is recoverable from this entry's description; it is not subtle.
.PP
.B "And the real finding, which reframes this whole item for the board."
The host does those 300 creates in 0.95 seconds.  The board takes more than
forty minutes.  That is a factor of 2500 where
.CW disbench
puts the processor difference at 10 to 50.  Allocations are 15 per cent of a
create and cannot be it; the free map is one group at these sizes and the image
size was shown flat across a 64-fold range.  What is left is the writes: every
efs block goes to a FILE on
.CW dossrv ,
and a commit rewrites a path.  So B1's quadratic is real, is now attributed,
and is NOT what makes a create slow on this board.  The next measurement is
writes per commit and microseconds per write through
.CW dossrv .
.PP
.B "MEASURED, and the forty minutes is now forty-two SECONDS."
The same three hundred creates, on the card, through
.CW dossrv ,
on a file of its own:
.P1
300 creates on /n/dos        42.56 s     142 ms each
  per round of fifty          6.83  6.62  7.28  7.15  7.59  7.09
the same on sdmem(3)         32.86 s     110 ms each
host emu, for reference       0.95 s
.P2
At least 56 times better than the figure above, flat across the run, and
.CW efsck
clean at generation 302.  Everything in B1a to B1f is in that number:
even splitting, the keyed dentry lookup, the write batch, the clunk rule
and the writeback cache.
.PP
.B "And the medium is no longer the cost, which inverts the premise of this whole item."
The card adds 9.7s to the free medium's 32.9, which is 23 per cent of a
create.
.CW man/3/sdmem
records it as about 70 per cent, and that was true when it was written.
Three hundred creates issue 3701 transfers, so the card is costing about
2.6ms a transfer through
.CW dossrv
\(em which is the "microseconds per write" this item asked for.
.PP
.B "The read-modify-write attribution above is WRONG, and G1b measures it."
That 2.5MB through
.CW dossrv
does 1251 reads with TWO read-modify-writes, against 1245 clusters
allocated.  The reads are a FAT lookup per cluster, not the track cache
doing read-modify-write.  Different fix, and not efs's.
.PP
So the remaining question in this item \(em whether efs on a raw partition
is a different machine \(em is now worth much less than it was: there is
only 23 per cent to win, and part of that is the FAT lookups rather than
the card.
.NH 2
B1a.  MEASURED \(em the growing term is READS, and walk and create scan the whole directory
.LP
Those measurements were taken.  Counters on
.CW Dev.wrblk
and
.CW Dev.rdblk ,
300 creates into one directory, printed every twenty commits:
.P1
commits   writes (+per 20)   reads (+per 20)
     20        109  (+109)        95   (+95)
    200       1423  (+157)      1247  (+140)
    300       2188  (+150)      2009  (+160)
    400       2989  (+160)      5752 (+1205)
    500       3740  (+150)     12352 (+1320)
    600       4500  (+159)     19018 (+1386)
.P2
.B "Writes are FLAT, at about 7.8 per commit, the whole way."
So the model that a fuller directory rewrites more blocks per commit is wrong,
and so is anything that follows from it.
.PP
.B "Reads go from about 4.8 per commit to about 69, and the step is between 150 and 200 files."
That is the quadratic.  It is in reads, which is why the packed-navigation
change above could not have helped: that change left reads untouched, and said
so \(em 17814 raw reads before and after, exactly equal.  The one number it was
careful to prove unchanged was the one that mattered.
.PP
.B "And the cause is in the SERVER, not the library and not the medium."
.CW appl/cmd/disk/efs.b
asks for the whole directory to answer a question about one name:
.CW walkto()
at 364,
.CW create()
at 733 and
.CW deldentry()
at 918 each call
.CW "fs.range(dir, Kdentry)"
and scan the result linearly.  Every walk and every create therefore reads every
leaf of the directory, so an operation is O(entries) in reads and filling a
directory is O(entries squared).
.PP
.B "The key is already designed for the lookup that is not being done."
A dentry's key is
.CW "Key(dir, Kdentry, namehash(name))"
\(em
.CW "create()" :775 builds it that way.  So a name could be found with one
.CW Fs.get ,
a descent of three or four reads, instead of a scan of the directory.
.PP
.B "What makes it non-trivial, in create()'s own words."
"A second dentry with the same name hashes to the same key and a bucket holds
collisions \(em so the check has to be here."  The hash is 64-bit FNV-1a masked
to 63 bits, collisions are possible, and the tree holds more than one entry at a
colliding key.
.CW Fs.get
returns one.  So the lookup wants to retrieve every entry AT one key and scan
only those \(em normally one \(em which is a new library call, not a
substitution.  Done wrongly it either misses a file or reintroduces the scan.
.PP
.B "Before building it, do the division."
This item has just paid for not doing that: a 48 per cent cut in decode work
bought 4 per cent, because decoding was 15 per cent of a create.  The share to
establish first is reads: how many microseconds a block read costs through
.CW dossrv
on this board, times the reads per operation above, against the measured time
per create.  A floor is already known \(em ten file creates straight onto
.CW /n/dos ,
FAT through the same
.CW dossrv
and the same card, cost 38.8ms each, against 97.7ms for an efs create on the
same card \(em so a single durable metadata update on this medium is tens of
milliseconds and efs pays about 2.5 times it at small directory sizes.  If 69
reads a commit are each anywhere near that, reads are the whole story and the
keyed lookup is worth building.
.NH 2
B1b.  ANSWERED, with an instrument: sdmem(3), a block device in RAM
.LP
The division above was done by taking the medium away.
.CW os/inferno/port/sdmem.c
is an
.CW sd (3)
controller whose storage is memory: sparse, 4096-byte chunks allocated on
first write, a hole reading as zeros, and
.B "the read and write counters in the driver"
so that anything layered on it \(em
.CW efs ,
.CW kfs ,
.CW dossrv ,
a raw
.CW dd
\(em is counted without being instrumented.  It also charges a settable
.CW delay
in microseconds per transfer, once per transfer and not per sector, so a
medium's cost can be put back and swept.  See
.CW man/3/sdmem .
.PP
.B "The counters cross-validate the hand-patched ones, which is the first thing it bought."
Three hundred creates into one directory, counted by the driver, against the
same workload counted by counters patched into
.CW appl/lib/efs.b
and reverted:
.P1
            efs's counters   sdmem's counters
writes               4500               4508
reads               19018              17014
.P2
Two instruments at different layers, neither aware of the other.  The writes
agree to eight parts in four thousand.
.PP
.B "And the growth survives the medium being free."
Same three hundred creates, on
.CW /dev/sdZ0/data
with
.CW "delay 0" ,
timed per fifty:
.P1
creates     ms each
  1-50           35
 51-100          49
101-150          78
151-200         139
201-250         140
251-300         160
.P2
29.6 seconds in total, growing by a factor of 4.6.  The medium costs nothing
here, so that growth is the filesystem and not the card.  B1a's suspicion is
confirmed from the other side.
.PP
.B "The medium's share, measured rather than divided."
Ten creates, same shape, three ways on the same board:
.P1
FAT on the SD card, through dossrv     38.8 ms each
efs on the SD card, through dossrv     97.7 ms each
efs on sdmem, delay 0                  28.2 ms each
.P2
So about seventy of those ninety-seven milliseconds is the card.  The
filesystem's own cost is 28ms at ten files and 160ms at three hundred, and
THAT is the quadratic worth attacking.
.PP
.B "Which revives the change this plan reverted."
Packed interior navigation cut decode work 48 per cent and bought 4 per cent
of wall time \(em measured against the SD card, where the medium was seventy
per cent of a create and hid it.  On
.CW sdmem
the medium is nothing and the decode work is a far larger share, so the same
change should be re-measured there before it is dismissed.
.PP
.B "RE-MEASURED, and it is worth 2x.  The change is back in."
Identical workload, identical image, both arms on
.CW /dev/sdZ0/data
with
.CW "delay 0" ,
timed per fifty creates:
.P1
creates    baseline   packed    ratio
  1-50         35       18.4     1.9
 51-100        49       23.7     2.1
101-150        78       44.2     1.8
151-200       139       61.4     2.3
201-250       140       75.7     1.85
251-300       160       75.1     2.1
total      29.6 s     14.9 s     1.98
.P2
.B "And the control is exact, which is what the driver's counters are for."
Both arms report, byte for byte:
.P1
reads   17014 ops  136112 secs
writes   4508 ops   36064 secs
chunks   3912 held
.P2
The same I/O, the same allocation footprint, so the whole difference is CPU \(em
which is the claim the change makes and nothing else.  No sampling, no drift,
no three-run median: the thing that would have confounded it is measured and
equal.
.PP
.B "The 4 per cent was not wrong, it was measured through the wrong medium."
Against the SD card the medium is about seventy per cent of a create and hides
a halving of the other thirty.  Against a medium that costs nothing the same
change is a factor of two.  One patch, two defensible numbers, and the
difference between them is entirely the instrument \(em which is the argument
for
.CW sdmem
existing, made by the first thing it was pointed at.
.PP
.B "And it answers the open question that got the change reverted."
Two runs of 300 creates on the card had not finished in the time a 60-file
curve predicted, with no baseline arm to compare against, and that absence of a
control was the stated reason for reverting.  The control is now arithmetic on
measured counters: 300 creates are 17014 reads and 4508 writes, 21522
transfers, and a transfer on that card costs tens of milliseconds \(em ten FAT
creates measured 38.8ms each.  21522 at 38.8ms is fourteen minutes at the
floor, before
.CW dossrv 's
read-modify-write.  So forty minutes is what 300 creates on that card COST, in
either arm, and both arms issue exactly the same transfers.  The change was
never implicated; the medium was.
.PP
.B "Calibration, so the delay is not believed more than it deserves."
200 transfers at
.CW "delay 1000"
added 221079us over the same workload at
.CW "delay 0" ,
or 1105us each against 1000 asked for.  The overshoot is
.CW microdelay 's
granularity.  The counters are exact; the delay is approximate and should be
quoted as such.
.NH 2
B1c.  FIXED \(em the leaves were eight per cent full, because a split was greedy
.LP
B1a said the growing term was reads and that they were in a directory scan.
Attributing them, with a counter in
.CW Fs.rawblk 's
miss path tagged by caller:
.P1
commits   leaffor   nextleaf   pathto
    200       506          0      337
    400      1106       4145      866
    600      1706      15845     1366
.P2
.CW Fs.nextleaf ,
the leaf-advance
.CW Fs.range
uses, is 84 per cent of every read and is the thing that grows.
.PP
.B "But it was not walking too far.  The leaves were nearly empty."
Of 15077 leaves walked, 5 matched nothing \(em so the scan stays inside its
key range.  It took 16.7 leaves per call to see 147 entries, about eight per
leaf, where a dentry is some 35 bytes and a 4096-byte leaf holds over a
hundred.  Interior nodes meanwhile ran 65 per cent full.
.PP
.B "The cause, measured rather than reasoned: every split made a one-entry leaf."
.CW Fs.writeents
packed each node full and started another when one overflowed.  The shapes it
produced, first piece over total:
.P1
96/97  97/98  97/98  98/99  98/99  99/100
.P2
A dentry's key is a name hash, so inserts arrive at uniformly random points.
The one-entry leaf covers a sliver of the key range and almost nothing lands
in it again, while the full leaf keeps being hit and keeps shedding another
one.  300 creates made 119 such splits.
.PP
.B "Splitting evenly instead."
The node count is still the greedy minimum, so evenness never costs a block;
the entries are then divided among that many nodes.  The capacity test stays
and is what makes it safe.  New shapes, and the count of splits over the same
300 creates:
.P1
49/97  45/90  45/89  45/90  58/116  45/89      17 splits, was 119
.P2
.PP
.B "What the two changes are worth, 300 creates on sdmem with delay 0."
.P1
arm                         total   first 50   last 50    read ops
as committed before         29.6 s      35        160       17014
+ packed navigation         14.9 s      18.4       75.1      17014
+ even split                 8.0 s      17.5       29.3       4504
.P2
3.7x together, and on the term that grows \(em the last fifty creates \(em
5.5x.  Reads fall 3.8x, which is the even split; the packed change moved no
reads at all and never claimed to.
.PP
.B "Note which fix was fundamental."
Packed navigation made each read cheaper.  The even split made there be fewer
of them, by removing the reason they multiplied.  B1a named the directory scan
as the cause and proposed a keyed lookup to avoid it; that is still a real
improvement and is still unbuilt, but it is no longer the first thing, because
the scan is now walking five leaves instead of thirty-four.
.PP
.NH 2
B1e.  DONE \(em a write no longer commits per message, and neither does a create
.LP
Every Styx Write used to commit.  A commit is a path rewrite plus the free
map plus the superblock, 7.8 blocks measured, so a file written in 8KB
messages paid 7.8 blocks of metadata for 2 blocks of data.  Copying this
board's own kernel image into efs \(em 2548632 bytes, 622 blocks \(em cost:
.P1
                     per-message    batched
time (sdmem, free)       8.55 s      4.46 s
write ops                 3253        2377
write sectors            26024       19016
disk touched              11.8 MB     9.4 MB
.P2
1.94x in time.  A write now leaves the transaction open and Clunk commits
it, bounded at 32 blocks so an open transaction cannot hold the free map
hostage; metadata operations still commit immediately.
.PP
.B "The contract is unchanged, and it was never per-operation."
.CW man/4/efs
promises that the image holds "exactly the last committed state", and it
still does \(em there is simply less of it after a crash in the middle of a
file nobody closed, which is what every filesystem means by writing.
.CW efs-crash ,
which fails every write in turn across a whole workload and requires the
image to mount holding exactly the last committed state with
.CW efsck
silent, passes.
.PP
.B "Only 1.37x fewer write operations, and the remainder is worth naming."
2377 writes for 622 data blocks is still 3.8 per block.  Subtracting the
data, 1755 writes over about 311 messages is 5.6 blocks a message, and that
is the copy-on-write path rewrite per extent insert: within ONE transaction
the same leaf and its ancestors are rewritten once per insert, because
nothing is overwritten in place.  Batching removed the per-commit part and
left that.
.PP
.B "Which is where a cache belongs, and it belongs INSIDE efs."
Holding dirty tree nodes in memory and writing them once at the commit
barrier would collapse those 5.6 blocks a message toward one.  It is safe
exactly because the barrier still orders everything: the blocks go down,
then the superblock.  A cache UNDER efs \(em
.CW dossrv 's
track cache, or a block cache in a driver \(em cannot do this, because it
does not know where the barrier is, and reordering across it is precisely
the failure G1b suspects on this board.  There is no
.CW cfs
in this tree to borrow;
.CW memfs (4)
is a heap filesystem with no backing store, not a cache.
.PP
.B "DONE: deferring the create commit too."
A create leaves a fid that 9P requires to be clunked, so the clunk could
commit it, and for the common
.CW "echo x > file"
that would halve the commits \(em the creates workload still pays two, one
for the Create and one for the Clunk, and batching the write changed
nothing there because an 8-byte write never reaches the bound.
.PP
It broke two suites.  BOTH are now answered: one was the test's fault, and the
other was a bug in
.CW Fs.commit
that the deferral exposed and did not cause.
.PP
.B "The 228 leaked blocks were not leaked.  The test encoded a commit count."
.CW efs-write
copied a 733-block file in, removed it, and then did "two more commits, so
every pendingfree list has been folded back in" \(em its own comment \(em
before counting blocks marked used.  Deferring the create changed how many
commits an operation costs, so two no longer sufficed and blocks still sitting
in
.CW pendingfree
read as marked.  Driven further:
.P1
before            5 marked
after 2 commits 233 marked      <- what the check looked at
after 4          15 marked
after 6          15 marked      <- settled
.P2
Nothing was leaking.  A test that encodes an implementation's commit frequency
fails the next change to it whichever direction the change goes, so the check
now does six operations and wants the count SETTLED rather than any particular
value.  It reports "5 blocks before, 15 after" with the deferral applied and
with it reverted, which is the point.
.PP
.B "The hang is real, and it is not a data bug."
.CW efs-stress 's
second arm printed
.CW "FATSTRESS-OK 3 rounds, 8 files each"
\(em the workload COMPLETED \(em and then
.CW emu
never exited, which this tree already records as the signature of a spawned
Dis process still blocked rather than of anything wrong with the filesystem.
.CW efs
spawns a navigator and tells it to stop with
.CW "navops <-= nil"
after its Styx loop ends, so a main loop that never reaches that line leaves a
process behind and
.CW emu
hangs.
.PP
.B "DIAGNOSED: it is a crash, and the cause is a data race between efs's two processes."
Tracing every message in and out of the Styx loop found it stopping inside
.CW remove() ,
and
.CW emu 's
own output had said why all along:
.P1
[Efs] Broken: pid 13066 "array bounds error"
.P2
The server process dies, nothing replies, and the client waits for a mount
whose server is gone \(em which is why it reads as a hang.  Reading the test's
stdout rather than
.CW emu 's
had hidden it.
.PP
The faulting site is
.CW Fs.nextleaf 's
leftmost descent:
.P1
for(c := d + 1; c < len blks; c++){
        ...
        blks[c+1] = fb;         # c can be the last index
.P2
On a BALANCED tree that cannot overrun, because the descent meets a leaf
before
.CW c
runs out \(em every leaf is at the same depth.  So the path it was handed no
longer described the tree.
.PP
.B "And the path goes stale because fs is shared with no mutual exclusion."
.CW serve()
spawns a navigator, and
.CW Styxserver.new
spawns a reader of its own, so
.CW walkto() ,
.CW dirof()
and
.CW readdir()
run in a DIFFERENT process from the loop that creates, writes and removes.
Both reach the same
.CW "ref Fs" ,
its node cache, its raw-block cache and its free map, with nothing between
them.  Dis is serialised here but it interleaves at instruction boundaries, so
a tree walk can be suspended half way and resumed after the tree has been
rewritten under it.  Deferring the create commit widens the window; it does not
create it.
.PP
.B "And the obvious fix is the wrong shape, which was worth finding out."
One token in a buffered channel, taken per Styx message and per Navop,
.I does
remove the crash \(em "Broken" stops appearing.  It then deadlocks, because
several arms of the Styx loop end in
.CW srv.default(m)
as their NORMAL path, and
.CW srv.default
answers Walk, Stat and Attach by sending a Navop to the navigator, which wants
the same token.
.CW Open 's
truncate arm is the first one hit, eleven messages in.  Releasing the token
around the one
.CW "* =>"
arm is not enough, because
.CW Open ,
.CW Read
and others call
.CW srv.default
too.
.PP
So the lock boundary cannot be the message loop: the library calls back into
the navigator from inside the handlers.
.PP
.B "CORRECTION: the race is NOT the cause, and locking every fs access proves it."
The brackets were moved off the message and onto the
.I fs work
instead \(em every arm of the Styx loop around only the calls that reach
.CW fs ,
every
.CW srv.default()
outside, the navigator's three handlers around
.CW dirof ,
.CW walkto
and the whole of
.CW readdir
(whose loop calls
.CW dirof
per entry).  Every
.CW "fs."
user in the file was enumerated and checked to be reachable only from a
bracket.  That deadlocks nowhere and it does not fix the crash: "Broken"
still appears.  So cross-process interleaving is not what invalidates the
path, and the entry above that said it was is wrong.
.PP
.B "The fault is located exactly, and the tree really is unbalanced."
A guard on the overrunning line prints before it would fault:
.P1
DBG nextleaf OVERRUN: c=1 len blks=2
.P2
A path of two \(em root and leaf \(em while the root's OTHER child, just
stepped to, is an interior node.  One child of the root a leaf and another
interior is an unbalanced tree, and
.CW nextleaf
is entitled to assume it is not.  With the guard returning 0 instead of
faulting the workload completes, but returning 0 means "no more leaves", which
would silently truncate a directory listing, so that is a diagnostic and not a
fix.
.PP
.B "And it took BOTH the even split and the deferred create commit."
.P1
even split, create commits (as shipped)   clean, efsck clean, rc=0
even split, create deferred               OVERRUN
greedy split, create deferred             clean, rc=0
.P2
Neither change is wrong by itself.  Even splitting makes the tree shallower
(17 splits against 119), and a shallower tree is where a path of two exists at
all; batching the commit is what let a transaction end without an operation
following it.  The combination exposed a third thing, which is what was
actually broken.
.PP
.B "CAUSE: a commit with no free map in memory wrote zeroes over the live one."
.CW Fs.commit
read
.CW "ng := len f.bmindex"
and assumed a transaction was open.  When it was not,
.CW ng
was 0, so the fixpoint considered no group, the write loop wrote no group
block, and the all-zero
.CW idx
array went to
.CW "f.putblk(f.idxblk, idx)"
\(em over the free map index the mounted filesystem was using, because commit
never cleared
.CW f.idxblk .
The next transaction read that back, took every group's block to be 0, and
read BLOCK 0, a superblock, as the bitmap.  Almost every bit in a superblock
is clear, so the allocator began handing out blocks that were already in the
tree.
.PP
That is the whole of the unbalanced tree.  A live leaf was handed out and
rewritten as an interior node while its parent still pointed at it as a leaf,
so one child of the root was interior and its siblings were leaves.
.CW pathto
stops at the first block that says leaf, so paths of two different lengths
both existed, and
.CW Fs.nextleaf
walked off the end of the shorter one.
.PP
.B "Exactly one state reaches it, which is why it took the two changes above."
A commit whose freed list does not fit in the superblock \(em 504 blocks, hit
by removing a file of about 2MB \(em sets
.CW f.dirty
from the carried remainder while leaving
.CW f.bmindex
nil.  The NEXT commit then runs with no map.  Before writes were batched there
was always an operation between two commits and an operation opens a
transaction, so the state was unreachable; batching removed the accident that
was hiding it.
.PP
So
.CW Fs.commit
opens the transaction itself, and clears
.CW f.idxblk
so a published index can never be rewritten in place.
.PP
.B "How it was found, because two rounds of reasoning got it wrong first."
Recording every block's whole history \(em alloc, free, write with its node
type, and the pendingfree unmark \(em and reading out the offending child's:
.P1
HIST 865: alloc@36 wrINT@36 free@36 unmark@37
          alloc@145 wrLEAF@145
          alloc@205 wrINT@205
.P2
Allocated at 145, written as a leaf, never freed, and allocated AGAIN at 205.
That is a double allocation and nothing about tree shape, which is where two
sessions of looking at
.CW fixup
and
.CW idx[depth]
had been aimed.  A per-transaction check that every block the tree reaches is
marked used then named the exact generation, and a trace of what each commit
published named the one before it:
.CW "npend 504" .
.PP
.B "This also answers the cleared bit that B1 left open."
The entry below says
.CW mkefs
marks block 0 and block nblocks-1 used, so "a bit is being cleared somewhere,
and that is still open".  This is it: a zero index block makes the allocator
read a superblock as the map, in which nearly every bit including those two is
clear.  It explains the "interior block 4095: interior entry 0 is not a
pointer" that started that line of enquiry, and G1's "block 16383 is in the
tree and free in the map" on this board's image.  The guard in
.CW Fs.alloc
stays: an invariant that matters should not depend on a bit.
.PP
.B "Deferring alone bought nothing, which measuring said and arithmetic did not."
.CW "echo x > f"
clunks two fids \(em the directory walked to and the file created \(em and a
clunk committed whenever the filesystem was dirty, so deferring moved the
commit from Create to the other clunk and left the count at two per file.
Sixty files cost generation 122 either way;
.CW efsck 's
generation counts commits exactly and is medium-independent, which is why this
was visible at all without a board.  A clunk now commits when THAT fid dirtied
something, or when no fid is holding a dirty change: 60 files cost generation
62, 300 cost 302.  One commit per file.
.PP
.B "Two more bugs, both mine, found on the way."
.CW Fs.rawblk
\(em the raw-block cache B1c added \(em had no invalidation at all.  Every
write went straight to
.CW f.d.wrblk
and left the stale copy behind, and a copy-on-write filesystem changes the
bytes behind a block number constantly.  Writes now go through
.CW Fs.putblk ,
write-through rather than invalidating, because a block just written is the one
most likely to be read next.
.PP
And B1c's packed navigation decided leaf-or-interior from byte 0 with no
verification, where the code it replaced decided it from
.CW Node.unpack ,
which checks the checksum first.
.CW Nleaf
is 0, so a block of zeros read as a leaf.  Verified now in
.CW Fs.rawblk ,
and WHERE matters \(em 300 creates, host, 302 commits in every arm:
.P1
no verification                     2.41 s  2.39 s
verified in Fs.rawblk               3.13 s  3.12 s   1.30x
verified in each navigator          4.56 s  4.56 s   1.90x
.P2
B1c's whole win was 1.98x, so checking once per block TOUCHED gave almost all
of it back; once per block READ costs 1.30x, which is the price of a filesystem
actually checking the checksum it stores and is worth paying while G1b's
corruption has no cause.
.PP
.B "And efsck did not check the B-tree invariant."
It checked that the tree was no deeper than 16 and nothing about its shape, so
an unbalanced tree passed it clean \(em which is why "efsck: clean, generation
285" above had not contradicted any of this.  It now requires every leaf to be
at the same depth.
.PP
.B "Verified on the host."
All ten efs suites pass, and
.CW "fatstress -n 4 -f 12 -s 8" ,
which crashed the server reproducibly, finishes with
.CW efsck
clean including the new check.
.PP
.B "And ON THE BOARD, against the previous commit, both arms in one boot."
.CW sdmem (3)
with the previous commit's three
.CW .dis
bound over
.CW /dis
for arm A, so the only difference is the library.  Four cores online with the
work on core 0, the Dis JIT on.  300 creates into one directory, free medium:
.P1
                    A: 3dfb88270   B: this commit
commits (generation)      602            302
read ops                 4253           3084
read sectors            34024          24672
write ops                4402           3502
write sectors           35216          28016
disk touched            15.2 MB        12.8 MB
time                    38.9 s         38.3 s
.P2
The commits are exactly halved, which is what the dirty-fid rule set out to
do, and the transfers fall 24% with it.  The TIME IS UNCHANGED, and that is
the expected answer rather than a disappointment: the medium is free in that
arm, so operations it does not have to issue cost it nothing.
.PP
.B "With a card-like latency put back, 1.28x."
The same A/B at
.CW "delay 10000" ,
10ms a transfer, 150 creates:
.P1
                    A             B
transfers           4141          3122
time                68.25 s       53.38 s
.P2
Faster in every one of the three rounds, no overlap.  1019 fewer transfers at
a calibrated ~11ms is 11.2s of the 14.9s saved; the remaining 3.7s is the CPU
the extra 300 commits cost in free-map scanning and superblock packing.  So
the operation count is the thing, and
.CW sdmem 's
.CW delay
is what turns it back into time without needing the card.
.PP
.B "What is NOT verified."
Nothing has run on the real SD card, only on
.CW sdmem .
And the commit on hangup is a backstop that no harness here exercises \(em
dropping a local mount makes the kernel clunk every fid first, so the clunk
path always runs, and a connection severed under a client that still holds a
fid is a case this tree cannot produce.  The control says so: removing the
hangup commit again leaves the test passing.
.NH 2
B1f.  DONE \(em a cache for efs: dirty tree nodes, written once at the barrier
.LP
B1e leaves the write path at 2377 writes for 622 blocks of file.  The floor
is 622.  The 1755 in between are 5.6 blocks a message of copy-on-write path
rewrite: within one transaction the same leaf and its ancestors are rewritten
once per insert, because nothing is overwritten in place.  A cache that holds
those nodes and writes each once should reach about 800 \(em a further 3x, and
the last large one available.
.PP
.B "The crux is that deferring the WRITE means deferring the ALLOCATION."
Under copy on write each rewrite gets a new block.  Defer the write but keep
allocating per rewrite and you allocate N blocks, write one, and leak N-1 \(em
which is exactly the shape of the 228 leaked blocks B1e reverted.  So a dirty
node must have
.I no block number at all
until it is flushed.
.PP
.B "Which gives the key: the committed block number it was read from."
A node read from block B and modified twice is ONE dirty entry, named B.  At
flush it is allocated one new block, written once, and B goes to
.CW pendingfree
\(em the rule that a block freed by a commit is not allocatable until the
commit after it is untouched, and so is the rule that no committed block is
ever overwritten.  A dirty node that has never been allocated is not a
committed block, so holding it in memory is consistent with the format rather
than an exception to it.
.PP
.B "Flush is bottom-up, and it is today's fixup run once."
Children are allocated and written first; their new numbers are patched into
their parents; parents are written; up to the root, then the free map, then
the superblock.  That is the same order
.CW Fs.commit
already documents \(em blocks, barrier, superblock \(em with the tree written
in one ordered pass instead of once per insert.  The barrier is not weakened
by this; it is the thing that makes it safe.
.PP
.B "The reserve has to grow, and getting that wrong is a known wedge."
.CW Fs.reserve()
is min(nblocks/8, 24) and
.CW Nreserve
is documented as covering "one path rewrite (Maxdepth) and the group and index
blocks a commit needs".  With writeback a commit writes the WHOLE dirty set at
once, so the reserve must cover that set and not one path: the Wbatch bound of
32 blocks, the tree blocks that bound implies, and the map.  Too small and a
commit fails for want of space on a filesystem that had room, which is the
full-filesystem wedge this plan has already fixed once.
.PP
.B "It does not touch reads, which are already cached."
.CW getnode 's
decoded cache and the raw-block cache under it handle repeats inside a
transaction; reads were 1724 of the 4101 operations in the kernel-image write.
A read cache is not the missing piece.
.PP
.B "And it must be INSIDE efs."
A cache below \(em
.CW dossrv 's
track cache, a block cache in a driver \(em cannot do this, because it does
not know where the barrier is, and reordering across it is precisely what G1b
suspects of this board.  There is no
.CW cfs
in this tree to borrow, and
.CW memfs (4)
is a heap filesystem with no backing store rather than a cache.
.PP
.B "What must guard it, named in advance."
.CW efs-crash ,
for the invariant.  But the test that matters more here is
.CW efs-write 's
block-leak check \(em "5 blocks in use before, 233 after" \(em because
deferred allocation is exactly the bug class it detects, and it is what caught
the create deferral.  Then the
.CW sdmem
counters for the win, against the 2377 above.
.PP
.B "Approach it expecting to be wrong."
A far smaller change to commit timing \(em deferring one commit from Create to
Clunk \(em produced 228 leaked blocks and a hang that are still unexplained.
This is a larger change in the same place.  The leak check and the crash
harness should be run at every step and not at the end.
.PP
.B "BUILT, and it does what the design above said it would."
A dirty node is named by
.CW "Pseudo + its slot" ,
a number above every real block, which goes into its parent's entry exactly as
a real one would.
.CW Fs.rawblk
serves it from memory,
.CW Fs.dnew
holds it,
.CW Fs.free
of a pseudo-number DROPS it rather than listing it on
.CW pendingfree
\(em which is what makes a node rewritten twice cost one block and not two, and
why nothing leaks \(em and
.CW Fs.flush
turns the tree into real blocks at the commit barrier, children first,
recomputing each parent's checksum as the children's numbers are patched in.
.PP
.B "Measured on the board, through sdmem (3), both arms in one boot."
The kernel image into efs: 2548984 bytes, 622 blocks of file.
.P1
                  before      after
write ops          2374        744     3.19x
read ops           1726         96     18.0x
write sectors     18992       5952
disk touched      9436 KB    2916 KB
time, free        14.84 s    12.40 s
time, delay 10ms  61.65 s    22.09 s   2.79x
.P2
The design predicted "about 800" writes against a floor of 622.  744.  And the
read collapse was not predicted at all: a node rewritten inside a transaction
used to be read back from the medium, and now it never left memory.
.PP
2916KB to hold 2488KB of file is 1.17x write amplification, against 3.79x
before.  On the charging medium the 3260 transfers not issued account for
39.6s of the 39.6s saved, 12.1ms each, which matches
.CW sdmem 's
calibration \(em so this is the operation count and nothing else.
.PP
.B "And the create path, which the design did not aim at."
300 creates into one directory, same board, same boot:
.P1
                  before      after
read ops           3084       1643     1.88x
write ops          3502       2057     1.70x
disk touched      12.8 MB    7.0 MB
commits (gen)       302        302
time, free         38.3 s     35.3 s
.P2
The commit count is unchanged, correctly: how many commits there are is the
clunk rule from B1e, and what each one costs is this.  Per-round cost stays
flat, 5.79s to 5.64s across six rounds of fifty.
.PP
.B "The reserve had to grow, which the design said and the tests proved."
.CW Fs.reserve
was min(nblocks/8, 24), covering one path rewrite and the map.  A commit now
writes the whole dirty set at once, so it is at least
.CW "ndirty + Maxdepth + ngroups + 1" ,
which grows with the transaction \(em and that is wanted:
.CW room()
then refuses new work while a large uncommitted set is outstanding, and
.CW Fs.commit
never consults
.CW room() .
.PP
.B "TWO TESTS FAILED, and both were the tests."
This is the third time in this plan that a filesystem improvement broke a
check that had encoded the implementation's cost, so it is worth naming as a
pattern rather than an accident.
.PP
.CW efs-groups
puts the allocator's cursor at 32760 and requires the write to land blocks
above 32768, which is the only test that makes a commit dirty two groups at
once.  Its file was 20000 bytes \(em 5 blocks \(em and it crossed the boundary
only because the path rewrite allocated several more blocks per write message
on top of them.  Remove those and the write no longer reaches 32768, and the
check failed on a change that made the filesystem better.  The file is 100000
bytes now, 25 blocks against the 8 left below the cursor, so the crossing is a
property of the workload.
.PP
.CW efs-limits
fills a 4MiB filesystem until a create fails.  It filled with a REDIRECT, and
a failing redirect is not catchable in this shell \(em it raises and the whole
script ends, so the FULL-AT line never printed and nothing after the loop ran.
That worked by accident while a full filesystem refused at the WRITE, which
.CW echo
reports as a failed command; the larger reserve makes it refuse at the CREATE,
which is the better behaviour, and the failure became a redirect failure.  The
loop uses
.CW cp
now, which is what the comment twenty lines below it already said and which
that comment's own arm had been fixed to do.
.PP
It also filled to 921 files where it filled to 515, which is the space side of
the same win.
.PP
.B "A SLOT HAS TO GO BACK, and the bound was bounding the wrong thing."
The first version never reused a dirty slot, on the ground that
.CW getnode
caches decoded nodes by number and a reused number would hand back the wrong
node.  True, and it made
.CW Maxdirty
count nodes WRITTEN rather than nodes HELD \(em and removing a file is one
transaction that rewrites a leaf and its ancestors once per extent key while
never holding more than a handful of them.  Removing a 12MB file made about
6000 of them and failed:
.P1
rm: /n/client/big: more than 4096 dirty tree nodes in one transaction
.P2
and the half-done removal left the image with
.CW "block 2410 is in the tree and free in the map" .
A removal that had always worked.  So
.CW Fs.ddrop
puts the slot back and evicts the number from the decoded cache first, which
is the whole of what made reuse unsafe;
.CW ndirty
is a maintained counter rather than a scan, because
.CW room()
asks for it on every create and every write.
.PP
.B "Which found a leak that predates all of this: a carried freed list is MEMORY."
A commit whose freed list does not fit in one superblock puts 504 blocks on
.CW pendingfree
and carries the remainder on
.CW f.freed
for the next commit.  That is safe in the direction it was argued for \(em a
carried block is still marked used, so nothing hands it out \(em and it says
nothing about a server that EXITS still holding one.  Removing that 12MB file
freed about 3000 blocks, one commit took 504, and the unmount threw the other
2117 away, permanently.
.PP
.CW efsck
reported them as "marked used and not reached (pendingfree keeps some; not an
error)".  That message is why it was invisible: pendingfree does keep some,
and 2117 is not some.
.PP
.CW Fs.commit
drains the list before it returns now \(em each round folds in the previous
round's pendingfree and takes the next 504, so the list strictly shrinks \(em
and 2117 blocks became 109, which is the last commit's own pendingfree and
becomes free at the next transaction.
.PP
.B "And efs-write could not see it, because it measured in the same session."
Its big-remove check does twelve operations after the removal, which is enough
commits to fold every carried block back in, so the arm that exists for
exactly this leak drained it before looking.  A second arm removes a 12MB file
and lets the server EXIT at once.  Control, with the drain removed again: "5
before, 1979 after \(em 1974 carried blocks were lost".  With it: 473, one
commit's worth.
.PP
.B "Verified."
All ten efs suites pass, including
.CW efs-crash
(every write refused in turn, the image required to mount holding exactly the
last committed state with
.CW efsck
silent) and
.CW efs-write 's
block-leak check, which the design named in advance as the one that matters
because deferred allocation is the bug class it detects.
.CW "fatstress -n 4 -f 12 -s 8"
stays clean.  On the board \(em same state as B1e above, four cores with the
work on core 0, the JIT on, both arms in one boot \(em the image copies back
byte-for-byte with
.CW cmp
in both arms and
.CW efsck
is clean in arm B.  Arm A's
.CW efsck
did not run: it failed to load the library through the bind, unexplained, and
the comparison rests on
.CW cmp
in both arms and on arm A being the code already shipped.
.NH 2
B1d.  DONE \(em the keyed lookup, and the silent data loss it uncovered
.LP
.CW walkto() ,
.CW create()
and the rename in
.CW wstat()
read a whole directory to answer a question about one name.  They now do one
descent:
.CW dlook() ,
which reads
.CW "Key(dir, Kdentry, namehash(name))" .
.CW adddentry()
had always built the key that way; nothing used it.
.PP
.B "And B1a's premise about collisions was wrong, in the direction that loses files."
.CW create() 's
comment said "a second dentry with the same name hashes to the same key and a
bucket holds collisions \(em so the check has to be here".  There is no bucket.
.CW Fs.replace ,
given a key it already holds,
.I replaces
it.  So a create whose name hashed onto an existing DIFFERENT name passed the
scan \(em which compares names, and the names differ \(em reached
.CW fs.insert ,
and silently replaced that file's directory entry.  The file left the
directory with no error and its inode and blocks leaked.
.PP
.B Demonstrated, not reasoned.
With
.CW namehash
narrowed to 8 bits so a collision is reachable, creating
.CW b
then
.CW ga
\(em both hash to 165 \(em left only
.CW ga ,
and
.CW "cat b"
said the file did not exist.  With the fix the second create is refused,
.P1
cannot open /n/client/d/ga: name hash collision with 'b';
    efs holds one entry per key
.P2
and
.CW b
is still listed and still reads
.CW first .
At the real 63 bits a directory needs of the order of 2**31 names for this to
be likely, which is why it had never been seen; silent is still silent.
.PP
Refusing is the only honest answer while one key holds one entry.  Making
colliding names work needs a format that chains them, which is a version bump
and not this.
.PP
.B "What the three changes are worth together."
300 creates on
.CW sdmem
with
.CW "delay 0" :
.P1
arm                      total   first 50   last 50   read ops
as committed before      29.6 s      35        160       17014
+ packed navigation      14.9 s      18.4       75.1      17014
+ even split              8.0 s      17.5       29.3       4504
+ keyed lookup           7.06 s      17.2       22.1       4255
.P2
4.2x in total and 7.2x on the term that grew.  The keyed lookup is only 12 per
cent of the time by itself, because the even split had already reduced a
directory to about five leaves and a scan of five leaves is cheap \(em but it
removes the last term that grows WITH the directory, which is the difference
between fast at three hundred files and fast at thirty thousand.  The per-create
figures are now flat.
.PP
.B "Not converted, and why."
.CW deldentry(dir, ino)
searches by inode: its two callers, remove and rename, know the inode and not
the name.  It keeps the scan.  Both are far rarer than a walk, which happens on
every path element of every operation.

.NH 2
B2.  DONE.  One namehash, in the library
.LP
Checked before moving, which the plan did not ask for and should have: the two
copies were
.I identical ,
so this was latent rather than a live bug on the card.  Moved to
.CW Efs->namehash
in
.CW appl/lib/efs.b ,
declared in
.CW module/efs.m
with the reason recorded beside it, called from both commands.
.CW 2d273290f .
.PP
Verified by the whole suite, and by the one path no suite covers:
.CW "mkefs -n 256 -a payload"
then mounting that image and reading
.CW /n/client/payload
.I "by name" ,
which returns its contents \(em so the hash
.CW mkefs
wrote and the hash the server looks up are the same one.  That is the check
that matters, because a divergence would leave
.CW ls
listing a name that could never be opened.
.NH 2
B3.  CLOSED.  efs-limits passes
.LP
.CW EFS-LIMITS-OK ,
and the arm had
.I four
bugs of which only one was memory.
.CW 5fa815638 ,
.CW c406dfee5 .
.PP
Inferno's
.CW sh
has no
.CW break
builtin.  The loop said
.CW break
on the first failed write, sh looked for
.CW ./break ,
and raised \(em which aborted the script, so the write-when-full, the unmount,
the remount and the efsck never ran.  The transcript had been saying it all
along:
.CW "sh: break: './break' file does not exist" .
A failing redirect is not catchable either, so
.CW "or {and {echo x > f} {...}} {...}"
ends the script rather than taking a branch;
.CW cp
raises
.CW fail:*
and
.CW or
catches it.  And
.CW /n/client2
did not exist, because everything under
.CW n/
here is untracked, so the remount failed for that and the verdict called it efs.
.PP
The memory was real and is fixed by the two changes above.  What the arm reports
now: 515 files into a 4MiB filesystem,
.CW REFUSES-AFTER-FULL ,
.CW REMOUNTED ,
.CW CKCLEAN .
.NH 1
C.  The rig
.NH 2
C1.  DONE.  alive and where lied about a kernel from another build
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
D1.  DONE.  They are generated, and are now ignored
.LP
.CW libinterp/mkfile
builds every file in them, down to the
.CW mkdir :
.P1
$DISH/runt.h:D: $MODULES
	mkdir -p $DISH && rm -f $target && \
	limbo -W $DISWORD -a -I../module ../module/runt.m > $target
.P2
and nine more rules like it, with
.CW DISH=w$DISWORD .
They are the C shape of a Dis frame, which depends on the word width, so there
is one directory per width and each board's CFLAGS point at the one it needs.
Nothing is tracked in either.  Ignored as
.CW libinterp/w[0-9]/ .
.PP
Untracked and load-bearing was the worry, and it is a real one \(em a fresh clone
has no
.CW w8
until something runs
.CW mk
in
.CW libinterp
\(em but the answer is the ignore and not committing them, because the rule makes
them before anything includes them.  The same applies to the acid symbol files a
kernel build writes beside each kernel, ignored in the same change as
.CW os/inferno/*/i*.acid ;
only
.CW i* ,
because
.CW emu/9front/emu.acid
and
.CW os/inferno/pc/pci.acid
are hand-written and tracked.
.NH 2
D2.  DONE.  The bind-create section was two bugs, and both are closed
.LP
.CW doc/raspi3b-completion-plan.ms
carried a long section on creates through a
.CW bind
of the
.CW efs
mount failing silently and poisoning the name.  It was two separate things, and
neither is open.
.PP
The silent, durable half was the
.CW big
literal bug: about half of all names hashed negative, so a create reported
success and the file could never be found again.  Fixed in
.CW 04d84c28c
and
.CW dcca478dd ,
and the names that had been "poisoned" \(em
.CW wprobe ,
.CW inferno ,
.CW zzz ,
.CW abc ,
.CW ab1 ,
.CW second
\(em all create and list now.
.PP
The other half is a namespace rule working exactly as intended, measured on the
fixed kernel:
.P1
bind    /n/efs/d2 /n/efscrash   create -> cannot create: mounted
                                 directory forbids creation
bind -c /n/efs/d2 /n/efscrash   create -> OK
                                 and the name that just failed -> OK
.P2
Loud, not silent, and no poisoning: the name that was refused through the
.CW -c -less
bind succeeds through the
.CW -c
one, in the same command.  The host said the same thing all along, which is
recorded in
.CW bc90d99e6 ;
the board now agrees.
.PP
What is left of that section is one sentence: a create through a bind made
without
.CW -c
is refused by the namespace, correctly and with a message, and everything else
attributed to it was the VM.
.NH 1
E.  A retention leak found and fixed, and four places it is not
.NH 2
E1.  FIXED.  remove() pruned neither name cache
.LP
.CW disk/efs.b
keeps two caches keyed by inode:
.CW names
for
.CW nameof() ,
.CW parents
for
.CW parentof() .
.CW forget()
prunes
.CW names
and was called from exactly one place \(em
.CW wstat() ,
the rename path \(em and
.CW parents
had no counterpart at all.
.CW remove()
pruned neither.  Since
.CW nextino
only increments, an entry for a deleted inode can never match again: it is dead
weight for the filesystem's whole life, and with 64 buckets the chains that
.CW remember() ,
.CW nameof()
and
.CW parentof()
walk on every operation grow with it.  Fixed in
.CW 42b807c42 .
.PP
Live heap blocks after each of four cycles of 60 creates and 60 removes:
.P1
before   2385  2568  3365  3990     monotonic, +1605 over 240 files
after    2116  2282  2621  2401     no trend
after    2100  2554  2228  2146     again
.P2
About 6.7 blocks per file created and removed.
.NH 2
E2.  And the noise band, which matters more than the four negatives
.LP
The same instrument was pointed at four other operation mixes.  Directory
create-and-remove looked like a second leak:
.P1
dir-1 2147   dir-2 2458   dir-3 2546
.P2
monotonic over three cycles, with the directory verified
.I empty
after each one \(em so not accumulated state.  Run eight times instead:
.P1
2074  1791  1908  1899  2089  1779  2071  2108
.P2
No trend.  It oscillates around 1950 by about 170 either way, and three samples
inside that band happened to rise.  There is no directory leak.
.PP
So the band is +-170 live blocks for this test, and that is the number to beat
before believing anything measured with it.  E1's signal was +1605, about nine
times it, which is why that one is real; and the fixed runs sit inside the band.
.PP
Flat, with no retention found: renaming (1996, 2166, 2008), truncating by
rewrite (2241, 2511, 2427) and walking a directory (2057, 2055, 2071) \(em the
last being the tightest, which is what one expects of a read-only operation.
.NH 2
B1b.  The collector's trigger (and a conclusion B1c overturns)
.LP
.B "Two facts about the VM, both read from the source."
.CW emu/port/dis.c 's
.CW vmachine()
collects when
.P1
if(curP->runhd != nil)
if((++gccounter&0xFF) == 0 || memlow()) { ... rungc(isched.head); ... }
.P2
so the periodic trigger counts
.I scheduler passes ,
not allocation, and
.CW memlow()
is
.CW "heapmem->cursize > heapmem->maxsize/2" .
The guard is harmless \(em a running process stays on the queue, rotated rather
than dequeued, so
.CW runhd
is non-nil whenever anything is runnable.
.PP
And nothing collects when an allocation
.I fails .
.CW nheap() ,
.CW heap()
and
.CW heapz()
all read
.P1
h = poolalloc(heapmem, sizeof(Heap)+n);
if(h == nil)
	error(exHeap);
.P2
and
.CW dopoolalloc
returns nil without attempting any reclaim.  So a program dies rather than
collecting once more and retrying.
.PP
.B "Why that is not a two-line fix."
Collecting from inside
.CW heap()
would call the collector from an arbitrary point in the mutator, which is
precisely what the quantum-boundary discipline exists to avoid: the collector
wants a root set it can trust, and
.CW rungc 's
own invariant check \(em the one that reports "context %d has a quantum" \(em is
there because of it.  The safe shape is to make the
.I trigger
allocation-driven while keeping the collection points where they are: count
allocations, and fire at the next quantum boundary when the count since the last
collection passes a threshold.
.PP
.B "But the pacing is not the whole story, and this is the correction."
The first
.CW efs-limits
run of this session recorded
.P1
arena heap too large: size 128 maxsize 268435456 ressize 267911168
                      cursize 268304384
.P2
\(em the pool at 268MB of 268MB.  Past 134MB
.CW memlow()
is true at every quantum, so the collector was running constantly and still
could not keep the pool down.  At the moment of failure the live set really was
that large.  So the out-of-memory is
.I retention ,
not allocation rate, and the 40 per cent cut in rate
.CW ( 3d09ea990 )
does not address it \(em which is exactly why the fill arm still fails while the
rate numbers improved.
.PP
.B "So B1 is two problems, and the second is the one that OOMs."
The rate is measured and partly fixed.  The retention is not found: an early
measurement put live blocks at 558751 after 300 creates, about 1862 per file,
and the only per-live-file state identified so far is the
.CW names
and
.CW parents
entries \(em two tuples and two list cells, call it four allocations.  Three
orders of magnitude unaccounted for.
.PP
.B "And the instrument for it is the one that has worked twice."
Not
.CW nalloc
per operation, which measures rate.  Live blocks
.CW ( nalloc-nfree )
sampled per
.I created file ,
against a control that creates nothing, with the +-170 noise band from E2 in
mind \(em and then a counter on the work, tagged with the caller, once there is a
number to attribute.  The cycle test in E1 found its leak that way in one
afternoon; this is the same shape of question.
.PP
.B "And a check that nearly cost the slice fix."
.CW mprof -2
after 300
.I creates
\(em profiling the creates rather than rewrites, which is where the retention
happens \(em attributes most of it to
.CW efs.b:777 ,
the line after
.CW getnode
inside
.CW Fs.nextleaf :
73.5MB with the slice change against 55.9MB without.  Read alone that says the
change made retention worse, which would matter, because the retention is what
runs the heap out.  The mechanism was even plausible:
.CW Fs.range
keeps
.CW Ent
values, and with slicing each one's
.CW val
pins the whole 4096-byte block it came from.
.PP
It is not what happened.  The per-line figures are not additive \(em
.CW mprof
attributes a callee's allocations to the line after the call, so
.CW nextleaf 's
and
.CW unpack 's
overlap and summing them double-counts \(em and the pool-level numbers after the
same 300 creates say the opposite:
.P1
              cursize      hiwat       live blocks
without     202816256   240359424         876206
with        203327616   224801536         688848
.P2
Same current size, peak 6.5 per cent lower, 21 per cent fewer live blocks.  The
change is good on count and on peak, and the per-line reading was the wrong
instrument for the question.  Three for three: every time a per-line or
per-call-site figure has been compared against a pool-level one in this
investigation, the per-line one has been the misleading half.
.NH 2
B1c.  SOLVED: there was never any retention, and the fix is the collector
.LP
.B "The measurement that settles it."
Sample the pool immediately after 300 creates, then let the machine idle:
.P1
                          cursize     live blocks
before any creates         191360             913
immediately after 300   199905792          677406
after 10s idle             347264            2019
after 30s idle             318720            1873
.P2
200MB collapses to 347KB.  300 files cost about 1100 live blocks in total, 3.7
per file, which is the
.CW names
and
.CW parents
entries and nothing else.
.PP
.B "So every retention figure in these notes was garbage, counted as live."
.CW nalloc-nfree
is
.I allocated and not yet freed ,
which is live
.I plus
whatever the collector has not reached.  The early reading of "558751 live
blocks after 300 creates, about 1862 per file" was uncollected garbage, and it
sent this investigation looking for a leak that does not exist \(em twice.
.PP
.B "And the collector was being asked, and not answering."
From
.CW /dev/memgc
.CW ( "bind '#%' /dev" ,
which is where the counters live \(em there is no
.CW /dev/memheap
in this emu):
.P1
allocations     1143908
rungc calls       29176    14698 of them from the busy path
sweeps              327
epochs               63
.P2
Called constantly, since
.CW memlow()
is true at every quantum past half the heap, and progressing barely, because
.CW rungc()
is incremental and the busy path called it
.I once
per trigger.
.CW execatidle()
had always looped a full
.CW gccolor+3
cycle;
.CW 5fa815638
does the same when there is no idle to wait for.  Pool peak 212MB to 181MB,
busy entries 14698 to 525, and no slower.
.PP
.B "What is left of B1."
Nothing that OOMs.  The allocation
.I rate
still grows with filesystem size \(em 306, 858, 1203 per operation at 2, 62 and
242 entries after
.CW 3d09ea990
\(em and that is a throughput matter now rather than a correctness one, because
the garbage it makes is collected.  Whether to chase the remaining growth is a
judgement about speed, not about whether the board can hold files.
.NH 2
F1.  CLOSED \(em the kernel does not need it, measured on silicon
.LP
.CW 5fa815638
fixed
.CW emu 's
busy-path collection to run a full cycle under pressure.
.CW os/inferno/port/dis.c
has the identical shape \(em
.CW rungc(isched.head)
once per trigger, against an
.CW execatidle()
that loops a whole
.CW gccolor+3
cycle \(em and was deliberately left alone, because the kernel's version runs
inside
.CW stoptheworld() :
a full cycle there holds all four processors, not one scheduler.
.PP
This item asked two questions before changing anything: what
.CW gcmax
is on the board, and whether the board exhibits the symptom at all.  Both are
now answered, and the answer is that the change would be dead code here.
.PP
.B "The board does not come close to the trigger."
Read from
.CW /dev/memory
on a Pi 3B up for 98 minutes, and again after driving it:
.P1
heap  cursize    maxsize     hw        nalloc
      1 194 880  52 136 345  1 467 264  2 217 540   (98 min idle-ish)
      1 338 752  52 136 345  2 357 760 20 192 090   (after the runs below)
.P2
A high-water mark of 2.36MB against a 50MB pool is 4.5 per cent.  The kernel's
predicate is not
.CW emu 's
.CW memlow()
\(em there is no
.CW memlow()
kernel side \(em but
.CW memusehigh() ,
which is
.CW "cursize > ressize"
with
.CW ressize
set by
.CW poolsize()
to
.CW maxsize-RESERVED .
That is a far later trigger than
.CW maxsize/2 ,
and the board reaches neither.
.PP
.B "Nor can a workload drive it there."
Two shapes, both on silicon:
.IP "\(bu" 3
.B "I/O bound, the shape that caused the hosted failure."
Ten file creates into the board's own
.CW /n/efs
cost 695 060 heap allocations in about 70 seconds \(em roughly 70 000
allocations per create \(em and
.CW cursize
went from 1 321 088 to 1 325 184.  Flat.
.IP "\(bu" 3
.B "Compute bound, which is the harder case."
.CW "disbench -n 2000 string"
did 4 002 010 heap allocations in 21.07 seconds \(em 190 000 per second, no
I/O at all \(em and
.CW cursize
was
.I byte-identical
before and after, 1 338 752 both times.
.PP
The reason is not that the collector is clever: it is that the board is slow
enough that even the throttled one-increment busy path, gated on
.CW "(++gccounter & 0xFF) == 0" ,
has enormous slack.  A create takes about 7 seconds of SD I/O.  What defeated
.CW emu
was host speed outrunning one increment per trigger; nothing on this board
outruns it.
.PP
.B "And gcmax is below the measuring floor."
.CW "echo sched >/dev/sysctl"
reports
.CW "gc 39/23636 max 1" :
23 636 busy-path passes, 39 ticks in total, worst single pass one tick.  Taking
.CW emu 's
change would triple the work inside
.CW stoptheworld()
to buy nothing, on a predicate that never fires.
.PP
.B "A caveat on that figure, which is why it had to be fixed first."
.CW gcmax
and
.CW idlegcmax
were among the counters broken by
.CW m->ticks
being per-processor; the figures above are from the kernel with
.CW gticks()
in it.  The pre-fix board reported
.CW "idlegc 4275348120 max 4294967257" ,
which is \-39.  An instrument this item depends on was lying, and F1 could not
honestly have been answered against it.  That is now a separate landed change,
and it is the only part of F1 that produced code.
.PP
.B "What would reopen this."
A faster board, a smaller heap cap, or a workload that generates
.I collector
garbage \(em not refcount garbage \(em faster than the throttled path can
sweep it.  The
.CW string
figure above does not test that: those strings are freed by reference count on
the spot and never reach the collector.  The efs arm does, and it was flat.  If
any of those three changes, re-read
.CW gcmax
and
.CW cursize
before touching
.CW os/inferno/port/dis.c ,
because the thing that makes the change safe on a host is exactly what makes it
expensive in a kernel.
.NH 1
Found while closing F1, not part of it
.NH 2
G1.  CLOSED as a failure \(em efs can commit a superblock whose tree is not all on the medium
.LP
.B "CLOSED as a failure, not as a cause."
Both symptoms below are now PRODUCED ON DEMAND, by
.CW sdmem (3)'s
injected faults, and both are caught at mount with the fallback reached:
.P1
node checksum 1000 1, want 0 0      a lost tree write
                                    reorder 8 partial 1 stop 40
                                    caught: "has no tree"; falls back

block N is in the tree and         a map older than its tree
free in the map                     reorder 8 partial 1 stop 130
                                    caught by spineok's bit check;
                                    falls back
.P2
The second needed a new check and is written up in G1a; the hypothesis about
.CW dossrv
below is refuted and is written up in G1b.  What remains unestablished is why
the BOARD's image came to be that way, and the answer is now narrowed to the
card's own volatile cache or to the confound this item already names.
.PP
.B "The original report, kept because the arithmetic in it is what made the rest possible."
The board's
.CW /n/dos/efs.img
would not mount:
.P1
efs: /n/dos/efs.img: 16384 blocks, generation 978 from superblock 1
efs: mount /n/efs: node checksum 1000 1, want 0 0
EFS-EXCEPTION fail:error
.P2
.CW efsck
on the same image:
.P1
efsck: block 6521: node checksum 1000 1, want 0 0
efsck: block 6521 is in the tree and free in the map
efsck: block 6523 is in the tree and free in the map
efsck: block 16383 is in the tree and free in the map
efsck: 123 block(s) marked used and not reached
efsck: /n/dos/efs.img: 4 problem(s)
.P2
.PP
.B "Established."
Block 6521 reads back as 4096 zero bytes, and that is arithmetic rather than
inference:
.CW checksum()
is Adler with
.CW a
starting at 1 and
.CW c
at 0, so 4096 zero bytes give
.CW a=1 ,
.CW c=4096 ,
which is the
.CW "1000 1"
printed, against stored fields of
.CW "0 0" .
So a durable superblock at generation 978 names a tree node that never reached
the medium, and names two more blocks that the committed free map calls free.
Block 16383 is not a false positive from
.CW efsck
counting its own superblock: a freshly made 1024-block image came back
.CW "clean, generation 1" ,
with no complaint about its block 1023.
.PP
.B "The hole in the design."
.CW Fs.commit 's
own comment sets out the order \(em free map, wait for the writes, then one
superblock \(em and
.CW Fs.alloc 's
says that "a crash part way through a commit must be able to fall back".
.CW Fs.mount
does not provide that fallback.  It picks the higher-generation
.I readable superblock
and never checks that the tree that superblock names can be read, so a
superblock whose tree is incomplete is preferred over an older one whose tree
is whole.  Two superblocks exist precisely for this and the second is not
reached.
.PP
.B "Hypothesis, REFUTED \(em see G1b, which measures it."
That writes within one transaction reached the medium out of order because the
backing store is a file on
.CW dossrv ,
whose track cache is write-back.
.CW dosfs
reports it as
.CW "9-sector tracks, 20 buffers" ,
and if those buffers defer a write then
.CW Fs.commit 's
"on this board's synchronous SD driver" is false for this path.  The cache is read
off one statistics line; it has not been shown to defer a write.
.PP
.B "And the confound is the author's."
This image was filled by a session that both overwrote the board's command file
while a transaction was running, killing the writer, and then rebooted the
board.  So this may not be reachable in ordinary operation at all.  Against
that: the boot's own injected-failure arm,
.CW "efs -F 12" ,
reports
.CW "EFS-CRASH-OK the card held the last committed state" ,
so efs survives a failure injected at its own layer; what it has not been shown
to survive is the whole system going down with writes in flight below it.
.PP
.B "The fallback now exists, and so does the flag to ask with."
Both halves of that are done.
.CW efs
and
.CW efsck
take
.CW "-S n" ,
which mounts superblock
.I n
whatever its generation, so the two slots can be read independently \(em
without it the question could not be put at all, because a
mount-write-unmount cycle commits twice and the live slot cannot be moved by
hand either.  And
.CW Fs.mount
now validates the superblock it chose before accepting it, falling back to the
other when the tree is not there:
.P1
efs: x.img: superblock 0 (generation 5) has no tree (tree root:
    node checksum 1000 1, want 0 0); falling back to
    superblock 1 (generation 4)
.P2
.PP
.B "The answer to the question is yes."
On the board's own 64MB filesystem,
.CW "disk/efsck -S 0"
and
.CW "-S 1"
report generation 31 and generation 30, both clean.  The previous generation IS
retained and IS sound, which is what the two superblocks were for and had never
been shown.
.PP
.B "And the A/B is on one image, not two."
A 256-block image was built, committed twice so both slots held a generation,
and the block its live superblock's
.CW treeroot
names was zeroed by hand.  Against the library as it was, that image reproduces
the board exactly \(em
.CW "generation 5 from superblock 0" ,
then
.CW "mount /n/client: node checksum 1000 1, want 0 0" ,
and nothing mounted.  Against the library as it is, it falls back to generation
4 and both files read back.  Corrupting by hand rather than with
.CW "efs -F"
is the point:
.CW -F
stops writes at the efs layer, where the commit order still holds, so it cannot
produce "the superblock landed and a node did not".
.PP
.B "And that hand-zeroing is now unnecessary, which is the better test."
.CW sdmem (3)
produces the same state from the MEDIUM, which is where it comes from, and at
twenty-one cut points rather than one hand-chosen block \(em
.CW tests/efs-fault .
.CW efs-fallback
stays: it is the only arm that runs under host
.CW emu ,
and a check that needs a board is a check that does not run.
.PP
.CW tests/efs-fallback.sh
is that experiment, and it was checked against the old library before being
believed: 9 of its 13 checks fail there.  Two of them had to be tightened first
\(em
.CW '/n/client/a'
unanchored matched
.CW "cat: cannot open /n/client/a: does not exist" ,
so a check written to catch the failure passed on it, and "mounted the spare"
was matching the ordinary banner.  Anchored, and asserting the LOWER generation
by number.
.NH 2
G1a.  CLOSED for the failure that reaches it \(em and the check is one group read
.LP
.CW Fs.mount
reads the free map index and unpacks the tree root.  That is what mount itself
needs, and it is deliberately not more: a full check is
.CW efsck ,
which costs a pass over every block \(em about forty seconds on the board's
64MB image \(em and putting that in front of every mount would mean nobody
mounts.  So a hole deeper in the tree still surfaces as a failed operation
later, exactly as it did on the board, where the bad block was 6521 and not the
root.
.PP
What would close this properly is for the SERVER to fall back when a descent
fails at runtime, not only when mount's spine check does.  That is a larger
change \(em it means a mounted filesystem changing generation under its own
clients \(em and it should not be done before the question below is answered,
because if commits are ordered correctly on the medium then a deep hole cannot
happen and none of it is needed.
.PP
.B "INJECTED, and the spine check had a hole that was not the one above."
.CW sdmem (3)
can now be told to break, so this stopped being an argument.  The
interesting fault is not a lost write but a lost HALF of a writeback:
.CW "reorder 8 partial 1 stop n"
holds eight writes, applies the newest and loses the rest, and the newest is
the superblock because efs writes that last.  So the superblock lands and the
tree it names does not.  Five cut points, and two different outcomes:
.P1
cut at 40, 70   the TREE ROOT was lost
                mount: "has no tree (tree root: node checksum
                1000 1, want 0 0); falling back to superblock 1"
                the older generation is clean.  RECOVERED.

cut at 130      the FREE MAP INDEX was lost
                mount accepted generation 16
                efsck: nine blocks "in the tree and free in
                the map"; generation 15 in the other slot CLEAN
.P2
So the fallback existed, was correct, and was not reached.  The spine check
asked whether the spine was READABLE, which is what a lost tree looks like, and
a lost map is not that: every block it checks reads perfectly.
.PP
.B "The check that catches it is the tree root's own bit."
A map older than its tree is the worst damage this format can carry, because
nothing goes wrong until the allocator hands out a block the tree is using \(em
which is what B1e spent two sessions on from the other direction.  The full
check is
.CW efsck ,
a pass over every block, and putting forty seconds in front of every mount
means nobody mounts.  So
.CW spineok
now reads the group the tree root falls in \(em one block, and mount reads the
index anyway \(em and requires the root's bit to be SET.  It cannot prove the
map is right; it catches a map that predates the root, which is the shape a
lost writeback leaves.
.PP
Verified against the fault that found it: generation 16 is refused with "free
map group 0 says block 0, which is not a map block" and mount takes generation
15, which
.CW efsck
calls clean.  Before the check, mount took 16 and
.CW efsck
found nine problems.
.PP
.B "And a superblock is not a bitmap, which Fs.group did not say."
.CW Fs.group
accepted a group block number of 0.  Block 0 is a superblock, most of its bits
are clear, so reading it as a bitmap reads as tens of thousands of free blocks
and the allocator hands out the filesystem.  That is exactly the state B1e
reached from inside, by writing an all-zero index over the live one \(em and a
device that returns zeroes for a block it never wrote reaches it from outside,
which "stop" demonstrates.  Guarded now, like the matching guard in
.CW Fs.alloc ,
and it is what produces the clean message above.
.PP
.B "What is still open here."
The runtime fallback \(em a mounted server changing generation under its own
clients when a descent fails deep in the tree.  Nothing injected so far
reaches it: every shape tried is caught at mount.  It stays unbuilt, with the
reason upgraded from "answer G1b first" to "no failure has been exhibited that
needs it".
.PP
.CW tests/efs-fault
is the suite: the four faults at twenty-one cut points, each requiring the
image to remount and
.CW efsck
to call it clean with the faults OFF \(em a check run through a device that is
still losing writes is checking the device.  Board only, like
.CW tests/fsbench .
.PP
21 of 21, four times: twice on a JTAG boot, which holds cores 1 to 3, and
twice on the kernel installed on the card with all four online.  The control
is what makes it worth having \(em with the mount check above disabled again
it fails at the reorder cut points, naming the nine blocks.
.PP
.B "AN INTERMITTENT HANG: twice in nine full runs, both at the nineteenth check."
A run on a four-core card boot stops after eighteen of the twenty-one checks
and wedges the board's command poller.  It is not reproducible on demand \(em
nine full runs, two hangs, both on a card boot and both at the same check \(em
and four theories are eliminated by measurement rather than by argument:
.IP \(bu
.B "Not that trial."
Reorder 8, partial 1, stop 100 passes five times out of five in isolation on
one core and five out of five on four.
.IP \(bu
.B "Not memory."
The suite prints
.CW /dev/memory 's
heap row between sections, and it is flat across a run in use and free both:
in use 5554, 5670, 5696, 5670, 5771 blocks, with 50.7MB free throughout.
.IP \(bu
.B "Not a crash."
A watcher process scans
.CW /prog
for a
.I broken
process every five seconds and dumps its status and stack.  It ran during a
hung run and found none, which rules out this tree's usual explanation for a
hang \(em "the server process dies, nothing replies, and the client waits for
a mount whose server is gone".  So something is BLOCKED, not dead.
.IP \(bu
.B "Not a stack of servers."
A failed unmount would leave one mounted and the next trial would mount
another on top.  The unmount is checked now and twenty-one trials report no
failure; the two long-lived
.CW Efsfs
processes a
.CW /prog
scan finds are the BOARD's own, from raspi3binit's
.CW efscheck ,
with the same two pids every trial.
.PP
.B "And the instrument that will catch the next one exists."
The hang leaves the poller blocked, so nothing can be asked of the board
afterwards \(em which is why four rounds of this produced no evidence.  The
answer is for the watcher to write a snapshot of every process's status AND
stack to the HOST, through the styx mount, every eight seconds.  Then a hang
leaves the last snapshot on the host whether or not the board can still be
asked anything.  That version lives outside the suite, because a test should
not depend on being able to write to the machine running it.
.PP
It is written down at this length because an intermittent hang in a
filesystem is the thing most likely to be quietly forgotten, and because
three of the four eliminations above would have been the obvious answer.
.PP
.B "Nothing in it may capture the output of" "disk/efs -f" .
It mounts and leaves a server holding the descriptors it was given, so a
backquote around it waits for an EOF that never comes.  The first version of
the suite did that, wedged the board's command poller, and needed a JTAG
reboot: a program that exits can be captured and a file server cannot.
.NH 2
G1b.  The suspect is DEAD, measured \(em dossrv defers nothing
.LP
Everything above is recovery.  Why a superblock became durable while a node it
named did not is unanswered, and the hypothesis in G1 is unchanged and still
unverified: that
.CW dossrv 's
write-back track cache reordered the writes, which would make
.CW Fs.commit 's
"on this board's synchronous SD driver" false for a filesystem kept in a file
on it.  The cache is read off one statistics line and has not been shown to
defer anything.
.PP
The confound also stands: the image was filled by a session that killed a
writer mid-transaction and then rebooted the board, so this may not be
reachable in ordinary operation.  Against that, the boot's own
.CW "efs -F 12"
arm reports
.CW "EFS-CRASH-OK the card held the last committed state" ,
so efs survives a failure injected at its own layer.  What it has not been shown
to survive is the system going down with writes in flight below it.
.PP
The test that would settle it is now cheap to build, which it was not before:
make an image on
.CW /n/dos ,
write to it, pull power, and read both superblocks with
.CW -S .
If the newer one is durable and its tree is not, the ordering is not being kept
and the fix belongs in the layer below efs, not in efs.
.PP
.B "MEASURED, and it needed no power pull: dossrv does not defer."
.CW sdmem (3)
counts transfers in the DRIVER, so the moment a write reaches the medium is
observable.  A FAT on it, a file written through
.CW dossrv ,
and the counter read at four points:
.P1
                       small write    2.5MB write
mounted and idle          0 ops          0 ops
the copy has returned     5 ops        559 ops
six seconds later         5 ops        559 ops
after the unmount         5 ops        559 ops
.P2
Every write is on the medium before the copy returns, and the unmount flushes
NOTHING.  The second column is the same test under buffer pressure \(em 2548984
bytes through twenty nine-sector buffers, 180KB of cache against 2.5MB \(em
because a cache that defers only when it is full would pass the first column.
It does not defer there either.
.PP
So the hypothesis this item has carried since G1 is refuted.  "Write-back" in
.CW dossrv 's
description is about the read-modify-write of a nine-sector track, not about
deferring anything, and
.CW Fs.commit 's
"on this board's synchronous SD driver" is true for a filesystem in a file on
it.
.PP
.B "And an attribution this plan has made twice is wrong."
That 2.5MB write did 1251 READS for 5031 sectors written, with TWO
read-modify-writes.  1245 clusters were allocated.  So the reads are not
read-modify-write of partial tracks, which is what B1 and
.CW doc/efs-plan.ms
both say dossrv's cost is: they are one FAT lookup per cluster allocated.  That
is a different fix \(em cache the FAT \(em and it is not efs's.
.PP
.B "A power cut alone cannot produce the state G1 describes, and the reason is structural."
Eight cut points, writes lost from transfer 20 through 160: every one remounted
and
.CW efsck
called every one clean, at generations 2 through 25 tracking the cut.  That had
to happen, and seeing why is worth more than the eight results: under copy on
write every write in a transaction goes to a NEW block, so whatever subset
lands, the OLD superblock still names a complete old tree.  Losing writes is a
KIND failure for this format.
.PP
What is not kind is losing PART of a writeback, which is what a volatile cache
does when the power goes: the superblock lands and the tree does not.  That is
reproducible now and efs survives it \(em see G1a above, which is where the one
hole it exposed is written up.
.PP
.B "What remains unestablished."
Why the board's image was damaged in the first place.
.CW dossrv
is eliminated.  The SD driver is synchronous.  What is left is the CARD's own
volatile cache, which is precisely a device that can lose part of a writeback,
and which cannot be tested without pulling power.  The confound the plan
already names \(em the image was filled by a session that killed a writer and
rebooted \(em also stands.
.PP
The useful change is that this no longer needs answering.  The question was
"can the medium leave efs an unmountable filesystem", and the answer is now a
measurement rather than a hypothesis: for every failure shape that can be
injected, no.
.NH 1
H.  The draw path
.NH 2
H1.  DONE \(em the Pi draws into the scanout buffer, and the pixels were read back
.LP
The soft-to-framebuffer copy was 91% of this board's screen path, measured on
silicon at ten times the drawing it delivered.  A peer session pointed
.CW gscreen
at the mailbox buffer instead
.CW ( Directfb
in
.CW screenbcm.c )
and reported
.CW screen+flush
falling from 23333-24444us over 9 fills to 3448us over 58, with
.CW memdraw
unchanged at 2090us.  Those numbers are theirs and are not re-run here.
Committed as
.CW a66d787a7 .
.PP
.B "What the commit rests on that is mine."
It builds; the self-branch scan over the linked kernel stays clean; the card is
.CW kinstall -verified
and the board boots with wifi, DHCP, DNS and the poller up;
.CW wm/wm
runs against it with no fault, no broken process and the board still answering.
None of that sees a pixel, and
.CW DRAW-OK
at boot does not either \(em it prints after filling three colour bars and
checks nothing.
.PP
So
.CW drawink (1)
was written to close that gap
.CW ( 6fbfd2b9a ,
.CW 39123e35f ):
it draws geometry of known size and colour into the screen image and reads it
back
.I "out of the screen image" ,
which under
.CW Directfb
is the memory the GPU scans out.  Five checks \(em a clear that must read all
zero, a fill that must read all non-zero inside, the band above it that must
stay zero, two abutting fills that must each be whole, and a string whose box
must be partly but not wholly inked, because text reaches memdraw as a mask
rather than as a solid source.  The first two are each other's control: the
same pixels read all zero after the clear and all non-zero after the fill, so
neither a readback stuck at zero nor one stuck at full scale passes both.
.PP
All five pass on the board, and the glyph ink agrees with hosted
.CW emu
to the pixel \(em 226 of 1728, ink box 9,10 to 71,21 \(em so the board's draw
path produces the same pixels as the known-good host rather than merely
plausible ones.
.PP
.B "And the checks were shown to be capable of failing."
The first board run failed two of them, by 145 pixels of 75684 and by 14 of
320 on the middle row.  That is the kernel's 16x16 soft cursor, which
.CW Directfb
now composites into the live scanout buffer;
.CW drawink
hides it while it runs.
.CW "drawink -k"
leaves it alone and fails both checks again, naming a 14x14 box at 320,240 \(em
the hotpoint the kernel seeds to the screen centre \(em with both counts
reproducing exactly.  One run therefore establishes three things: the checks
discriminate, the holes were the cursor, and the zero-length write that
restores the default cursor works.
.PP
.B "Two faults a readback cannot see, both already covered."
Reading back through the same memimage, stride and mapping it wrote through
would pass a pitch error and a cache error alike.
.CW screeninit
refuses outright if the mailbox returns a pitch other than
.CW ScrX*ScrPix ,
and
.CW flushmemscreen
still cleans each dirty scanline to the point of coherency now that it has
nothing to copy.  Both were in the patch; neither is owed.
.NH 2
H1a.  OPEN.  It tears, and nothing here separates drawing from scanout
.LP
Stated plainly in the commit and in
.CW screenbcm.c :
a frame can be displayed half-drawn.  This is the price
.CW Directfb
pays for not copying, and
.CW Directfb
set to 0 buys the copy back.
.PP
.B Established.
The mailbox already pins virtual height to physical with tag 0x00048004 and
already sends tag 0x00048009 (virtual offset) as 0,0; asking for 2*h returns
exactly twice the allocation and y=h moves the scanout.  Both verified under
QEMU.
.PP
.B "Not established, and it is the whole problem."
Landing the flip in vertical blank.  Without that a flip moves the tear rather
than removing it, so double buffering on its own is not a fix and must not be
committed as one.
.PP
.B "How it gets closed."
Find the vsync signal the VideoCore exposes to the ARM \(em SMI or the
mailbox's own frame-sync tag \(em and show, with a counter, that flips happen
only between frames.  The acceptance test is not "it looks better": it is
.CW drawink
unchanged (a flip must not change what the readback sees) plus a tear probe
that fills alternating colours as fast as it can and samples one scanline,
which on a torn frame reads two colours.  Write the probe first and prove it
sees the tear that exists today, or it proves nothing afterwards.
.NH 2
H2.  OPEN, and G1b's attribution is withdrawn: the reads are the bad-cluster check
.LP
.CW G1b
closed with this, twice stated as established:
.QP
That 2.5MB write did 1251 READS for 5031 sectors written \(em they are one FAT
lookup per cluster allocated.  That is a different fix \(em cache the FAT.
.LP
The count is right.  The attribution is wrong, and the arithmetic should have
refused it at the time: a 32-bit FAT holds 1152 entries in a nine-sector
track, so the 1245 clusters that write allocated span barely one track, and
LRU touches that track every iteration.  Nothing there needs re-reading.
.PP
.B "What it actually is, read off a trace."
.CW sdmem (3)
now records the first sixty-four transfers since a reset.  A 64KB write
through
.CW dossrv :
.P1
r0+9 r63+9 r97+4 r27+9 r101+4 r105+4 r109+4 r113+4 ...
.P2
The nine-sector reads are the track cache \(em five of them, matching
.CW dossrv 's
own counter exactly.  The four-sector reads march up from sector 97, which is
that filesystem's first data sector, one per cluster.  That is
.CW clustok()
in
.CW appl/cmd/dossrv.b ,
reading each cluster off the device before allocating it to check the medium
can still deliver it.
.PP
A control came first, because the layer below was the obvious suspect: 574
aligned 4608-byte writes straight to the device produce exactly ZERO reads, so
.CW devsd
invents none and the reads had to be the server's.
.PP
.B "Measured, with the server's own -A to turn the check off."
Four arms, same 2.6MB:
.P1
                            check on          check off
2KB clusters, delay 0    1284 reads 1512ms   4 reads 1176ms
2KB clusters, delay 500  1284 reads 2360ms   4 reads 1437ms
16KB clusters, delay 500  165 reads 1609ms   5 reads 1390ms
.P2
22 per cent of the write with a free medium, 39 per cent with a
500us-per-transfer one, and the read count scales as 1/clustersize exactly as
the code's own comment predicts.  The 4-read arm agrees with
.CW dossrv 's
track counter to the transfer, which is the two instruments checking each
other.
.PP
.B "And it matters on this board."
Its card is FAT32 with 16KB clusters, so the check reads 16KB for every 16KB
written: about double the bytes moved for a sequential write.
.CW doc/efs-plan.ms
and item B1 both attribute dossrv's cost to read-modify-write of partial
tracks.  Measured, that is TWO transfers in a 2.6MB write.  This is the cost.
.PP
.B "Why it is not fixed here."
.CW clustok
is not a tuning knob, it is failure handling, and it was added for a real
card: deleting a file and copying it again put it back on the same dead page
and it failed at the same byte, 1245184, every time, because nothing ever
asked whether a free cluster worked.  A fix has to keep that.
.PP
.B "What a fix must preserve, and the three candidates."
The property is: a cluster the medium cannot deliver is marked bad in the FAT
and never handed out again.
.IP 1.
.I "Read one sector instead of the whole cluster."
Cuts the added bytes 32-fold at 16KB clusters and keeps the FAT marking.
Weakens detection to "the cluster's first sector fails".  The premise that a
hard-failed region is larger than a cluster is PLAUSIBLE AND UNVERIFIED, and
cannot be verified without the failing card, so this must not be committed as
though it were equivalent.
.IP 2.
.I "Detect on the write that is already happening."
.CW falloc
zero-fills the whole cluster immediately after allocating it, so the medium is
exercised anyway and
.CW wberr
already latches a failed write-back.  Moving the FAT marking there costs
nothing.  The gap: a pre-write read detects a page that cannot be READ, and a
write can succeed where a read fails \(em so this is a different test, not a
cheaper one.  Which failure the card actually had is not recorded.
.IP 3.
.I "Check once per run of free clusters rather than per cluster."
.CW falloc
allocates sequentially from
.CW freeptr ,
so a run of clusters is contiguous on the medium; one read per run of 32 would
cost 1/32 as much and detect a dead region of at least that size.
.PP
.B "The acceptance test, which has to exist first."
.CW sdmem 's
.CW fail
fault can make one transfer return an error, so "the cluster is marked bad in
the FAT and the write still succeeds" is now a test that can be written and
run, at a chosen cluster, without a bad card.  Write that test against the
CURRENT code and see it pass before changing anything; a fix whose test was
written afterwards proves only that the two agree.
.PP
.B "The acceptance test now exists, and passes against the UNCHANGED code."
.CW tests/dossrv-badclust ,
ten checks on
.CW sdmem (3)
with a new fault that names a SECTOR rather than a transfer number \(em
.CW "failsect n [times]" ,
because a transfer number moves the moment anything unrelated reads the disk
first, and the question here is about a PLACE.  The write succeeds through a
dead cluster; the server names what it condemned; the file reads back and
survives a remount; a fresh write after that remount never offers cluster 2
again, so the bad mark reached the FAT; and with the fault aimed off the disk
nothing is condemned.
.PP
.B "Two controls, and the positive one earned its keep by failing."
"A fresh write skipped the cluster" first looked for a transfer starting at
sector 65.  The control \(em the same sequence with no fault, where cluster 2
MUST be taken \(em failed, because the data leaves as nine-sector tracks
aligned to the track grid
.CW ( w63+9
.CW w72+9
.CW w81+9
.CW w90+9 ),
so nothing ever starts at 65 and the check could not have failed.  The witness
is
.CW clustok 's
own read,
.CW r65+32 ,
which is exactly
.CW clustsize
sectors at the cluster's first sector.
.PP
.B "And candidate 1 now has a named check to break."
Section 7 aims the fault at sector 80, in the MIDDLE of cluster 2, and
requires the cluster to be condemned.  Reading only the first sector would
turn that check red.  That is the point: the trade-off has to be taken by
editing a stated requirement, not discovered afterwards as a regression.
.PP
.B "A fourth candidate, and why it is worse than all three."
Start with the check OFF and turn it on the first time a transfer fails \(em
free on healthy media, protective once a card starts dying.  It is unsafe, and
not marginally.  A bad page that accepts a write and cannot return it later is
precisely the case
.CW clustok 's
READ catches before the data is trusted; with the check off that write is
believed, and the loss surfaces as unreadable data in a file reported written.
Worse, if the bad page announces itself by failing the write instead,
.CW wberr
is sticky and every later write to that filesystem fails until the server is
restarted.  So the trigger either arrives too late or wedges the filesystem.
Recorded because it is the obvious idea and it is wrong.
.PP
.B "Where this leaves H2."
Ready to be worked on, which it was not before: there is a test, it passes
unchanged, and each candidate's cost is now a check that turns red rather than
an argument.  Nothing is changed in
.CW dossrv 's
behaviour here, because the premise candidate 1 rests on \(em that a
hard-failed region is bigger than a cluster \(em cannot be verified without
the failing card, and this tree does not ship unverified premises as fixes.
.NH 2
H3.  OPEN, and now explained: 8l is validated by its shape alone
.LP
Every other loader change in this tree was validated by relinking something
large.
.CW 7l ,
.CW 5l
and
.CW jl
link real kernels;
.CW 6l
relinks
.CW pc64
and was shown to produce a byte-for-byte identical size with its defensive
check in place.
.CW 8l
got the same nil check in
.CW xfol
and has never linked anything, because the only 386 target here \(em
.CW os/inferno/pc
\(em is dormant.
.PP
.B "How dormant, measured rather than assumed."
Five divergences from the port it links against, all fixed in
.CW 70be6af06
by matching
.CW os/inferno/pc64 :
a missing
.CW FPU
typedef that
.CW portdat.h
has required since every
.CW Osenv
gained one;
.CW active.machs
as an
.CW int
bitmap where
.CW portclock.c
indexes an array;
.CW waserror()
defined twice; and a config asking for
.CW bootp ,
.CW iprouter
and
.CW netaux ,
none of which exist in
.CW os/inferno
any more.
.CW portclock.c
compiles now and so does everything before
.CW i8250.c ,
which declares its own
.CW Uart
while the port declares one too \(em a driver that moved into the port and
left a copy behind.
.PP
.B "What closing this needs, and what it is worth."
Reviving the 386 port is its own job, and the only thing it buys here is one
loader's validation.  So the honest order is: leave
.CW 8l
as it is, with
.CW tests/kencc-brloop.sh
saying why; if the port is ever revived for its own sake, relink with
.CW 8l
then and compare sizes as
.CW 6l 's
check was compared.  What must NOT happen is the gap being closed by argument:
.CW 6l 's
story is three bugs deep and each one was found by linking a real kernel, not
by reading the pass.
.NH 2
H4.  OPEN.  The intermittent efs-fault hang, and what a clean run is worth
.LP
.CW tests/efs-fault
has hung twice in about twelve runs.  The symptom is not a failed check: it is
the BOARD'S COMMAND POLLER wedging, once after eighteen of the suite's
twenty-one checks, and the trial it stopped on passes five times out of five
on its own, on one core and on four.
.PP
.B "The criterion, written down BEFORE the runs."
Two in twelve is a rate of about 0.17, so a clean batch proves much less than
it feels like it does:
.P1
clean runs   chance of that many clean if the rate is unchanged
   10                      16%
   20                     2.6%
   30                     0.4%
.P2
So ten clean runs are NOT evidence of anything \(em one batch in six looks
like that with nothing fixed.  Thirty are: at 0.4% the old rate is refused.
And to claim the rate is now under 5 per cent would take fifty-nine.  The
batch to run is THIRTY, and the sentence it licenses is "the rate is not what
it was", never "it is fixed", because nothing has been changed to fix it.
.PP
.B "Theories eliminated, each by a measurement."
Mount stacking: twenty-one trials report no failed unmount, and the two
long-lived
.CW efs
processes a
.CW /prog
scan finds are the board's own, with the same two pids every trial.  The
specific trial: passes five of five alone.  A styx connection or
thread leak on the host: sampled every thirty seconds through six suite runs,
ESTABLISHED connections stayed at 7 and the server's threads at 30, with CPU
climbing 1.7 per cent.
.PP
.B "Memory accumulation is NOT eliminated, and a claim made here has to be withdrawn."
The suite's own comment proposes it: "twenty-one mkefs-mount-write-efsck cycles
in ONE shell process accumulate, and on a board memory is the constraint that
bites".  Between the LAST TWO of the suite's five heap prints the heap moves
7KB and live allocations
.CW ( nalloc-nfree )
go from 6785 to 6861 \(em 76 objects.  That is the end of the run only,
because those were the two lines a truncated capture showed, and
.CW 09f679c25 's
message calls it "across a passing run", which it is not.  The figure that
matters is the first print against the fifth, and it has not been taken: the
board was running the batch.  Take it with the WHOLE output kept \(em
.CW grep heap
over an untruncated capture \(em before the theory is called dead.
.PP
.B "The theory that is left, and it is NOT efs."
The workload copies its twenty files FROM
.CW /n/remote
\(em the styx mount, through the same export session the poller holds.
.CW tools/jtag/styxd.sh
records "the server genuinely stops answering Styx" as a real mode, seen on a
server up three and a half days, whose symptom is that the board "simply
blocks with no message".  That is the reported symptom exactly, and it would
make a healthy board look dead to every instrument that reaches it through
.CW /n/remote .
.PP
.B "Which is why the instrument had to change first."
The watcher wrote its snapshot to
.CW /n/remote/tmp/snap.txt ,
so for the failure most likely to be happening it would block too \(em an
instrument that goes down with the thing it watches, and the reason two hangs
produced no evidence.  It writes to
.CW /dev/cons
now, which reaches the serial port AND the kernel's print ring, and the ring is
readable over JTAG with neither styx nor the console's deaf input path.
.PP
.CW tools/jtag/wedgediag
asks the four questions that tell the ends apart: does the host answer a NEW
styx handshake, is the server process moving, does the board answer JTAG, and
does the print ring hold anything.  On a catch, question one is the whole
experiment.
.NH 2
H1a update.  ANSWERED: the firmware does know where vertical blank is
.LP
H1a above says the one thing not established is landing the flip in vertical
blank, and that without it a flip moves the tear rather than removing it.  It
was open because nobody had asked the hardware.
.PP
Mailbox tag 0x0004800e, waited on eight times from the board's
.CW screenstats()
hook
.CW ( c942709ef ):
.P1
SCREEN vsync errors 0 gaps(us)
    8612 16664 16665 16667 16665 16666 16668 16665
.P2
Zero errors, a partial first interval because the probe entered mid-frame, then
seven gaps of 16664 to 16668us \(em 60.006Hz, stable to 2us.
.PP
.B "The outcomes were written down before the run,"
because one number here is ambiguous three ways:
.P1
errors 0, gaps near 16667us   it works
errors 0, gaps of a few us    the firmware ignores the tag
errors 8, gaps of a few us    the firmware refuses it
errors 8, gaps near a second  mboxread's SPIN COUNT expired
.P2
The last row was the real hazard.
.CW mboxread
bounds its wait with a spin count and not a timeout, and a spin count expiring
inside a legitimately slow reply is how this tree once read a working SD card
as a stalled one \(em see
.CW doc
and the standing note on it.
.CW Spins
is 10 million, about a second of uncached reads by
.CW mailbox.c 's
own comment, against a 16.7ms frame: sixty frames of headroom.  Checked, not
assumed.
.PP
And the partial first gap is the internal control: a fixed 16.667ms sleep would
have given eight equal gaps.  This is phase-locked to something outside the
ARM.
.PP
.B "What is still NOT established, and it is the next step."
That the call returns exactly at vertical blank.  Timing shows only that it
synchronises to a 60Hz frame clock.  Whether a flip issued immediately after
the return lands before scanout reaches the top is a different question, and
the order H1a already sets stands: write the tear probe FIRST and see it catch
the tear that exists today, because a probe that cannot see today's tear
proves nothing about tomorrow's flip.
.PP
.B "A note on the probe's placement."
.CW mboxvsync()
blocks the calling core for up to a frame, so it lives on a statistics hook
reached by writing
.CW dump
to
.CW /dev/kpctl
and nowhere near a draw path.  Nothing should change that until the flip is
built, and then only on the path that flips.
.NH 2
H1a correction.  The prescribed tear probe cannot work, and the arithmetic says why
.LP
H1a asks for
.QP
a tear probe that fills alternating colours as fast as it can and samples one
scanline, which on a torn frame reads two colours.
.LP
.B "That probe cannot see a tear, and would have reported success."
A readback reads the FRAMEBUFFER, and the framebuffer is never torn: after a
fill completes, every pixel in it is the new colour, whatever the display did
while the fill was running.  A tear is a property of the IMAGE THE GPU
ASSEMBLED during one frame \(em old pixels above the beam, new below \(em and
that image exists only on the wire.
.CW drawink (1)
reads the same memory the fill wrote and would pass on a wildly tearing
display, which is exactly the shape of instrument this plan keeps catching.
.PP
.B "What CAN be measured, now that the frame clock is known."
Tearing is a race between two rates, and both are now numbers:
.P1
scanout        34.72 us/row   (480 rows in 16.665ms, measured)
memdraw fill    4.35 us/row   (2090us full screen, the peer's figure)
fill + flush    7.18 us/row   (3448us full screen, the peer's figure)
.P2
A full-screen fill proceeds in scanline order, so a fill STARTED AT VSYNC runs
8.0x ahead of the beam and finishes row 479 when the beam is at row 60.  With
the flush included it is 4.8x ahead and finishes at row 99.  The beam never
catches the write, so the frame the GPU assembles is entirely new pixels.
.PP
.B "Which means, for this case, vsync alone is the fix and double buffering is not needed."
A draw that waits for vertical blank and then writes faster than the beam
advances cannot tear.  That is a claim about ONE full-screen fill at the
measured rate, and it is the case the numbers cover.
.PP
.B "Where it stops being true, which is what the probe must measure."
.IP 1.
A draw that takes longer than a frame.  At 16.665ms the beam laps the writer
and every subsequent frame is torn regardless of phase.
.IP 2.
A draw that does not proceed in scanline order.  Tk paints many small
rectangles in widget order, so a write can land above the beam after the beam
has passed, and that pixel appears one frame late \(em a tear that no
full-screen measurement predicts.
.IP 3.
A draw not aligned to the frame at all, which is every draw today: nothing in
.CW flushmemscreen
waits for anything.  A write at a random phase puts the boundary wherever the
beam happens to be.
.PP
.B "So the probe to write is a timing probe, not a pixel probe."
Three numbers, all available on the board: the gap from a vsync return to the
first write of a draw (the phase), the draw's duration, and its extent in rows.
From those, "did any row get written after the beam had passed it" is
arithmetic, and it is decidable per draw rather than guessed at from a
photograph.  The acceptance test for a flip is then that this count is ZERO
over a run of draws, with
.CW drawink
unchanged to show the pixels are still right.
.PP
.B "And the first thing to measure is the cheap one:"
whether simply waiting for vsync in
.CW flushmemscreen
removes tearing for the real workload, before any second buffer is allocated.
It costs up to a frame of latency per flush and nothing else.  The numbers
above say it should work for full-screen fills; items 2 and 3 say Tk is where
it will not, and that is a measurement, not a guess.
.PP
.B "And where the wait would have to go, which settles the architecture."
With
.CW Directfb ,
.CW memdraw
writes the scanout buffer directly, so by the time
.CW flushmemscreen
runs the pixels are already on the wire \(em waiting there is TOO LATE, and
that is where the obvious implementation would have put it.
.PP
There is a correct pre-draw hook:
.CW hwdraw(par)
is called from
.CW memimagedraw
in
.CW libmemdraw/draw.c
before any pixel is written, and
.CW screenbcm.c 's
returns 0 and does nothing.  But it fires once per draw OPERATION, and a Tk
update is hundreds of them, so a vsync wait there would cost hundreds of frames
per update.  Per-operation synchronisation is not an option at any granularity
the draw device exposes, because nothing in it says where one frame's worth of
drawing begins.
.PP
That is the argument for double buffering, and it is stronger than "it tears":
a single buffer has no moment at which waiting is both correct and affordable.
Two buffers give one \(em the flip \(em and the flip is once per frame no matter
how many draws fed it.  So the direction H1a already had is right, and the
cheap-experiment paragraph above applies only to the one case where a frame IS
a single top-to-bottom pass.
.PP
.B "The cost of tear-freedom, and it is the Directfb win handed back."
Page flipping with INCREMENTAL drawing needs both buffers to agree except for
the current frame's damage, so each frame costs a damage-sized copy (or the
same damage drawn twice).  That is exactly what
.CW Directfb
removed: the old path drew into a shadow and copied the damage to the scanout
buffer, and the peer measured the copy at 20452us of a 23900us screen path for
a full-screen fill \(em 86 per cent.
.PP
Scaled by damage, which is the number that decides it:
.P1
full screen 640x480     20452 us
a quarter of it          5113 us
a 128x96 widget            818 us
a 64x48 widget             205 us
.P2
So for Tk, where damage is widget-sized, tear-freedom costs a few hundred
microseconds a frame against a 16665us budget, and is affordable.  For a
full-screen fill it costs 20ms and would undo the whole change.
.PP
.B "Which gives the item a shape it did not have."
The conflict is real and it is not either/or: the expensive case for the copy
is the full-screen redraw, and a full-screen redraw is exactly the case that
needs NO copy, because the next frame overwrites the whole back buffer anyway.
So the rule to try is: flip when the damage covers the screen, copy when it
does not, and the copy is small precisely when it is needed.  That is a
hypothesis with a measurement attached, which is what this item has been
missing; it is not yet built and not yet tested.
.PP
.B "What would refute it."
A workload whose damage is both large and partial \(em half the screen, every
frame \(em pays 10ms a frame and 60Hz becomes impossible.  Whether Tk ever does
that is a measurement on the real thing, not an argument, and
.CW flushmemscreen
already counts
.CW nflushbyte ,
so the damage distribution can be read off a session before any of this is
built.
.PP
.B "A latent bug the vsync work turned up: the mailbox was not serialised."
.CW os/inferno/raspi3b/mailbox.c
had no lock of any kind.  An exchange is a write of a buffer address followed
by a read of the reply, with the reply landing in the CALLER'S buffer, so two
callers interleaving can each take the other's \(em a GPIO read returning a
clock rate, with the success code set.  Not a detectable error: a wrong answer.
.PP
It is reachable.  Boot-time callers run one at a time, but several drivers come
back at runtime:
.CW btbcm
reads a firmware GPIO to power Bluetooth,
.CW sdhostbcm
and
.CW sdhcibcm
ask for clock rates on a card reset,
.CW pwmbcm
asks on open, and now
.CW screenbcm 's
vsync probe waits on the display.  Any two can overlap.  One
.CW Lock
in
.CW mboxprop
serialises all of it, since
.CW mboxwrite
and
.CW mboxread
are used nowhere else.  A
.CW Lock
and not a
.CW QLock
because
.CW mboxprop
runs during boot from
.CW mailboxinit
and
.CW screeninit ,
where there is no process to sleep.
.PP
.B "And that settles how the tear probe must get its timeline."
A waiter on this lock spins, and a vsync wait holds it for a whole frame.  So a
periodic vsync kproc \(em the obvious way to keep a running vsync timestamp for
any draw to measure its phase against \(em is NOT an option: at sixty waits a
second it would hold the mailbox essentially all the time and starve every
other user of it.
.PP
The probe must instead sample vsync ONCE per measurement window and extrapolate
from the period, which the measurement makes safe: 16.665ms stable to 2us, so
extrapolating over a second of frames accumulates at most 120us of phase error
\(em three and a half rows out of 480.  One mailbox call per window, and an
error small against what is being measured.
.PP
It also imposes a rule the file now states: NOTHING may call the mailbox from an
interrupt handler.
.NH 2
H4 update.  CAUGHT, and it is not efs, not the host, and not memory
.LP
The hang reproduced on the third run of the second batch, and the instrument
built for it answered the question it was built to answer.
.PP
.B "A confound first, recorded before the result was read."
Between 23:58 and 00:02 I ran three kernel links on THIS host while writing the
tear probe, and this host serves the board's styx mount.
.CW styxd.sh
records that a server busy sending the board a kernel does not answer promptly,
so a slow run during my builds could have been mine.  It was not:
.CW wedgediag 's
first question is whether the HOST answers a NEW styx handshake, and it
answered in 0.00s on the first attempt, with the server process blocked and its
CPU time unchanged across five seconds.  The host was healthy.  The rule for
the next batch stands anyway \(em nothing heavy on this host while one runs.
.PP
.B "The board is WEDGED, not reset."
Its build stamp reads correctly over JTAG
.CW ( 1790998142 ,
the installed build) so kernel memory is readable and no reboot happened, and
yet the command poller does not answer.
.PP
.B "What the dump says, with every name resolved against the build that was running."
That mattered:
.CW where
REFUSED to print names because the host's kernel had been rebuilt since the
install \(em item C1's fix doing its job \(em so the symbols came from a kernel
rebuilt from the exact commit the card holds.
.P1
55 processes: 38 Queueing, 15 Wakeme, 2 Running
cpu0                 idle+4
31 of the Queueing   sched <- iyield <- vmachine
one Running (dis)    in Sys_readn, lpc iprintcanlock+36
one Running (wlrx)   wlreadpkt -> sleep, lpc qlock+140
many waiters         qpc tcpkick+84
.P2
.CW iyield
parks a process on the Dis VM's idle queue, so those 31 are queued for the
single-threaded VM, which is ordinary.  What is not ordinary is 38 of them
queued while cpu0 is IDLE: nothing is running and nothing can run, which is a
VM that is held and never given back.
.PP
.B "Three theories die here, two of them mine."
Not the host, measured above.  Not process exhaustion:
.CW conf.nproc
is 200 and there are 55.  Not the styx export session, which is the theory this
item has carried \(em it answered instantly.
.PP
.B "And the board cannot recover from it, which is why it reads as a hang."
.CW clock.c 's
.CW diswdog()
exists for exactly this \(em it stops feeding the hardware watchdog once a Dis
process has held the VM too long, and lets the reset come \(em but it begins
.CW "if(bootwdog == 0) return;" ,
and
.CW bootwdog
is 0 in the config.  So the recovery written for this failure is switched off,
and a VM livelock wedges the board for ever.  That is a configuration finding,
not a bug in the watchdog.
.PP
.B "What is established and what is not."
Established: the facts in the table, the host's health, the dead theories, and
that the board cannot self-recover.  NOT established: WHICH process holds the
VM and why.  Two candidates, each with evidence and neither proven:
.IP 1.
The console.  The one Dis process in
.CW Sys_readn
has its last lock in
.CW iprintcanlock ,
and
.CW clockpoll /
.CW clockcheck
\(em the console UART poll \(em are on its stack.  A process holding the VM and
stuck in the print path would produce precisely this.
.IP 2.
The network.  Many waiters carry
.CW qpc
.CW tcpkick+84 ,
and
.CW wlrx ,
the wifi receive kproc, had 6309 ticks of time.  The styx mount runs over wifi,
so a stalled receive path with the VM held would also produce it.
.PP
.B "The next step is one instrument change, and the ring is why."
.CW clock.c
already prints
.CW VMHELD
lines naming the pid, the text, the ticks held and the last kernel and Dis pcs.
Those would name the holder outright.  They are not in the capture because the
RING WRAPPED \(em 111 lines, all of them process-dump lines, with the trigger
and any VMHELD above them gone.  So: make the hold report survive, by raising
the ring or by sending VMHELD somewhere that is not the ring, and run the batch
again.  The answer is one line of output away and the instrument threw it away.
.NH 2
H4 LOCALISED.  The wedge is a poll of the CARDLESS Arasan controller
.LP
Caught a second time, with the host deliberately idle so the confound of the
first catch could not apply, and with
.CW tools/jtag/vmheld
armed.
.PP
.B "The holder question is answered, and the answer kills my own hypothesis."
.P1
vmheld: the CURRENT hold is 14 ticks; the longest since boot is 127 ticks
vmheld: last kernel pc during a hold 0x8b100 -> awaitbit+44
where:  cpu0 0x8b100 awaitbit+0x2c   (five samples over 18 minutes)
.P2
.CW maxvmheld
is 127 ticks, which is exactly the healthy-boot figure, so NO process held the
Dis VM for long.  The first catch's reading \(em "the VM is held and never
given back" \(em was wrong, and the thing that refuted it is the instrument
built to confirm it.
.PP
.B "What it really is."
.CW awaitbit
is in
.CW sdhcibcm.c :
the register poll of the Arasan/EMMC controller, which on this board has NO
CARD.  cpu0 sits in it.
.PP
.B "Spinning, not stalled, and that distinction took one command."
Five samples at the identical pc look like a core stalled on an MMIO read that
never returns \(em and this tree's own rule says a pc that will not move is
stalled.  It moves: single-stepping gives 0x8b100, 0x8b104, 0x8b108, 0x8b10c.
So the core is executing, and the identical samples are a short loop whose
uncached register read dominates its time.
.PP
.B "And the loop that never ends is the OUTER one."
.CW awaitbit
is bounded \(em
.CW "for(i = 0; i < Timeout; i++)"
with
.CW Timeout
one million.  By
.CW mailbox.c 's
own calibration (ten million uncached reads is about a second) that is 0.1s a
call, so eighteen minutes of wedge is about TEN THOUSAND completed calls.
Something re-enters it for ever.  A spin count is a bound on one call and not
on a caller, which is the same lesson this board learned from the Arasan DMA
stall and is now wearing a second time.
.PP
.B "Why the board never comes back."
.CW bootwdog
is 0, so
.CW diswdog()
never arms the hardware watchdog.  Confirmed from the running kernel.
.PP
.B "Established."
Reproducible: two hangs in thirteen runs across two batches.  The host answered
a new styx handshake in 0.00s BOTH times.  cpu0 executes inside
.CW awaitbit .
It is not an efs fault, not the styx session, not memory, and not a Dis VM
hold.  No recovery is possible as configured.
.PP
.B "NOT established: which caller re-enters it, and why the Arasan is driven at all."
The suite works on
.CW /dev/sdZ0 ,
which is RAM.  Two leads, neither tested.  First,
.CW devsd 's
.CW gen()
calls
.CW online()
whenever a unit has no media, and a cardless unit never acquires any, so every
directory read of
.CW /dev
re-probes it.  Second, the board's config has all four drivers
.CW ( sdemmcbcm ,
.CW sdhostbcm ,
.CW sdhcibcm ,
.CW sdmem ),
so binding
.CW #S
enumerates the Arasan whether or not anything wants it \(em and
.CW tests/efs-fault
does NOT bind
.CW #S
itself; the harness around it does.  Whether the original hangs, which predate
that harness, share this cause is open.
.PP
.B "The next instrument, and it is small."
Name the CALLER.  openocd can read cpu0's registers, so a tool that takes
.CW sp
and
.CW x29
and walks the frame chain against the kernel's symbols would print the stack
above
.CW awaitbit
in one command \(em the same shape as
.CW vmheld ,
which needed no kernel change either.  That is the one fact missing, and
guessing between the two leads above is not worth a build.
.NH 2
H4 ROOT CAUSE.  The wifi chip stops answering SDIO, and the driver retries for ever
.LP
.CW tools/jtag/kstack
names the caller, and it is not what either lead in the previous section
guessed:
.P1
awaitbit            (cpu0 spinning here)
sdhcirecover+36
sdhcicmd+308
sdiocmd52+132
wlintwait+36
wlrxproc+104
linkproc
.P2
.B "And it corrects this plan's own reading of the hardware."
The previous section calls the Arasan controller "cardless".  It is not: on a
Pi 3B, SDHOST drives the SD card and the ARASAN drives the SDIO WIFI chip.
That is why a controller nothing seemed to want was being polled \(em the wifi
receive kproc was polling it, which is its job.
.PP
.B "The counters say the retry is unbounded, read off the wedged board:"
.P1
sdhcinrecover  0xc1c = 3100 recoveries
sdhcilastint   0x100   (no Cmdcomplete, no Interr)
sdhcilaststat  0x01ff0000
sdhcilastwhy   "nothing answered: no completion and no error"
.P2
So an SDIO command to the wifi chip got NO response at all \(em neither a
completion nor an error.
.CW sdhcicmd
returns -1,
.CW sdhcirecover
runs and spins its bounded poll, and
.CW wlrxproc
comes straight back for more: three thousand one hundred times, and still
going after eighteen minutes.  Each
.CW awaitbit
is bounded; the retry above it is not, which is the whole bug.
.PP
.B "Why it presents as every other theory."
The board's only network is wifi, so when
.CW wlrxproc
stops making progress the styx mount and the command poller go silent and the
board looks dead.  The HOST is untouched, which is why
.CW wedgediag
found it answering in 0.00s both times.  It is not an efs fault:
.CW efs-fault
is merely a workload long enough, with enough network traffic, to reach it.
That also explains the first catch's two
.CW Running
processes \(em
.CW wlrx
with 6309 ticks \(em and the waiters parked at
.CW tcpkick ,
which is TCP backing up behind a dead link.
.PP
.B "Established, end to end."
The chain above, from a stack scrape on the wedged core; the counters, read by
address; the reason string, read by address; and reproducibility, two hangs in
thirteen runs with the host proven healthy both times.  No recovery, because
.CW bootwdog
is 0.
.PP
.B "What is NOT established."
WHY the chip stops answering.  A retry loop that never gives up turns one lost
response into a dead board, and that is a driver defect whatever the cause \(em
but the cause is a separate question, and the counters above are the place to
start: 3100 recoveries with
.CW Interrupt
reading 0x100 every time says the controller is in a fixed state, not a
fluctuating one.
.PP
.B "The fix, in the order it should be done."
.IP 1.
Bound the retry.  A caller of
.CW sdhcirecover
must give up and report, not loop; a bounded poll inside an unbounded caller is
the same mistake this board already made with the Arasan DMA stall, now in a
second place.
.IP 2.
Then decide what "give up" means for wifi: drop the link and re-associate is
recoverable, and the board stays reachable over the console and JTAG either
way.
.IP 3.
Only then consider
.CW bootwdog .
A watchdog that resets the board would have hidden all of this, and the two
hangs would have read as spontaneous reboots.  It is a backstop, not the fix.
.NH 2
H4 FIX.  The retry is bounded; what that does and does not claim
.LP
.CW 796d76547 .
.CW wlrxproc
counts CONSECUTIVE refused reads, lengthens its sleep to a ceiling, and stops
polling the interrupt status under the bus lock while backing off.  Four in a
row is well clear of a working chip, because one successful read resets the
count and an empty queue does not raise it.  The ceiling is a flat second: the
point is to stop monopolising the bus and the processor, not to tune a
recovery.
.PP
.B "Verified both ways, because a path that has never run is not a fix."
The negative control is build 1791005012 \(em boots,
.CW WIFI-JOINED ,
.CW WIFI-DHCP-OK ,
poller answering over the air, and NO "refused" message, so the backoff does
not fire on a healthy board.  The positive control is a build with both
thresholds set to 0, which printed both messages alternating and could
deliberately not sustain a network; so neither branch is dead code.  That test
also found the message's own bug:
.CW sdhcilastwhy
is initialised to
.CW ""
and not nil, so the nil guard printed empty parentheses.
.PP
.B "What this claims."
That one unanswered SDIO command can no longer kill the board.  Nothing more.
.PP
.B "What it does NOT claim."
It does not stop the chip refusing commands, and it is not yet shown to hold
under the workload that produced the fault.  THAT is the acceptance test, and
it is the batch H4 already specifies: thirty runs, one variant, host idle.  The
outcome to require is not merely "thirty clean" \(em it is that IF the chip
refuses reads, the
.CW sdio
message appears AND the run still finishes.  A batch with no refusals at all
proves only that the chip behaved, which is the same thing ten clean runs
proved before and did not settle.
.PP
.B "And the counters make that distinguishable,"
which is the point of having them: the message names the run of refusals and
the recovery count, so "no failures occurred" and "failures occurred and were
survived" are different readings rather than one silence.
.PP
.B "Still open, and narrower than the item began."
Why the chip stops answering.  3100 recoveries with
.CW Interrupt
reading 0x100 every time says a fixed state rather than a fluctuating one, and
the place to start is that register rather than the driver's own counters.
.NH 2
H4 CORRECTION.  There are TWO failures, and "ROOT CAUSE" above claims too much
.LP
The section headed
.B "H4 ROOT CAUSE"
says the hang is the wifi SDIO retry.  That is one of the failures and not both,
and the fix for it did not stop the next one.
.PP
.B "Three catches, two signatures."
.P1
A  cpu0 idle+4     38 Queueing, wlrx Running, no SDIO data taken
B  cpu0 awaitbit   3100 recoveries, "nothing answered"
C  cpu0 idle+4     63 Queueing, NO refusals, heldkpc 0
.P2
B is the SDIO retry, diagnosed and bounded in
.CW 796d76547 .
A and C are something else: in C the backoff never fired, so the chip never
refused a read, and all four cores were examined \(em three idle and one
cycling through
.CW clockpoll
with a pc that MOVES between samples.  The kernel is alive and idling; only the
Dis world is stuck.
.PP
.B "And C is a failure this kernel has described all along."
.CW os/inferno/port/dis.c ,
above
.CW diswatchproc() :
.QP
This board wedges: the interpreter stops handing over, and a dump taken with
^\\ at that moment shows processes Queueing for the VM and others Ready with
nobody running them.  Five of those in two days.
.LP
That is catch C exactly.  There is already a watchdog for it \(em
.CW diswatch ,
pid 3, the process
.CW VMHELD
named \(em and the process dump this plan has been reading for three catches is
ITS output, not a dump anyone asked for.
.PP
.B "Which means the evidence was being destroyed by the instrument that gathered it."
.CW diswatchproc
prints
.CW DIS-WEDGED
with the facts \(em beat,
.CW vmq
waiting or empty,
.CW runhd
ready or empty \(em and THEN calls
.CW kstackdump() ,
which writes two lines per process: over 150 lines on a 77-process board, into
a ring that holds about 111.  A ring keeps the newest lines, so the one line
that names the wedge was gone every time.  Three captures were reconstructed
from process states when a single line had already said it.  Fixed in
.CW 31c5358a3
by printing the summary again AFTER the dump.
.PP
.B "What this does to the item."
.IP 1.
The SDIO retry was a real unbounded loop and bounding it was right, but it is
not "the" cause and the previous section's heading overstates it.  Stated here
rather than by editing that section, so the sequence of what was believed when
stays legible.
.IP 2.
Catch A's data is thin \(em no
.CW vmheld ,
no per-core reading \(em so whether A is C or B is not decided.  It looks like
C.
.IP 3.
The open question is now the one the kernel's comment already poses: why does
the interpreter stop handing over?  And for the first time the next occurrence
will say so itself, in a line that survives.
.PP
.B "So the batch to run is the same batch, and its reading has changed."
A wedge now produces
.CW DIS-WEDGED-END
with
.CW vmq
and
.CW runhd ,
which distinguishes "nothing was waiting" (not a wedge) from "work was queued
and nobody ran it" (the real thing) without reconstructing anything.
.NH 2
H4.  The watchdog's verdict survived \(em and a counter I trusted measures something else
.LP
.B "The fix to the watchdog worked, first wedge after it:"
.P1
DIS-WEDGED-END: beat 5472271, vmq waiting, runhd ready,
    ticks 134819 (the dump above is 15 s of no progress)
.P2
BOTH queues non-empty: processes waiting in
.CW acquire()
for the token AND Progs ready to run, with no interpreter progress for fifteen
seconds.  That is the one line three earlier captures had to be reconstructed
without.
.PP
.B "And no SDIO refusals at all in that catch,"
so the chip was answering and the backoff never fired.  The SDIO retry is a
real bug and is not this.
.PP
.B "WITHDRAWN: 'no process held the Dis VM for long'."
That claim, in the correction two sections above, rested on
.CW maxvmheld
reading 127 ticks.  It does not support it.
.CW livelockcheck()
keys on
.CW "static Proc *held"
and resets the count whenever the processor's current running process changes,
so on a four-core board
.CW vmheldticks
is the longest single-process run on cpu0 and says nothing about the token.
The name invites the reading and I took it.
.PP
The counters are still worth having \(em a Dis program that will not yield is
what they were built for \(em but they are not a measure of the token, and
.CW tools/jtag/vmheld
now says so where it prints them.
.PP
.B "So the token is instrumented directly."
.CW port/dis.c
records
.CW vmholderpid ,
.CW vmholdertext ,
.CW vmholdbeat
and
.CW vmholdn
in
.CW acquire() ,
.CW release()
and
.CW iyield()
\(em scalars rather than a
.CW Proc* ,
because they are read off a wedged board by address and a pointer would need
Proc's offsets, which are not in the symbol table.  Verified on a healthy
board: the token reads FREE, with 1031369 handovers against a disbeat of
903697.
.PP
.B "What the next wedge will settle, and it is a two-way question."
.CW vmholdbeat
against
.CW disbeat :
.IP \(bu
holder named and
.CW disbeat
UNCHANGED since it took the token \(em one process is stuck inside the
interpreter, and its kernel pc names where;
.IP \(bu
token FREE with
.CW vmq
waiting \(em the token was lost on a handover, and the bug is in
.CW release() /
.CW iyield() /
.CW acquire() ;
.IP \(bu
holder named and
.CW disbeat
moving \(em not a wedge at all, and the watchdog's threshold is wrong.
.PP
Those are three different bugs and no amount of reading process states tells
them apart, which is why the previous three catches did not.
.NH 2
H4.  The token's holder is named, and the next question is two numbers
.LP
.B "The three-way question is answered: branch one."
.P1
DIS-WEDGED-END: beat 2185878, vmq waiting, runhd ready, ticks 51303
vmheld: the token is held by pid 145 (dis)
vmheld:   and disbeat has NOT moved since it took it
vmheld: handovers since boot 2650203, disbeat 2185878
.P2
So it is not a lost handover.  ONE Dis process takes the interpreter token and
stops making progress, and every other Dis process queues behind it.  Two and a
half million handovers had happened before that one.
.PP
.B "Where it is stuck is not yet established, and one reading was a trap."
The dump's
.CW pc
field for pid 145 said
.CW Sys_pread+172 ,
which looks like an answer and is not:
.CW up->pc
is set by
.CW acquire()
when a process QUEUES, so it records where that process last queued, not where
it is now.  And
.CW Sys_pread
does
.CW release()
and
.CW acquire()
around its
.CW kpread
correctly \(em checked in
.CW os/inferno/port/inferno.c
\(em so it is not a syscall blocking with the token held.
.PP
.B "The live suspect, with the evidence both ways."
On the wedged board all four cores were read \(em which needed
.CW where
fixed first, since it had been examining only cpu0 \(em and cpu0, cpu2 and cpu3
were in
.CW idle+4
on every sample while cpu1 was in
.CW clockpoll ,
.CW minigetc ,
or
.CW splhi
inside
.CW minigetc
on four of five.  An idle core sits in WFI like the other three, so that
asymmetry wants explaining.
.PP
.CW clockpoll()
drained the console FIFO with
.CW "while getc() >= 0" ,
unbounded, and it is called from
.CW clockcheck()
INSIDE
.CW vmachine 's
loop \(em exactly where a token holder would spin.  The console is chosen at
runtime by GPIO14's function select and on this board the firmware chose the
MINI uart, so
.CW consuart->phys->getc
is
.CW minigetc ;
.CW uartmini.c 's
"NOT LINKED" header comment is stale.
.PP
.B "Against it:"
on a fresh boot
.CW npollchar
reads 0, so in ordinary operation the console delivers no characters and the
loop cannot iterate.  That does not contradict the above \(em a stuck RX line
would be present only during the wedge \(em but it is not a diagnosis, and I
nearly committed one.
.PP
.B "So it is now two numbers rather than an inference."
.CW 991f8ddf0
bounds the drain at 64 characters a call (the bound
.CW uartpl011 's
kick loop already uses) and counts
.CW npollchar
and
.CW npollfull ;
.CW vmheld
reads both.  At the next wedge:
.CW npollfull
climbing means the drain was being trapped and the old loop would have spun
there for ever;
.CW npollchar
still 0 means the console is not involved at all.  The bound removes an
unbounded loop from the token path either way, which is the part that does not
depend on being right about the cause.
.PP
.B "Three unbounded loops found in this item so far,"
all of the same shape and all in paths that hold something: the SDIO retry
above a bounded poll, the wifi reader's retry, and this drain.  The tree's own
rule \(em a bound on one call is not a bound on its caller \(em has now been
earned three times.
.NH 2
H4.  The holder is handed the token and never runs \(em the suspect is now the SCHEDULER
.LP
The watchdog prints the holder's own entry now, and it moves the question off
the interpreter altogether.
.P1
DIS-WEDGED-HOLDER: pid 158, the token holder:
158: dis pc 0x1c101c  Running (Running) ut 217
     qpc 0x164dc4 (tcpkick+84) lpc 0x1766ec (iprintcanlock+36)
DIS-WEDGED-END: beat 313842, vmq waiting, runhd ready, ticks 10352
.P2
.B "0x1c101c is Sys_print+256, and that is the acquire() AFTER the write."
.CW Sys_print
in
.CW os/inferno/port/inferno.c
does
.CW release() ,
then formats and
.CW kwrite 's,
then
.CW acquire()
\(em correctly.  So this is NOT a syscall blocking with the token held, which
was the obvious theory and is now the second one eliminated by reading the code
rather than guessing
.CW ( Sys_pread
was the first).  And
.CW up->pc
is where a process last QUEUED, so it names the
.CW acquire()
call site, not a position.
.PP
.B "What that leaves."
pid 158 finished its print, queued in
.CW acquire() ,
was handed the token \(em
.CW vmholderpid
says so \(em and then made no progress at all:
.CW disbeat
is frozen at the same value the watchdog reported.  Meanwhile ALL FOUR CORES
ARE IDLE (three in WFI, one in the idle path's
.CW clockpoll ,
which matches 0 characters taken).
.PP
So the token was handed to a process that never ran, with every processor idle.
That is not the Dis token logic and not a missing release: it is
.CW ready()
or the run queue.  The dumps have been pointing at it all along \(em the
.CW lpc
of almost every queued process is
.CW queueproc+40
or
.CW dequeueproc+16 ,
the scheduler's own lock.
.PP
.B "Eliminated, each by evidence rather than argument."
The host (styx answers in 0.00s, five catches running).  efs (the suite is a
workload, not a cause).  Memory
.CW ( conf.nproc
200 against 74).  The styx export session.  The SDIO retry (a real bug, bounded,
and its refusal count is zero in these catches).
.CW clockpoll 's
drain (0 characters taken DURING two wedges).  A held-too-long VM
.CW ( maxvmheld
measures something else entirely \(em withdrawn above).  A blocking syscall
holding the token
.CW ( Sys_pread
and
.CW Sys_print
both release correctly).
.PP
.B "Not eliminated, and newly visible now the ring survives:"
the USB host controller is erroring in the same window \(em
.CW "ep3.1 completion timeout" ,
.CW "error intr 00000082" ,
.CW "channel won't halt hcchar c0000000" .
That halt loop IS bounded (a 100-tick timeout, checked), so it is not a loop
defect, but a controller that will not halt a channel is a fault in its own
right and it is on the same board at the same moment.  Whether it is cause,
consequence or coincidence is open.
.PP
.B "The next instrument, and it is the last one this needs."
Read the RUN QUEUE and each processor's
.CW up
at a wedge, by address, the way
.CW vmheld
reads the token.  If pid 158 is sitting on a run queue while four cores idle,
that is a lost wakeup in
.CW ready() /
.CW queueproc() ,
and the bug is located.  If it is on no queue at all, it was readied and
dropped, which is a different bug in the same place.  Either way the answer is
two reads and no more guessing.
.NH 2
H4.  WHERE THIS STANDS (read this first; the sections above are chronological)
.LP
.B "The symptom:"
.CW tests/efs-fault
sometimes stops and the board answers nothing.  It was read, over two days and
by me, as an efs bug, a styx wedge, a memory leak, a held Dis VM and a wifi
SDIO stall.
.PP
.B "What it actually is, as far as it is established:"
a Dis process is handed the interpreter token and never runs.
.CW disbeat
freezes at the value the watchdog reports;
.CW vmq
has processes waiting and
.CW runhd
has Progs ready; all four processors are idle.  So the fault is in
.CW ready()
or the run queue, not in the interpreter and not in any driver.
.PP
.B "Two REAL bugs were found and fixed on the way, neither of them this one:"
.IP \(bu
.CW 796d76547
\(em
.CW wlrxproc
retried a failed SDIO command for ever (3100 recoveries, each spinning a
bounded poll), so one unanswered command killed the board.  Bounded.
.IP \(bu
.CW 991f8ddf0
\(em
.CW clockpoll()
drained the console FIFO unbounded, inside
.CW vmachine 's
loop.  Bounded.  Measured NOT to be this wedge (0 characters taken during two
of them) and fixed anyway, because an unbounded loop in the token path is a
hazard on its own.
.PP
.B "Eight theories eliminated by measurement:"
the host (styx answers in 0.00s at every catch), efs, memory
.CW ( conf.nproc
200 against 74), the styx export session, the SDIO retry, the console drain, a
held-too-long VM, and a blocking syscall holding the token
.CW ( Sys_pread
and
.CW Sys_print
both release correctly).
.PP
.B "Four instruments were wrong before they were useful,"
and each one produced a wrong conclusion first:
.IP \(bu
the wedge watchdog printed its diagnosis and then flooded it out of the ring
with its own 150-line dump;
.IP \(bu
.CW devprog 's
.CW progpid
counter printed every 10000 calls for ever and filled the ring with 333 lines
of itself;
.IP \(bu
.CW where
examined cpu0 and printed nothing about the other three, so "cpu0 idle" read as
"nothing is running";
.IP \(bu
.CW vmheldticks
is named for the token and measures the longest single-process run on ONE
processor.
.PP
.B "Two readings of a dump that look like answers and are not:"
.CW up->pc
is where a process last QUEUED, so it always names an
.CW acquire()
call site;
and a procdump stack line is a raw SCRAPE, not a call chain \(em one of them had
.CW vmachine
four times and a data symbol in it.
.PP
.B "The next fact needed"
is the per-processor census the watchdog now prints from inside the wedge
.CW ( 3810cbdc2 ):
whether any processor has the holder as its current process.  On a queue with
four cores idle is a lost wakeup in
.CW ready() /
.CW queueproc() ;
on no queue at all is readied-and-dropped.
.PP
.B "And one fault is open and unexplained:"
the USB host controller reports
.CW "ep3.1 completion timeout"
and
.CW "channel won't halt"
in the same window.  Its halt loop is bounded, so it is not a loop defect, but
it is a fault on the same board at the same moment and nothing yet connects or
disconnects it.
.PP
.B "ADDENDUM, and it splits the item in two."
A catch that produced NO
.CW DIS-WEDGED
produced something else entirely: the ring full of
.CW VMHELD
lines naming holds of 53 to 91 ticks whose last kernel pc was
.CW rungc+128 ,
.CW rungc+632
or
.CW memset .
The GARBAGE COLLECTOR holds the interpreter token for up to 0.91s at a time.
.PP
The watchdog's fifteen-second threshold cannot see that, so the board is SLOW
rather than wedged \(em and the harness, which only waits 600s for an answer,
had been calling both of them "HUNG".  It greps
.CW DIS-WEDGED
now, so the two are different readings.  Everything above that was written
before this distinction existed should be read with it in mind: the catches
with a
.CW DIS-WEDGED
line are wedges, the others may be slowness.
.PP
.B "And the GC's own counters say the heap chain breaks."
On a HEALTHY boot:
.P1
gc sweeps 53594, chains found BROKEN 12
gc busy 0xac3, gc idle 0x496e
.P2
.CW gcsweep()
calls
.CW okbhdr(ptr)
and, when the block header's magic is none of the four valid values, sets
.CW "base = nil" ,
counts it and abandons the sweep.  Not fatal \(em the next call restarts from
the pool chain head \(em but a header reading as invalid on a healthy boot is
either corruption or the sweep walking the chain while the allocator updates
it, and the second is a race.  Twelve in 53594 sweeps.  Recorded, not
diagnosed, and NOT yet connected to either failure above.
.NH 2
H4 ROOT CAUSE, FOUND: the JIT's I-cache invalidate covered one core of four
.LP
.CW b461ec5f1 .
.CW cacheiinv()
in
.CW os/inferno/raspi3b/l.s
executed
.CW "IC IALLU" ,
which invalidates the LOCAL processor's instruction cache to the point of
unification.
.CW "IC IALLUIS"
invalidates every I-cache in the Inner Shareable domain.
.CW segflush()
calls
.CW cacheiinv()
to make instructions written as data visible to the fetcher, and on this board
the writer is the JIT
.CW ( cflag
is 1): it compiles a Dis module on whichever processor happens to be running,
and the process that then executes that code can be scheduled on any other.
With a local invalidate, that other processor fetches stale instructions from
its own I-cache.
.PP
.B "The measurement that named it."
.P1
trap type 0 esr 0x2000000 pc 0x4c86be0
panic: trap
.P2
ESR 0x02000000 is exception class 0 \(em "unknown reason", which is what a
processor says when it executes something that is not an instruction \(em and
.CW pc
0x4c86be0 is in the Dis heap, where compiled code lives.  A processor fetched
garbage from an address the JIT had just written.
.PP
.B "Why it hid, and it is four things at once."
It is intermittent, because it needs the process to migrate between the compile
and the execution.  It is INVISIBLE to any single-processor arm, because a JTAG
boot holds cores 1-3 \(em so every JTAG-booted test in this plan would have
pronounced it fixed.  It presents as a WEDGE and not as a fault, because the
panicking process never releases the interpreter token and every other Dis
process then queues in
.CW acquire()
behind it.  And the wedge watchdog's own dump flooded the panic message out of
the ring.  Each of those had to be removed before the trap line was visible at
all.
.PP
.B "The encoding was checked by hand, because a wrong system instruction traps."
.P1
+0  0xd5033f9f  DSB SY
+4  0xd508711f  IC IALLUIS     (IC IALLU is 0xd508751f)
+8  0xd5033f9f  DSB SY
+12 0xd5033fdf  ISB SY
+16 0xd65f03c0  RET
.P2
.B "And the rest of the sequence is sufficient, checked rather than assumed:"
.CW cacheflush()
cleans with
.CW "DC CVAC" ,
to the point of COHERENCY, which is beyond the point of unification that
instruction fetch needs, and ends in
.CW coherence() .
The two other
.CW IALLU
sites in
.CW l.s
are left alone: both run at boot on one processor, where a local invalidate is
what is wanted.
.PP
.B "A PREDICTION THAT FAILED, which is the useful part."
If a processor executing garbage can scribble on the heap before it traps, the
GC's broken block headers should have been a consequence, and should have gone
to zero.  They did not:
.P1
pre-fix boot A   12 broken /  53594 sweeps = 2.24e-04
pre-fix boot B   13 broken /  41247 sweeps = 3.15e-04
pre-fix boot C   56 broken / 184251 sweeps = 3.04e-04
FIXED            38 broken / 452782 sweeps = 8.39e-05
.P2
3.5 times lower pooled, and NOT zero.  The comparison is across different boots
and workloads, so even the factor is not clean.  So the broken chains are their
own fault, still open, and the honest reading is that this fix addresses the
EC-0 trap and says nothing certain about them.
.NH 2
H4, the SECOND failure: the GC writes through unvalidated words
.LP
The item split in two and this is the other half: a board that is SLOW rather
than wedged, and a heap the GC keeps damaging.  Both have the same source, and
.CW libinterp/gc.c
has described it for four-plus sessions in a comment above
.CW markheap() :
.QP
if it's not H, it's D2H()'d and Setmark()'d (h->color written) with no
validation at all \(em unlike freeptrs(), which has had checkfreeptr()
guarding the same kind of word...  A small, non-H garbage value here computes a
garbage Heap*, and Setmark() then WRITES to whatever h->color happens to
resolve to \(em a live, unrelated object's memory, corrupting it, with no crash
at the write site itself (an ordinary store, not a fault) to point at what
happened.
.LP
.B "The only guard was switched off on this board."
.CW checkmarkptr()
returns at once unless
.CW distrack
is set, and
.CW main.c
sets
.CW distrack
to 0 on raspi3b because it costs 7.5x \(em 60ms a frame against 8ms, and 7
frames handed to a waiting reader against 1222.  So nothing checked, and
.CW gcbroken
counted 38 to 56 damaged chains per boot while being reported by nothing.
.PP
.B "The fix is two compares, always on."
The same test
.CW markheap 's
own entry already applies to
.CW t ,
for the reason it gives: a real pointer is never near-zero and never
misaligned, so a word that is either is known-bad without touching it.  Reject
it, count it in
.CW gcbadptr ,
and skip \(em skipping is right because there is no object at a misaligned or
near-zero address to mark, so nothing live is dropped.
.PP
Checked for safety before writing it:
.CW H
is
.CW (void*)(-1) ,
which IS misaligned and would be rejected \(em but the existing
.CW "*q != H"
test excludes it first.
.PP
.B "And the slowness is a separate, structural thing."
.CW Quanta
is 50 blocks and
.CW MaxQuanta
750, so the SWEEP is bounded; the ROOT WALK is not.
.CW rootset()
calls
.CW markheap()
on every live process's every stack frame every pass, which is why holds of 53
to 91 ticks appear once the suite has accumulated seventy-odd Dis processes,
and why the board stops answering inside 600s without ever being stuck.  That
is a design property, not a bug, and bounding it is its own piece of work.
.PP
.B "NOT installed with the I-cache fix, deliberately."
Two changes and one batch makes a clean result unattributable to either.  The
batch running now scores WEDGES against
.CW b461ec5f1
alone; the guard goes in afterwards, with
.CW gcbroken
as its own acceptance number.
.NH 2
H1a correction.  "The expensive case needs no copy" assumed the wrong frame
.LP
The flip/copy rule above says the expensive case for the copy is the
full-screen redraw, and that a full-screen redraw needs no copy because the
next frame overwrites the whole back buffer.  The first half is true and the
second quietly assumes the NEXT frame also covers the screen.
.PP
A full-screen fill followed by a widget update needs the copy after all: the
widget frame inherits a back buffer holding the frame before last, and only the
widget's own rectangle gets rewritten.  So the rule has to decide from the
frame it is ABOUT TO DRAW, not the one it has just drawn.
.PP
That is a sharper argument for a described frame than the one I gave, because
"how much of the screen will this frame touch" is answerable before drawing
only if something describes the frame first.  An immediate-mode draw knows it
after the fact, which is too late to choose between flipping and copying.  A
peer session has built that producer in libtk \(em
.CW tkscenebounds()
and
.CW "render bounds" ,
the union of what a described frame will mark \(em and committed it saying
plainly that nothing consumed it.  This rule is its first consumer.
.PP
.B "What is still missing is the PATH, and it is not built."
libtk knows the bounds, the decision belongs in a screen driver, and nothing
carries one to the other.
.CW hwdraw()
is a genuine pre-draw hook at the wrong granularity (per draw operation, and a
Tk update is hundreds).  Carrying a frame-level damage hint would be a change
to
.CW os/inferno/port/devdraw.c .
.PP
.B "And it is gated on a measurement I have not taken."
.CW aeb56a141 's
damage histogram answers the question the rule turns on, and has only been read
for
.CW drawink 's
own workload of full-screen fills.  Tk is the case that matters: widget-sized
damage makes the copy a few hundred microseconds against a 16665us frame and
the path worth building, while damage that is routinely half the screen makes
it 10ms a frame and 60Hz impossible \(em and then the rule is wrong and a hint
would carry a decision that cannot be made.  Read the histogram off a real
.CW wm
session FIRST.
.NH 2
H1a.  The damage measurement, and what transfers from another machine
.LP
A peer session measured the distribution the flip/copy rule turns on, without
needing a board, on the argument that damage GEOMETRY is a property of
.CW libtk 's
repaint logic and not of any screen.  That argument is right, and it is why the
measurement did not need hardware.  Its own
.CW flushmemscreen
got the same five buckets, env-gated:
.P1
runtests -g   n=197  mean 221236  <=64KB 67.5%  <=256KB 95.4%  >1MB 4.6%
wmtest -n 40  n=122  mean  98404  <=64KB 98.4%  <=256KB 98.4%  >1MB 1.6%
.P2
.B "The cost question is settled by that, and the frequency question is not."
They separate, and only one of them transfers:
.IP \(bu
COST is byte-denominated.  At 0.0166us a byte, 64KB is 1.1ms of a 16665us
frame and those means are 1.6 to 3.7ms.  A 128x96 widget is 49152 bytes on any
screen, so this carries over directly and the copy is affordable.
.IP \(bu
FREQUENCY is COVERAGE-denominated and does NOT carry over.  "Flip when the
damage covers the screen" compares damage against the screen, and the screen is
1228800 bytes here against 3145728 there.  The same rectangle is 2.6 times more
of this board's screen, so the flip case fires MORE often here \(em and their
">1MB" bucket is below full screen for them and above it for us.
.PP
That is the pleasant direction: more full-screen frames means more frames
needing no copy at all.  But it means the histogram still has to be read on
THIS board, for the coverage number rather than to second-guess theirs \(em the
buckets are the same absolute bytes, so the ratio to 1228800 is the part only
this board can give.
.PP
.B "Their bias note is also in the reassuring direction,"
and worth keeping: both workloads are automated suites rather than a person
using the machine, but the churn-heavy one \(em
.CW wmtest
creating forty toplevels \(em is the MORE widget-sized of the two, so any bias
overestimates damage.
.PP
.B "And one harness rule from them, which is the mirror of four of mine."
At a reporting interval of 300 flushes nothing printed at all, because the
whole workload produces a couple of hundred.  An instrument whose reporting
interval exceeds the experiment is indistinguishable from an instrument
measuring nothing.  Mine were the inverse \(em prints recurring without bound
that ate the kernel's ring, four of them, one being the wedge watchdog
destroying the panic message that explained why it fired.  Same error in both
directions: choosing a cadence without reference to how long the measured thing
lasts.  Counts belong in variables; prints belong bounded.
.NH 2
H1a RESOLVED on frequency: the refuting workload does not exist
.PP
.B "It has been read, and it does not refute it \(em it is the argument FOR it."
The peer took the distribution at 640x480 over two real workloads.  Damage is
in bytes, so these are directly comparable to the scaled table above.  This is
a SECOND measurement, re-run at this board's geometry rather than theirs, which
is what makes the coverage column mean anything: the frequency question above
does not transfer between screen sizes, and re-running at 640x480 is how it
gets answered without the board.  Coverage is the ratio to 1228800 bytes.
.P1
workload        flushes  mean B  mean cov  <=5.3%  <=21%   >85%
runtests -g         197  106356      8.7%   74.6%  19.8%   4.1%
wmtest -n 40        122   66979      5.5%   98.4%   0.0%   1.6%
.P2
.PP
The refuting workload \(em large and partial every frame \(em does not appear.
The middle of the distribution is nearly empty: damage is either widget-sized
(three quarters to all of it under 5.3 per cent) or it is the whole screen.
That is the shape the rule was designed for and not the one that breaks it.
.PP
.B "And the rare bucket is the one that decides it, which I had backwards."
A bucket holding 1.6 to 4.1 per cent of flushes reads as too rare to plumb
devdraw for.  It is not, for two separate reasons, and the second is decisive.
.PP
First, amortised.  Taking the bucket boundary, 1044480 bytes, as a lower bound
gives at least 42823 of
.CW "runtests -g" 's
106356-byte mean \(em 40 per cent \(em and at least 16711 of
.CW wmtest 's
66979, 25 per cent.  The peer then pinned it tighter from data I did not have:
the eight
.CW >85%
flushes in that run are 9830400 of 20952132 total damage bytes,
.B "47 per cent" ,
if each is a full screen \(em and they are, on two independent grounds in the
recording.  The maximum in the run is exactly 1228800, and the remainder is
self-consistent: the other 189 flushes then average 58845 bytes, inside the
64KB bucket that holds 147 of them, and the ceiling-sum of the non-1MB buckets
is 20652032, barely under the total, so those buckets sit well below their
ceilings.
.PP
So four per cent of the flushes carry 47 per cent of the damage bytes, and
skipping the copy there saves at least 711us of a 1766us average copy, 277us of
1112us for
.CW wmtest .
That is the inverse of the usual mistake: a 48 per cent cut of a 15 per cent
term is 7 per cent, but a four per cent term that is 47 per cent of the mean is
the MAIN term.
.PP
.B "The per-byte rate the whole thing extrapolates from is measured, not assumed."
Both halves above scale a full-screen measurement down to bucket sizes, so a
rate that bent with size would move the amortised half.  It does not: the four
points on this board are 0.01664us a byte at 1228800, 0.01664 at 307200,
0.01664 at 49152 and 0.01668 at 12288 \(em linear across a hundredfold range.
Worth stating because an unexamined extrapolation is where this argument would
have failed.
.PP
Second, and this is the real argument, the budget:
.P1
full-screen copy  1228800 B x 0.0166 us/B = 20398 us
one 60Hz frame                            = 16665 us
                                             1.22x the whole budget
at the 85 per cent boundary               = 17338 us = 1.04x
.P2
Every flush in that bucket exceeds a frame's entire budget on the copy ALONE,
before a single pixel is drawn.  Without the rule those are not slow frames,
they are dropped frames, deterministically.  With it they are the cheapest
frames there are \(em on the condition the correction above insists on: the
frame ABOUT TO BE DRAWN covers the screen, not the one just drawn.  Read that
way the rule converts the only frames that cannot meet the budget into free
ones.  Read the other way it is the bug that correction describes, and the
budget arithmetic would be an argument for shipping it.
.PP
So the frame-level damage hint in
.CW os/inferno/port/devdraw.c
\(em carrying libtk's
.CW tkscenebounds()
down to a screen driver \(em is worth building, and that is now a measured
conclusion rather than a preference.  What is still owed from this board rather
than from host emu is the coverage ratio on silicon: the per-byte cost above is
measured here, the bucket boundaries are in the same absolute bytes, but
whether a real
.CW wm
session on the Pi puts the same 1.6 to 4.1 per cent of its flushes in the top
bucket is a measurement only the board can give.
.PP
It waits on the
.CW "IC IALLUIS"
acceptance batch, not on the decision.  Two changes and one batch makes neither
attributable.
.NH 2
H1a CORRECTION, and it withdraws the budget argument above: the saving is OVERLAP, not coverage
.LP
The section above says the flip/copy rule turns frames that cannot meet the
budget into free ones, and that 47 per cent of the copy cost is in four per cent
of the frames.  Both halves are wrong as stated, and the error is the same one
the H1a correction describes \(em I wrote the qualification into the paragraph
and then reasoned without it.  What follows replaces them.
.PP
.B "Work the two schemes over a sequence, which a histogram cannot hold."
Call the buffers FRONT and BACK.  After the flip ending frame
.CW N-1 ,
FRONT holds frame
.CW N-1
and BACK holds frame
.CW N-2 ,
because BACK is the buffer that was front two flips ago.  Frames
.CW N-1
and
.CW N-2
differ exactly in
.CW damage(N-1) .
So before frame
.CW N
can be drawn incrementally, BACK must be brought up to frame
.CW N-1
everywhere frame
.CW N
will not overwrite:
.P1
deferred cost(N) = |damage(N-1) \e damage(N)|
eager    cost(N) = |damage(N)|
.P2
where eager is the obvious scheme \(em copy this frame's damage to the new back
immediately after the flip, so BACK is never stale and no hint is needed.
.PP
.B "Then the difference between them is the overlap, and nothing else."
.P1
eager - deferred = SUM |damage(N-1) AND damage(N)|
.P2
Deferred never copies more than eager and never less than eager minus the
intersection of consecutive frames' damage.  Modelled over scanline intervals,
where intersection is exact:
.P1
isolated full among widgets  eager 1474560 B / 1 dropped  deferred 1167360 B / 1 dropped
a RUN of four fulls          eager 5038080 B / 4 dropped  deferred 1167360 B / 1 dropped
the same widget every frame  eager  368640 B / 0 dropped  deferred       0 B / 0 dropped
disjoint widgets every frame eager  245760 B / 0 dropped  deferred  184320 B / 0 dropped
.P2
.PP
.B "So the budget argument is withdrawn for the case I argued it on."
An ISOLATED full-screen frame drops one frame under both schemes.  Deferred
makes the full frame itself free and then charges the frame AFTER it
.CW "|full \e widget|" ,
which is very nearly the whole screen.  The 20452us copy does not disappear; it
moves one frame later.  "Dropped frames deterministically, not occasionally" was
true of eager and I presented it as an argument for deferred, which does not fix
it.  Deferred wins on drops only when full-screen frames are CONSECUTIVE: k in a
row costs eager k drops and deferred one.
.PP
.B "And the amortised 47 per cent goes the same way."
47 per cent of the total damage bytes sitting in four per cent of the flushes is
a true statement about EAGER's cost distribution.  It is not a saving.  For
isolated fulls the deferred total is the same to within two widgets, because the
big copy is still paid, one frame later.  The number described the cost, and I
read it as the prize.
.PP
.B "What the model says instead, which is a better rule than the one it corrects."
The saving is
.B "repeated damage of the same region, at any size" ,
because that is where consecutive damage overlaps.  A widget animating in place
\(em redrawing the same rectangle every frame \(em costs eager that rectangle
every frame and costs deferred ZERO, for ever.  Coverage of the screen does not
enter.
.PP
So "flip when the damage covers the screen, copy when it does not" is not the
rule; it is one sufficient condition for the rule, which is why it looked right.
Full-screen
.CW damage(N)
makes
.CW "damage(N-1) \e damage(N)"
empty, so the coverage test fires exactly when the real test would \(em and also
misses every case where the real test fires on a small repeated rectangle.  The
rule is just: copy
.CW "damage(N-1) \e damage(N)" ,
with no coverage test in it at all.
.PP
.B "The pre-draw hint survives this, and for a sharper reason."
.CW damage(N)
is needed BEFORE frame
.CW N
is drawn, and nothing observing frames that have already been drawn can supply
it.  That is not an argument that a described frame is tidier; it is the whole
reason
.CW tkscenebounds()
is the only possible producer and
.CW hwdraw()
is not one.  The hint is still worth building.  What is withdrawn is the claim
that the measurement already justified it.
.PP
.B "What is now owed, and it is not a histogram."
Whether consecutive damage overlaps is a property of the SEQUENCE, and every
number taken so far \(em mine and the peer's \(em is a distribution over flushes
with the order thrown away.  The instrument has to change: record
.CW "|damage(N-1) AND damage(N)|"
per flush, which
.CW flushmemscreen
can do by keeping the previous rectangle, and which costs one
.CW rectclip
and an add.  Until that exists the flip/copy rule has no measurement behind it,
and the honest state of H1a is one step further back than the section above
claims.
.PP
.B "The lesson, which is mine and not the arithmetic's."
Every number here was correct.  The histogram was correct, the 47 per cent was
correct and tightened by the peer, the per-byte rate was correct and checked for
linearity at both ends.  The conclusion was still wrong, because a distribution
cannot answer a question about order and I never asked which kind of question I
had.  Checking an extrapolation and checking a rate does not check that the
quantity measured is the quantity the argument needs.
.NH 2
H1a MEASURED on overlap: 84.9 per cent, and the right measurement is larger than the wrong one
.LP
The correction above said the flip/copy rule had no measurement behind it and
named the one to take: the overlap of consecutive frames' damage.  A peer
session built it \(em one remembered rectangle, one
.CW rectclip
and an add \(em and ran it on
.CW "runtests -g"
at 640x480 over 197 flushes:
.P1
eager    20952256 B    1770 us a frame
deferred  3084216 B     260 us a frame
overlap  17796408 B    84.9 per cent saved
.P2
.PP
So the deferred scheme is strongly justified, and by the thing the model named
rather than the thing either of us argued: consecutive frames overlap because
Tk repaints the same widgets, which is repeated damage of the same region at
any size and has nothing to do with the rare full-screen frames both
measurements had been built around.  The right measurement gives a LARGER
number than the withdrawn one \(em 84.9 against a claimed 47 that was not even
a saving.
.PP
.B "And the sequence question has an answer, which kills the drops argument."
Differencing the cumulative histogram recovers which flush incremented which
bucket:
.P1
runtests -g  >1MB at flushes 1,2,3,4,5,6,7 and 68
wmtest -n 40 >1MB at flushes 1 and 2
.P2
The consecutive case that favours deferred on DROPPED frames does occur \(em
seven in a row \(em and all of it is start-up paint.  The one mid-run
full-screen frame, at flush 68, is isolated and saves nothing.  So on these
workloads the dropped-frame argument survives only for initial paint, which
nothing is trying to hit 60Hz on, and the whole case for the rule is the
amortised overlap.  That is the opposite of how I argued it: I called the
budget decisive and the amortised figure secondary.
.PP
.B "A check on the instrument, from devdraw's own absorb rule."
Both instruments measure flush-to-flush where the scheme is frame-to-frame, and
the error runs both ways: a frame arriving as several disjoint flushes
under-states, while two overlapping flushes within one frame over-state,
because a frame does not overlap itself.
.CW addflush()
nearly excludes the second.  It emits the accumulated box only when
.P1
anbb > 1024 && waste*2 >= anbb && !rectXrect(flushrect, r)
.P2
\(em a mid-frame emission happens precisely when the new rectangle does NOT
intersect the box being emitted, and the next box starts as that disjoint
rectangle.  Consecutive flushes from one frame therefore begin disjoint by
construction, so two adjacent flushes that overlap are evidence of a frame
boundary rather than of intra-frame splitting.  Not airtight \(em the second box
can grow back over the first \(em but it makes 84.9 per cent close to a lower
bound rather than merely suggestive, since the under-stating case is the common
one and the over-stating case is mostly excluded by the emit condition.
.PP
.B "What the failure was, and it is not an arithmetic mistake."
Every number in the withdrawn argument was right: the histogram, the peer's
tightened 47 per cent, the per-byte rate checked for linearity at both ends of
a hundredfold range.  The conclusion was wrong anyway, because a distribution
over flushes cannot answer a question about order and neither of us asked which
kind of question we had.  Validating an input does not validate the model it
feeds \(em the rate check was not wasted, it would have caught a different
failure, and it was not the one we had.
.NH 2
H1a: 84.9 per cent is an UPPER bound, and the frame boundary this item says does not exist does
.LP
Two corrections to the section above, one to a claim I made in it and one to a
premise this whole item has carried.
.PP
.B "First, my absorb-rule bound does not follow."
I argued that because
.CW addflush()
emits only when
.CW "!rectXrect(flushrect, r)" ,
consecutive flushes within one frame begin disjoint, so adjacent flushes that
overlap mark a frame boundary and 84.9 per cent is close to a lower bound.
That covers MID-BATCH emissions only.
.CW dunlock()
calls
.CW drawflush()
on every
.CW /dev/draw
write that took the drawlock, so the ordinary flush is one per write batch and
has no disjointness guarantee against the next batch whatsoever.  The argument
was reasoning from one code path and generalising to the other.
.PP
.B "And the peer's per-transition data says the unit is probably not a frame."
.CW damage(N-1)
lies entirely INSIDE
.CW damage(N)
in 132 of 196 transitions on
.CW "runtests -g" ,
120 of 121 on
.CW wmtest ,
and no transition on either has zero overlap.  Nested growing rectangles are
what several write batches refining one logical update look like.  Independent
frames repainting the same widget would REPEAT a rectangle, not grow through
it.
.PP
So 84.9 per cent is an upper bound on the deferred saving, not a lower one: a
present coalesces those nested flushes into one damage region, and the overlap
between coalesced regions is the quantity the scheme is about.  Which makes
.CW nsamerect
the discriminator after all, for exactly the reason I nearly demoted it \(em
repeated IDENTICAL rectangles are genuine frame-to-frame repaint, strict growth
is refinement within one update, and the ratio between them settles which this
is.
.PP
.B "Second, the frame boundary EXISTS, and this item has been assuming it does not."
The item has said throughout that nothing in the draw interface says where one
frame's drawing begins, and used that to argue a hint must come down from
libtk.  For the DECISION that is still true, because the decision needs
damage(N) before frame N is drawn.  For MEASUREMENT it is false:
.P1
'v' in devdraw is the client's present.
libdraw's flushimage(d, 1) emits it; flushimage(d, 0) does not.
drawflush() runs on it.
.P2
What makes the flush stream ambiguous is only that
.CW dunlock()
flushes unconditionally as well, mixing real presents with incidental per-write
flushes.  So accumulating damage between
.CW 'v'
commands needs no new interface at all, and the instrument belongs in
.CW os/inferno/port/devdraw.c
where
.CW 'v'
is visible rather than in a screen driver, which cannot tell the two kinds of
flush apart.
.PP
That is the third instrument, after the distribution and the per-flush overlap,
and it is the first one that measures the quantity the scheme is about.  Both
earlier ones measured something adjacent to it.
.PP
.B "The pattern, now three deep."
A distribution answered a question about order.  A per-flush overlap answered a
question about frames.  Each measurement was correct and each was of a quantity
ADJACENT to the one its argument needed, and in both cases the error was found
by someone other than whoever made it \(em I caught the first by working the
sequence, the peer caught the second by distrusting an agreement they would
have liked.  The durable rule is the peer's: validating an input does not
validate the model it feeds, and the two need separate checks.  The per-byte
linearity check was not wasted; it would have caught a different failure.
.NH 2
H1a SETTLED: a flush IS a frame on these workloads, so 84.9 per cent is the value
.LP
The peer measured at the
.CW 'v'
boundary rather than assuming the unit, on
.CW "runtests -g"
at 640x480:
.P1
runtests -g   197 flushes / 197 frames  eager 20952256 B  deferred 3084216 B
wmtest -n 40  122 flushes / 122 frames  eager  8171520 B  deferred 1182672 B
.P2
The two boundaries agree EXACTLY, on both workloads: same counts, same bytes,
84.9 per cent either way, 1770us to 261us and 1115us to 161us a frame.  So Tk
emits one
.CW 'v'
per update, there was never any fragmentation to coalesce, and the per-flush
number was the value rather than an upper bound.  Measured at the boundary
instead of assumed equal to it, which is the whole difference.
.PP
.B "A retraction inside the retraction, and it is the same error again."
The first figures from the
.CW 'v'
boundary were 196 frames against 197 flushes with eager differing by 71632
bytes, and both the peer and I explained the gap as one damage region.  It was a
cumulative counter read while the run was still going, before the last frame
closed.  A gap the size of a plausible finding got explained instead of
questioned \(em by its own author, who had written the reporting cadence.
.PP
.B "The equal/growth discriminator came in first and was nearly enough."
Splitting the nested transitions by area:
.P1
runtests -g    EQUAL 128  STRICT-growth 4  partial 64
               overlap bytes: EQUAL 74.6%  STRICT 0.9%  partial 24.6%
wmtest -n 40   EQUAL 119  STRICT-growth 1  partial 1
               overlap bytes: EQUAL 98.7%  STRICT 0.7%  partial 0.7%
.P2
Refinement by growth \(em the inflation mechanism \(em is under one per cent of
overlap bytes.  But the peer's push-back on my framing is right and is kept:
EQUAL rules out growth, not DUPLICATION.  A widget repainted next frame and a
widget flushed twice within one frame both read as equal rectangles, and a
present coalesces the second.  So the rectangle comparison narrowed it and only
the
.CW 'v'
boundary could close it.
.PP
.B "So the deferred scheme is justified, by overlap, at 84.9 per cent."
On this geometry that is 1770us a frame for eager against 260us for deferred,
both against a 16665us budget.  Nothing about coverage of the screen, and
nothing about the rare full-screen frames that two measurements and two
sessions were built around: the saving is Tk repainting the same widgets, which
is repeated damage of the same region at any size.
.PP
.B "The on-board instrument is written and not yet run."
.CW os/inferno/port/devdraw.c
now accumulates the union of damage between
.CW 'v'
commands and charges both schemes against the previous present, reported from
.CW screenbcm.c 's
.CW screenstats()
rather than from
.CW devkprof.c
beside
.CW screenstats() :
.CW shakti
and
.CW sifiveu
configure
.CW kprof
WITHOUT
.CW draw ,
so a hook there is an undefined symbol on those boards and would need a stub in
each, which is exactly why
.CW screenstats()
itself needs
.CW screennone.c .
.PP
It is not built into a kernel.  The board is scoring
.CW b461ec5f1
alone and two changes in one batch makes neither attributable.
.PP
.B "What the counters cannot tell you, recorded because I nearly claimed they could."
.CW nflushper
does not distinguish a per-FRAME
.CW 'v'
from a per-OPERATION one.
.CW libinterp/draw.c 's
.CW checkflush()
sends
.CW "flushimage(display, 1)"
after a draw when the image has flush enabled, so
.CW 'v'
can arrive per operation \(em and then each
.CW 'v'
still produces exactly one flush, so
.CW nflushper
reads 1 either way.  The unit is established by the 196-against-197 result and
by nothing in the instrument.
.PP
.B "Four instruments, and the lesson did not change once."
A distribution answered a question about order.  A per-flush overlap answered a
question about frames.  A rectangle comparison answered a question about growth
when the question was about duplication.  Only the fourth measured the quantity
its argument needed.  Every time, the author already held the disconfirming
data \(em my four linearity points were in the message I sent, the peer's
equal/growth split was in records already taken, the sequence model needed no
new measurement at all \(em and every time the error was caught by the other
one of us.  The missing step was never collection.  It was asking what question
the number answers.
.PP
And one failure mode of mine that repeated inside this item: I argued from
.CW addflush() 's
disjointness guarantee to a conclusion about the path
.CW dunlock()
takes.  That is the same shape as reading a distribution as an answer about
order \(em generalising from the path you looked at to the path that runs.
.NH 2
H1a.  WHERE THIS STANDS (read this first; the H1a sections above are chronological)
.LP
.B "Settled." 
Double buffering with incremental drawing costs a damage-sized copy per frame.
Two schemes: EAGER copies
.CW damage(N)
after each flip, DEFERRED copies
.CW "damage(N-1) \e damage(N)"
before each flip.  The difference is the summed OVERLAP of consecutive frames'
damage and nothing else; coverage of the screen never enters.  Measured at the
.CW 'v'
present boundary on two Tk workloads at 640x480, the saving is
.B "84.9 per cent"
\(em 1770us a frame down to 261us, 1115us down to 161us, against a 16665us
budget, so 1.6 per cent of a frame instead of 10.6.
.PP
.B "Withdrawn."
Three earlier arguments for the same conclusion, all of which were wrong: that
the rule is about damage COVERING THE SCREEN (it is about overlap, at any size);
that it saves dropped frames on full-screen frames (an isolated one drops under
both schemes, the copy merely moves a frame later); and that 47 per cent of the
cost in 4 per cent of the frames was a saving (it was a description of where
eager's cost sits).
.PP
.B "And the hint this item was built around is NOT NEEDED."
Everything above assumed the copy must precede the DRAWING, so
.CW damage(N)
had to be known in advance, so a frame-level hint had to come down from libtk's
.CW tkscenebounds()
through
.CW devdraw.c
to a screen driver.  The copy only has to precede the FLIP.  At
.CW 'v'
both rectangles are already known \(em
.CW prevpresent
is
.CW damage(N-1)
and
.CW presentbb
is
.CW damage(N)
\(em so the repair happens there, between the last draw and the flip, with no
hint, no interface change and no producer in libtk.  By region:
.P1
in S and in damage(N)      back was drawn this frame.  correct.
in S, not in damage(N)     frame N == frame N-1 there, and FRONT holds
                           frame N-1.  copying front->back gives frame N.
outside S                  back held frame N-2 == frame N-1 (undamaged in
                           N-1), undamaged in N, so == frame N.
.P2
where
.CW "S = damage(N-1)"
is where the back buffer is stale.  The difference is a rectangle subtraction,
at most four rectangles.  The H1a correction that introduced the hint conflated
"before it is SHOWN" with "before it is DRAWN".
.PP
.B "The one real hazard, and it is wider than read-modify-write."
Step 2 draws into a back buffer that is stale in S.  An operation that FULLY
OVERWRITES its damage rectangle does not care.  One that does not fully
overwrite it leaves stale pixels inside
.CW damage(N) ,
which step 4 excludes from the repair, and the error is shown.  That is not
only alpha and masks:
.IP \(bu
.CW string
\(em the glyph is a MASK, so non-ink pixels inside the glyph rectangle keep
whatever the destination held.  Text is the DEFAULT case, not a rare one.
.IP \(bu
.CW line ,
.CW poly ,
.CW ellipse
\(em only the spans are written, but
.CW dstflush()
charges the whole bounding box, so the holes are inside
.CW damage(N)
and excluded from repair.
.IP \(bu
any
.CW 'd'
with a non-opaque mask, an alpha source, or an op other than
.CW SoverD .
.PP
So the only true overwrite is a fill or an opaque blit.  The question is
therefore NOT how often Tk uses alpha; it is whether Tk draws partial-overwrite
operations onto a window directly, or onto a per-widget offscreen image that is
then blitted opaquely.  Inferno's Tk is flicker-free, which suggests the second,
and that is a guess and marked as one.
.PP
.B "What makes it shippable either way."
At the first partial-overwrite operation in frame N whose rectangle meets S,
repair ALL of S eagerly, there and then.  Worst case the scheme degrades to
eager \(em 1770us, the number it was trying to beat \(em and it never degrades
to a wrong image.  That turns the measurement below into a question about
PERFORMANCE rather than correctness, and 84.9 per cent is what you get when the
count is zero.
.PP
.B "Open, and it is a measurement in devdraw rather than an argument."
In
.CW drawmesg() 's
.CW 'd' ,
.CW 's' ,
.CW 'l' ,
.CW 'p' ,
.CW 'e'
cases, where the destination is the screen or a window layer, classify each
operation as overwrite or partial and count the partial ones whose rectangle
meets
.CW prevpresent .
That is an UPPER bound, because it ignores that an opaque background fill
earlier in the same present has usually already covered the region \(em which is
the normal widget-repaint order.  Zero on Tk workloads means the scheme is
correct with no per-operation machinery at all.  Non-zero means adding the
containment test against this present's earlier opaque rectangles.  The same
hook counts operations per present, which closes the one thing the present
instrument cannot tell you on its own: whether
.CW 'v'
arrives per frame or per operation.
.PP
.B "Also owed, and only this board can give it."
The damage histogram off a real
.CW wm
session for the coverage ratio to 1228800 bytes, and whether an interactive
session looks like the two automated suites at all.  That limit has been flagged
since the first measurement and cannot be removed from the other side.
.PP
.B "The partial-overwrite counter is written."
.CW os/inferno/port/devdraw.c
now classifies every client draw operation that reaches the screen and counts
the ones that can break the post-draw repair.
.CW fulloverwrite()
is memdraw's own criterion for its opaque path \(em
.CW "mask == memopaque" ,
which is what sets
.CW Fullmask
in
.CW libmemdraw/draw.c ,
and a source carrying no
.CW Falpha ,
and
.CW op
of
.CW SoverD
or
.CW S .
The seven
.CW dstflush()
call sites are classified by command:
.P1
'd' draw     fulloverwrite(src, mask, op)
'y','Y'      FULL -- writes the given pixels over all of r
'x','s'      partial -- the glyph is a mask
'e','E'      partial -- ellipse, spans only
'l','L'      partial -- line, spans only
'p','P'      partial -- poly, spans only
.P2
.PP
.CW npartialhit
is the number that decides it: a partial operation whose rectangle, in SCREEN
coordinates after the layer walk, meets
.CW prevpresent
\(em the region where the back buffer is stale.  It is an upper bound twice
over.
.CW fulloverwrite()
does not recognise a 1x1 replicated all-ones mask, which is opaque in fact, and
the count ignores that an opaque background fill earlier in the SAME present has
usually already covered the region, which is the normal widget-repaint order.
Both errors run toward over-counting, which is the direction that cannot hide a
correctness problem.
.PP
It needed a fourth argument on
.CW dstflush() ,
and that is the whole interface change \(em no hint, no new command, nothing
from libtk.  Compiled clean with
.CW "7c -wFV"
and with
.CW 6c
for pc64, since the file is shared by every board.  Not built into a kernel: the
board is scoring
.CW b461ec5f1
alone.
.PP
.B "The mailbox half of the flip, and why the driver half is still off."
.CW mboxfballoc()
pinned virtual height to physical height, so a page flip was not possible at
all.  It now takes a virtual height:
.CW ScrY
gives exactly what it always allocated,
.CW 2*ScrY
gives two stacked buffers in ONE allocation, which is what the flip needs \(em
the firmware scans out from a virtual window into a single buffer, so two
separate
.CW ALLOCATE_BUFFER
calls would give two framebuffers the GPU cannot switch between.
.PP
.CW mboxvirtoffset(x, y)
is the flip: tag
.CW 0x00048009 ,
SET_VIRTUAL_OFFSET, which
.CW mboxfballoc()
already sends once with
.CW (0,0)
during setup, so this is a re-send rather than a new capability.  It CHECKS the
offset the firmware reports back, because the firmware clamps rather than
failing when an offset would scan past the allocation, and a silently clamped
flip shows the WRONG buffer with a success code \(em the same shape as the bug
.CW mboxprop() 's
missing lock used to have, a wrong answer rather than a detectable error.
.PP
.B "And it is OFF, gated on an audit rather than on code."
.CW "Dbuf = 0" .
A flip makes the draw buffer's address ALTERNATE every frame, and several things
hold or compare it:
.P1
fbsaveunder()/fbrestoreunder()  save the cursor's pixels by address
the tear probe                  keys on par->dst->data == gscreen->data
dstflush() in devdraw.c         compares l->screen->image->data
                                against screenimage->data
memlayer                        holds the screen image
.P2
Every one of those fails SILENTLY if it caches a stale buffer: a cursor restored
into the buffer that is no longer visible, a tear probe reporting zero because
its identity test never matches, a layer that stops flushing.  None would
announce itself, and a tear probe reading zero would look like the flip WORKING.
That is the reason the flag is 0 and not 1, and the audit is the next piece of
work on this item rather than the flip itself.
.PP
.CW raspi4
has its own
.CW mailbox.c
and
.CW screenbcm.c
with its own five-argument
.CW mboxfballoc() ,
and is untouched.
.PP
.B "The audit is done, and three of its four items were not hazards."
.CW attachscreen()
hands devdraw the
.CW Memdata
ITSELF, which
.CW allocmemimaged()
shares into the screen
.CW Memimage .
.CW Memimage.data
is a
.CW "Memdata *" ,
and the byte pointer is
.CW Memdata.bdata
inside it.  So reassigning
.CW bdata
propagates to every
.CW Memimage
sharing it at once, and every identity test in the system keeps working, because
every one of them compares the Memdata POINTER and not the bytes:
.P1
devdraw.c:639   l->screen->image->data != screenimage->data
devdraw.c:901   l->data == screenimage->data
devdraw.c:2097  dst->layer->screen->image->data == screenimage->data
devdraw.c:2286  lp[0]->layer->screen->image->data == screenimage->data
screenbcm.c     par->dst->data == gscreen->data   (the tear probe)
.P2
I listed the tear probe and
.CW dstflush()
as hazards.  They are not, and neither is
.CW memlayer ,
whose per-layer
.CW save[]
are their own allocations.  The worry that a tear probe reading zero would look
like the flip working was real as a worry and false as a fact.
.PP
.B "So the flip is three lines."
.P1
scrdata.bdata = base + (front? ScrY*stride: 0);
fb = vfb = scrdata.bdata;
mboxvirtoffset(0, front? 0: ScrY);
.P2
.PP
.B "And ONE real hazard survives, which is the cursor."
.CW fbsaveunder()
copies the pixels under the cursor out of
.CW fb
and
.CW fbrestoreunder()
puts them back, with
.CW underok
and
.CW curslast
persisting BETWEEN frames.  A save taken in frame N and restored after a flip
writes frame N's pixels into the buffer that is now visible, at a moment when it
holds frame N-1.  The fix is one line at the flip \(em
.CW "underok = 0"
\(em because the cursor is recomposed on the next flush anyway, and invalidating
is cheaper than remembering which buffer a save came from.
.PP
.CW memdraw
computes byte addresses per call and the flip happens at
.CW 'v'
with
.CW drawlock
held, so nothing holds a byte address across it.
.PP
.B "What is written and what is not."
Written: the mailbox half
.CW ( mboxfballoc 's
virtual height,
.CW mboxvirtoffset ),
the per-present measurement in
.CW devdraw.c ,
and the partial-overwrite counter.  Not written: those three lines, the
.CW underok
invalidation, and the deferred repair at
.CW 'v' .
Nothing is on the board, which is scoring
.CW b461ec5f1
alone.
.PP
.B "The flip and the deferred repair are written, and the hazard measured away."
The peer ran the partial-overwrite counter on
.CW "runtests -g"
at 640x480:
.P1
s x l p P e E reaching the damage path      0
'd' ops that do not overwrite their rect    0 of 8628
.P2
Tk sends no string, line, polygon or ellipse to a window or to the screen, and
every blit it does send is
.CW SoverD
with an opaque mask and an alpha-free source \(em it renders into per-widget
images and blits them opaquely, which is why it is flicker-free.  So the
post-draw repair is correct with no per-operation machinery.
.PP
.B "Both zeroes have controls," 
which matters because a zero from a predicate never shown able to fire is not a
measurement: the op tally proves the instrument sees operations at all (2644
.CW 'd'
rectangles plus others), and inverting the opacity test to
.CW "op == SoverD"
gives 8628 of 8628.
.PP
.B "And the limit is real."
With the operation term legitimately zero, the mask-alpha and source-alpha terms
were never exercised.  They are UNTESTED rather than confirmed.  A workload
blitting an alpha image straight to a window would test them; the games and
draw3d go through other paths.
.PP
.B "What is now in the tree."
.CW bcmpresent() ,
called from devdraw's
.CW drawpresent()
through a function POINTER
.CW ( screenpresent ,
nil by default, so no board needs a stub \(em the same shape as emu's
.CW gpudrawflush ):
.P1
1. copy dmgprev \e dmg from FRONT to BACK   (|damage(N-1) \e damage(N)|)
2. mboxvirtoffset to show BACK
3. fb = vfb = scrdata.bdata = the old FRONT
4. underok = 0                             (the cursor hazard)
5. dmgprev = dmg
.P2
with
.CW rectsub()
giving the difference as up to four rectangles.  A failed or clamped
.CW mboxvirtoffset()
returns WITHOUT swapping
.CW fb ,
because swapping it then would draw the next frame into the visible buffer with
no repair behind it \(em a stale frame is better than that.
.PP
.B "A bug found by re-reading, which is the kind this would have hidden."
The first version of the repair had the source ternary inverted and copied the
back buffer onto itself.  A no-op whose only symptom is subtly stale pixels in
whatever a frame did not redraw \(em the hardest wrong picture to notice.  The
two halves are now behind
.CW frontaddr()
and
.CW backaddr()
rather than written inline at each use, which is the fix, not the sign flip.
.PP
.B "Still not tear-free, and the comment in the file now says so."
.CW bcmpresent()
does not wait for vertical blank, so the flip itself becomes the tear line \(em
the tear MOVES rather than vanishing.
.CW mboxvsync()
exists and
.CW vsyncprobe()
measures the period, but a vsync wait holds the mailbox lock for a whole frame
and whether that is affordable is its own measurement.  Double buffering as
written removes the half-drawn frame; it does not yet promise a clean one.
.PP
.CW "Dbuf = 0" .
Compiled clean; nothing has run on the board, which is scoring
.CW b461ec5f1
alone.
.PP
.B "Why none of this has been LINKED, which is a better reason than host load."
Everything above was compiled file by file with
.CW "7c -wFV"
(and
.CW 6c
for the shared port file) and deliberately not linked.  The reason recorded
earlier was that heavy host work during a batch is a confound, and that is true
but secondary.  The real one:
.PP
.CW tools/jtag/vmheld ,
.CW kstack ,
.CW where
and
.CW wedgediag
all read the board by ADDRESS, and all of them check the board's
.CW kerndate
word against the one in
.CW os/inferno/raspi3b/kernel8.img
and REFUSE when it differs \(em which is the thing that makes them trustworthy.
Linking replaces
.CW iraspi3b
and
.CW kernel8.img ,
so a link mid-batch does not merely load the host: it DISARMS every diagnostic
the batch exists to feed.  If run 18 wedges, the tools would correctly refuse to
name a symbol, and the catch would be wasted.
.PP
So the ordering is forced, and it is not a preference: finish the batch, then
link.  The compiles establish that the code is syntactically sound and type
correct; they say nothing about symbols, and the link waits.
.PP
.B "Two defects in the instruments above, found by re-reading rather than by running."
.PP
.B "A unit mismatch that made one counter unreachable."
.CW ndeferover
counts frames whose deferred copy alone exceeds a frame, and it compared a
microsecond cost against
.CW vsmeasured ,
which
.CW teararm()
sets from
.CW cycles()
and is therefore in 19.2MHz TICKS.  At that rate a 16.665ms frame is 320000,
so no damage-sized copy in microseconds ever exceeded it and the counter could
only ever read zero once the probe had run.  A zero from a predicate that
cannot fire is not a measurement, which is the rule this item has been applying
to everyone else's numbers.  Fixed with
.CW vsmeasuredus
alongside, converted with the same
.CW m->cpuhz
.CW vsyncprobe()
uses, and the report now labels both units.
.PP
It is the same class as the 196-against-197: a plausible number whose DIMENSION
nobody checked.
.PP
.B "And the non-flipping numbers are a prediction, which the comment now says."
The per-present accounting runs on every board that links
.CW devdraw.c ,
but where
.CW screenpresent
is nil nothing is ever swapped, so eager and deferred are "what the two schemes
WOULD cost if this board flipped".  That is deliberate \(em the point is to
decide whether a board should flip before making it \(em but a reader of pc64's
or virt's numbers is reading a hypothetical, and nothing said so.
.PP
.B "A lock constraint on the next step, which is the vblank wait."
.CW bcmpresent()
runs with
.CW drawlock
held and
.CW mboxvirtoffset()
takes
.CW mboxlock .
As it stands that is safe: a property exchange is short, and nothing holding
.CW mboxlock
wants
.CW drawlock ,
so there is no deadlock and only a brief coupling.  A vsync wait is a different
thing \(em it holds
.CW mboxlock
for a WHOLE FRAME, and doing that under
.CW drawlock
would stop every Dis draw operation in the system for up to 16.7ms while also
starving
.CW sdhostbcm ,
.CW sdhcibcm ,
.CW btbcm
and
.CW pwmbcm ,
all of which return to the mailbox at runtime.
.CW mboxprop() 's
own comment already rules out a periodic vsync kproc for exactly this reason.
.PP
So landing the flip in vertical blank needs the wait OUTSIDE both locks.  That
is a design question, not a line of code, and it is the gate on tear-freedom
rather than on double buffering.
.NH 2
H4.  kmesg has no build-stamp check, and the batch's wedge/slow split depends on it
.LP
Checking the batch's own predicates rather than trusting them turned up a worse
version of the no-link rule recorded above.
.PP
.CW tools/jtag/vmheld ,
.CW kstack ,
.CW where
and
.CW wedgediag
all compare the board's
.CW kerndate
against
.CW kernel8.img
and REFUSE on mismatch.
.CW tools/jtag/kmesg
does not.  It resolves the
.CW kmesg
symbol out of the ELF and reads that address, so after a relink it reads the NEW
kernel's address on the OLD running kernel, and prints garbage or nothing.
.PP
.B "And kmesg is the tool the classification turns on."
.CW hunthang2.sh
decides whether a 600s timeout was a wedge or merely slowness with
.P1
if ! sh tools/jtag/kmesg | grep -q 'DIS-WEDGED'; then  ... SLOW ...
.P2
so a relink makes that grep fail and EVERY WEDGE IS SILENTLY SCORED SLOW.  A
refusal wastes a catch and says so; a missing check corrupts the result and does
not.  The acceptance number this batch exists to produce is a wedge count, so
that is the one failure mode that would invalidate it without appearing anywhere.
.PP
.CW kmesg
is NOT being changed while the batch runs: the stamp currently matches, so a
check would be a no-op, and a buggy one would break the very detection it is
meant to protect.  It is also why
.CW hunthang2.sh
itself is not being edited \(em
.CW sh
is executing that file right now.  Both after the batch.
.PP
.B "What the batch's predicates DO establish, having read them."
.IP \(bu
HANG: a unique per-run token
.CW ( H2 <i>-<epoch>)
must appear within 40 polls of 15s.  Unique per run, so it cannot be satisfied
by an earlier run's output.  Sound.
.IP \(bu
CLEAN:
.CW EFS-FAULT-OK
in the console snapshot.  The marker is NOT unique, which would be contaminated
by earlier runs if the log accumulated \(em it does not.
.CW board.out
is a rolling
.CW "screen -X hardcopy"
snapshot, overwritten each refresh (2995 bytes mid-run, with no earlier run's
tokens in it), and the end token is echoed AFTER the suite, so when the token is
visible the OK line is still on screen above it.  Sound, for a reason that had
to be checked rather than assumed.
.IP \(bu
SLOW: counted, and the loop continues rather than exiting \(em which is the
whole point, since aborting on slowness would make the wedge count
unmeasurable.
.PP
So "19 clean, 0 slow, 0 wedges of 30" is a real reading, and the one thing that
could have silently falsified it is a relink, for the
.CW kmesg
reason above rather than for host load.
.PP
.B "It LINKS, verified without disarming anything."
A compile proves syntax and types and says nothing about symbols, and the
no-link rule above is about
.CW iraspi3b
and
.CW kernel8.img
specifically \(em not about linking as such.  So: compile the three changed files
into the tree, capture the real link line with
.CW "mk -n" ,
and run it with the output redirected to the scratchpad.
.P1
7l -o <scratch>/iraspi3b.linktest -H7 -T0x80000 -R4096 -l ...   rc=0, 3228778 bytes
iraspi3b, kernel8.img                                           untouched, 06:25:17
.P2
Every JTAG reader stays armed and the batch's wedge/slow classification is
intact, because neither artefact they key on moved.
.PP
The new symbols all resolved, read back with the tree's own
.CW tools/jtag/ksyms :
.P1
0x00082e84 t bcmpresent
0x0016450c T mboxvirtoffset
0x0019a5cc T drawpresent
0x0019a998 T drawpresentstats
0x001d6878 d nflip
0x001d6b60 D npartialhit
0x001d9338 D screenpresent
0x001d93a8 d vsmeasuredus
0x001dab50 D presentoverlap
.P2
The counters are DATA in the symbol table, which is the point of putting counts
in variables rather than prints: they can be read off a wedged or slow board by
address with no kernel change.
.PP
.B "One consequence to remember: the tree's objects are now NEWER than iraspi3b."
So any
.CW mk
in
.CW os/inferno/raspi3b
will relink and replace the artefacts the JTAG tools key on.  That is exactly
what the post-batch step wants and exactly what must not happen before it.
.NH 2
H4.  7c exits ZERO on an implicitly declared function, so a build filter cannot see it
.LP
A peer found that kencc never prints
.CW "error:" ,
so a filter tuned on clang's wording misses every kernel compile failure, and
proposed
.CW mk 's
own
.CW "exit status=exit(1)"
as the toolchain-independent signal.  That is right and it is not sufficient.
Measured by appending each error kind to a real kernel source and reading both
the status and whether an object appeared:
.P1
injected error                      7c exit   object written
syntax error                            1         no
name not declared (a variable)          1         no
structure not fully declared            1         no
function not declared                   0        YES
.P2
.PP
An implicit function declaration is a WARNING here.
.CW 7c
prints the diagnostic, WRITES THE OBJECT, and exits 0 \(em so
.CW mk
prints no
.CW "exit status"
either, and neither an
.CW "error:"
grep nor a status check nor the exit-status pattern sees it.  The peer's own
counterexample,
.CW "mailbox.c:484 function not declared: mboxtagprobe" ,
is exactly this case, which means that build did not merely fail quietly:
.CW 7c
reported SUCCESS and
.CW mk
archived an object.  That is why the stale kernel ran.
.PP
.B "And it is the dangerous case, not just the sneaky one."
The link is the backstop, but only when the symbol does not exist.  A misspelled
call that happens to match ANOTHER real symbol compiles, links, and misbehaves at
runtime with no diagnostic anywhere.  The reliable catches are reading the
diagnostic TEXT and a successful link:
.P1
7c ... -o <scratch>/x.7 f.c > out 2>&1; echo $?; grep -c 'not declared' out
.P2
Checked on this session's three changed files: exit 0, zero
.CW "not declared"
diagnostics, zero output of any kind.
.PP
.B "A second instrument bug of mine, and it invalidates a number stated above."
.CW "cmd | head -20; echo \(dqrc=$?\(dq)"
reports HEAD's status, not the command's.  The
.CW rc=0
recorded earlier for the scratch link was therefore meaningless.  Re-run with the
output redirected and
.CW $?
captured on the bare command, the linker's real status IS 0 with no diagnostics
and a byte-identical 3228778-byte output \(em so the conclusion stands and the
evidence given for it did not.  The substantive evidence was always the output
file plus
.CW ksyms
resolving the new symbols.
.PP
.B "What generalises, and it is the peer's method rather than either finding."
Reading a predicate tells you what it MATCHES; firing it tells you what it
MISSES.  They found the kencc wording by injecting a real syntax error instead of
re-reading the filter, and the
.CW 7c
table above exists only because they did.  Of the four ways a correct number
lies, this is the only one with a reliable procedure attached: break the thing
deliberately and check the instrument notices.  It is the same move as auditing a
harness that is producing a result you like.
.PP
.B "Refinement, and it is worse for me and better for the tree."
Checking whether the
.CW kmesg
flaw is in COMMITTED tooling or only in my scratch batch script: only mine.
.CW tools/jtag/boot.sh
already does it correctly, and its comment says this exact bug bit before \(em
.P1
# kmesg's OWN failure is reported rather than swallowed: it exits 1
# when the debugger hands back nothing and 2 when what it hands back
# reads as an empty ring, and both used to arrive here as "the board
# printed no banner", which is the same answer as a board that did
# not boot.  Four attempts were reported that way for a kernel that
# was running.
.P2
so it redirects, tests
.CW $? ,
and reports
.CW kmesg 's
own stderr separately before concluding anything about the board.
.CW wedgediag
only dumps the ring for a human and branches on nothing.
.PP
So the pattern was already in the tree, with the scar tissue attached, and my
batch script reimplemented the check without it.  That is a worse failure than
not knowing: the lesson was written down ten feet away.
.PP
.B "And it narrows what kmesg actually misses."
It is not blind \(em it exits 1 when the debugger answers nothing and 2 when the
ring reads empty.  What it has no check for is a WRONG KERNEL: after a relink it
resolves
.CW kmesg
to the new kernel's address and reads that address on the old running one.
Whether that presents as an empty ring (caught, exit 2) or as plausible garbage
(not caught, exit 0) depends on what the arbitrary
.CW n
word at the wrong address happens to hold, and is untested.  So the
misclassification is PROBABLE rather than certain, which is not a better place to
be: it means a relink would corrupt the wedge count some of the time, which is
harder to notice than always.
.PP
Two fixes, both after the batch: give
.CW kmesg
the
.CW kerndate
check its siblings have, so the wrong-kernel case is certain rather than
probabilistic; and make the batch test
.CW kmesg 's
exit status the way
.CW boot.sh
does, so "could not read the ring" is a third verdict and not silently folded
into SLOW.
.PP
.B "CORRECTION to the paragraph above: the peer's incident was NOT the exit-0 case."
I wrote that their
.CW "function not declared: mboxtagprobe"
build "did not merely fail quietly:
.CW 7c
reported SUCCESS and
.CW mk
archived an object."  That is true of my table and false of their example.  Their
build ALSO printed
.CW "external redeclaration of: mboxtagprobe"
with conflicting types, which is a hard error.  Reproduced here:
.P1
void zz(void){ gg_nosuch(); }                      exit=0  object=YES
    function not declared: gg_nosuch

void zz(void){ gg_conflict(); }                    exit=1  object=NO
u32 gg_conflict(void){ return 1; }
    function not declared: gg_conflict
    external redeclaration of: gg_conflict
.P2
So
.CW mk
DID print
.CW "exit status=exit(1)"
on their build, and their stale kernel ran because their filter was not looking
for it \(em the TEXT gap, since kencc never says
.CW "error:" .
Two different holes, and I attributed mine to their example.
.PP
.B "And the correction sharpens the finding rather than softening it."
The exit-0 case is specifically a call to a function NOT DEFINED IN THAT
TRANSLATION UNIT.  When the callee is defined later in the same file with a
different type, kencc catches the conflict and fails.  So the silent case is the
ordinary cross-file call with a missing
.CW extern
declaration \(em which is the normal shape of kernel code, not an exotic one.
The link backstops it only when no symbol of that name exists anywhere.
.PP
So for kencc the catches are: a clean link, plus
.P1
grep -cE 'not declared|redeclaration' <compile output>
.P2
and the status alone is not one of them.
.NH 2
H4.  The implicit-declaration audit: 110 linked sources, ZERO, and 12 false findings on the way
.LP
Since
.CW 7c
writes an object and exits 0 for a call to a function not declared in the
translation unit, any such call in this kernel compiles and links today and
misbehaves only if the name happens to match some other symbol.  That had never
been checked, so:
.P1
110 linked C sources, compiled with the build's own flags
0 with 'not declared' or 'redeclaration' diagnostics
2 of the 112 objects have no .c (generated or assembly)
.P2
Clean.  A statement not available without looking.
.PP
.B "And the two sweeps before it produced twelve findings, all artifacts."
Worth recording because each looked exactly like a real bug.
.IP \(bu
Sweeping
.CW "raspi3b/*.c"
flagged
.CW "raspi3b.c:132 name not declared: KERNDATE" .
The mkfile compiles that file with
.CW "'-DKERNDATE='$KERNDATE"
and my hand invocation had no such define.  One false finding.
.IP \(bu
Sweeping
.CW "../port/*.c"
flagged eleven files \(em
.CW devboot ,
.CW devns16552 ,
.CW devpci ,
.CW devproc ,
three
.CW flash* ,
.CW iomap ,
.CW pciecam ,
.CW portclock ,
.CW rdb
\(em with plausible-looking misses like
.CW "function not declared: segflush"
and
.CW "function not declared: kmapinval" .
NONE of the eleven is linked into this kernel.  They are port files for other
boards, compiled against raspi3b's headers, missing the per-board declarations
their own configs supply.
.PP
The fix was to stop guessing at the file set and take it from the LINK LINE:
.CW "mk -n"
gives the real
.CW OBJ
list, every
.CW .7
maps to a source, and that is the only set the build actually compiles.  Two
wrong file sets and one wrong flag set, twelve findings, zero real.
.PP
.B "Which is the same error as everything else in this item, at the input end."
An audit is an instrument, and its SCOPE is a parameter like any other.  Running
a correct check over the wrong file set produces correct diagnostics about code
that is never built \(em a measurement of the wrong population, next to the
measurement of the wrong quantity and the comparison of incommensurable units
already recorded above.  The control is cheap and I nearly skipped it: ask
whether the thing you just flagged is in the artefact you care about.
.NH 2
H4.  kaudit(1), and the truncating PADDR it found on its first control run
.LP
The hand audit above is now
.CW tools/kaudit ,
because the two mistakes that made its first sweeps useless are avoidable by
construction.  Both the FLAGS and the FILE SET come from
.CW "mk -n -a" ,
which prints every recipe without running any of them \(em so per-file defines
like
.CW -DKERNDATE
are included and the file set is exactly what the kernel compiles.  Objects go to
a temp directory, so
.CW i$CONF
and
.CW kernel8.img
are never replaced and the JTAG readers stay armed.
.PP
.B "It refused before it worked, twice, and both refusals were the design working."
First run: no compile lines matched, and it said
.CW "that is a FAILURE of this tool, not a clean audit"
rather than reporting zero.  The pattern
.CW "^[0-9]?[a-z]c"
wanted three characters and
.CW 7c
is two.
.PP
Second: 39 of 110 sources.
.CW mk
prints recipes for a mkfile own targets at column 0 and inherited ones
TAB-INDENTED, so a pattern anchored at column 0 saw every board file and not one
of
.CW ../port
or
.CW ../ip
\(em and would have reported "clean" over a third of the kernel without saying it
was a third.  That is the third too-narrow pattern of the session, after the
monitor filter and the two audit sweeps.
.PP
.B "Then the can-it-fire check, which is the only procedure of the four:"
run it with a pattern known to match.
.CW "PAT='shorter integer'"
produced two findings, so the tool is not blind \(em and the two findings were
real.
.NH 3
PADDR() truncated a 64-bit pointer into 64-bit fields
.LP
.CW "#define PADDR(v) va2pa((void*)(v))"
and
.CW va2pa
returned
.CW ulong .
Measured with a compile-time assertion rather than assumed:
.CW ulong
is 4 bytes on this kernel and pointers are 8.
.PP
.B "And the callers are 64-bit."
.CW ../port/xalloc.c
\(em which IS linked into raspi3b \(em calls
.CW "xhole(PADDR(a), t)"
three times, and
.P1
xhole(uintptr addr, uintptr size)
struct Hole { uintptr addr; u64 size; uintptr top; Hole *link; };
.P2
so the allocator record is 64-bit correct and the macro feeding it truncated.
.CW virtarm64/ethervirtiommio.c
is worse: it puts
.CW PADDR()
straight into a virtio DMA descriptor address.
.PP
.B "Harmless here, a silent corruptor elsewhere."
raspi3b has
.CW "KZERO == PHYSDRAM == 0"
and 1GB of RAM, so every address is below 4GB and the truncation never bites.
On an arm64 board with memory above 4GB \(em raspi4 goes to 8GB,
.CW virtarm64
takes whatever QEMU is given \(em
.CW xalloc
records the wrong hole and a device DMAs to the wrong physical page, with
nothing reported anywhere.
.PP
Fixed to
.CW uintptr
in
.CW fns.h
and
.CW main.c
on raspi3b, raspi4 and virtarm64, with the reason in the code.  Verified by
.CW kaudit
on raspi3b and virtarm64: the
.CW main.c
warning is gone from both.
.NH 3
The two truncations NOT changed, and why
.LP
.CW ../port/devkprof.c:73 ,
.CW "kprof.maxpc = (ulong)etext" .
.CW kprof.minpc
and
.CW maxpc
are BOTH
.CW ulong
by design, with a comment in the struct saying so, so the truncation is
internally consistent: both ends truncate the same way, the difference is right,
and the profiler works for any text segment under 4GB.  Self-consistent rather
than wrong.
.PP
.CW virtarm64/screenarm.c:203
prints
.CW "(ulong)fb"
with
.CW %lux .
A diagnostic, not a DMA path \(em it would print a wrong address on a
high-mapped framebuffer, which is worth fixing on the board that owns it and is
not this one.
