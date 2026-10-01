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
A5.  A pointer cast through long in the JIT
.LP
.B Established.
.CW comp-aarch64.c
computes code offsets as
.CW "(long)(code - ptr)"
and
.CW "(long)(IA(...)) - (long)(code + codeoff)" ,
with
.CW SZ_LONG
at 4.  Before
.CW dcca478dd
the cast was dropped; now it is obeyed.
.PP
.B "Not a bug today, and the reason is not 'addresses are small'."
It is that these are differences between two addresses in the same allocation,
and the destination is a 4-byte
.CW long
in any case.  Truncating both operands of a subtraction preserves the
difference whenever it fits, and a branch displacement inside one code buffer
always does.
.PP
.B The work.
.CW uintptr
rather than
.CW long
at those casts, and at the
.CW off
variables that receive them \(em changing one without the other buys nothing.
Rebuild, confirm the
.CW "MOVW Rn,Rn"
sites in
.CW punt ,
.CW commframe ,
.CW commcall ,
.CW comp
and
.CW compile
are gone from the
.CW -S
output, and boot: anything that runs Dis exercises the JIT, so
.CW DRAW-OK
and the efs checks cover it.
.PP
.B Priority.
Low, and honestly so.  It is hygiene: making the source say what it means.
Nothing in the tree miscomputes because of it, and the scan above says nothing
newly truncated is dereferenced.
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
B1.  40 per cent of it fixed; the rest still grows
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
B1b.  The collector's trigger, and why the OOM is retention after all
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
