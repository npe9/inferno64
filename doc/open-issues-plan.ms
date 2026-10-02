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
.NH 1
B.  efs
.NH 2
B1.  The rate: 40 per cent of it fixed (the OOM is B1c)
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
which caches 9-sector tracks and does read-modify-write, and a commit rewrites
a path.  So B1's quadratic is real, is now attributed, and is NOT what makes a
create slow on this board.  The next measurement is writes per commit and
microseconds per write through
.CW dossrv ,
and the one after it is whether efs on a raw partition \(em which
.CW EFS-NOROOM
says there is no room for on this card \(em is a different machine entirely.
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
B1e.  A write no longer commits per message \(em and two things that stopped it going further
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
.B "REVERTED: deferring the create commit too."
A create leaves a fid that 9P requires to be clunked, so the clunk could
commit it, and for the common
.CW "echo x > file"
that would halve the commits \(em the creates workload still pays two, one
for the Create and one for the Clunk, and batching the write changed
nothing there because an 8-byte write never reaches the bound.
.PP
It broke two suites and the reasons are not understood:
.CW efs-write
reported "5 blocks in use before, 233 after \(em 228 leaked", and
.CW efs-stress
hung.  A first guess was wrong and is worth recording: the stress failure
first appeared as
.CW "interior block 4095: interior entry 0 is not a pointer" ,
block 4095 being
.CW superblk(4096,1) ,
so the allocator had handed out superblock 1 and a tree node had been
written over it.  Guarding that in
.CW Fs.alloc
did not fix either suite, so the leak and the hang are something else.
.PP
.B "The guard stays, because the invariant should never have depended on the map."
.CW Fs.alloc
now refuses block 0 and block nblocks-1 whatever the free map says.
.CW mkefs
does mark both used, so a bit is being cleared somewhere, and that is still
open \(em but overwriting superblock 1 destroys the copy the whole format
exists to fall back to, and that must not be one bad bit away.  It also
explains a reading in G1: efsck's "block 16383 is in the tree and free in
the map" on this board's image was this, not corruption.
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
G1.  efs can commit a superblock whose tree is not all on the medium
.LP
.B OPEN.
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
.B "Hypothesis, NOT established."
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
G1a.  STILL OPEN \(em what mount checks is a spine, not a proof
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
.NH 2
G1b.  STILL OPEN \(em and the cause is still not established
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
