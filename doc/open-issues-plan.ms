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
6  B1  efs's quadratic allocation         DIAGNOSED; fix is lazy decode
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
B1.  DIAGNOSED.  Node.unpack allocates per entry in a block
.LP
.B Established.
.CW efs
allocates more heap per operation the more entries the
.I filesystem
holds \(em not the directory, which was measured and falsified earlier.  With
the written file's parent held at two entries:
.P1
fs 2 entries	 328 alloc/op
fs 62 entries	1372 alloc/op
fs 242 entries	1989 alloc/op
.P2
.CW memfs
mounted the same way is flat, so the term is
.CW efs 's.
Not a leak: live blocks fall during the work, so the ceiling is the high-water
of garbage.
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
.B "And the target is fixup, which is a THIRD answer."
The plan said, two commits ago, that the cost was
.CW replace 's
leaf rebuild.  That was read off arm A alone, where it is exactly true \(em
.CW replents/op
is 22.0 and the total entries unpacked is 22 \(em and arm A is a filesystem of
two entries, whose whole tree is one leaf with no parents at all.  Instrumenting
the large case instead:
.P1
fs 242 entries   alloc/op 2000   repl/op 4.0   replents/op   6.0
                                 rangeents/op 0.0   fixents/op 660.0
.P2
.CW Fs.fixup
is 660 of the 789.  It walks back up the tree after a leaf is rewritten, and for
each level it
.I decodes the parent ,
rebuilds every entry of it, and re-packs \(em to change one child pointer.  An
interior node near the root of a 242-entry filesystem holds hundreds of entries,
and copy on write means this happens on every modifying operation.
.PP
.B "Which makes the fix small, because interior entries are fixed width."
.CW Keysz
is 17, an interior value is always the 8 bytes of a block number, and the length
field is 2: an interior entry is exactly 27 bytes and never changes size.  So in
the common case \(em
.CW "len kids == 1" ,
no split \(em the parent needs no decoding at all.  Copy its block, walk the entry
headers to the offset of entry
.CW at
without allocating, overwrite 17 bytes of key and 8 of value, restamp the
checksum the way
.CW Node.pack
does
.CW ( "(a, c) := checksum(b, Nocksum)" ,
then
.CW put2
at
.CW Nocksum
and
.CW Nocksum+2 ),
allocate a block, write it, free the old.  The split case keeps the existing
decode-and-rebuild path, which is rare and genuinely needs it.
.PP
.B "Three answers, and why the first two were wrong in the same way."
Keeping decoded nodes: measured, no effect, because copy on write renumbers.  A
lazy descent: measured, no effect, because the entries are not in the interior
nodes the descent reads \(em except that they
.I are ,
when
.CW fixup
rewrites those same nodes, which is what the third measurement found.  And
.CW replace :
true only of a one-leaf filesystem.
.PP
Each was a reading of one arm generalised to all three.  The instrument that
settled it attributes entries to their caller and is run at
.I both
ends of the range, which is what the earlier measurements should have done.
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
