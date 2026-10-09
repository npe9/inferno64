.TL
Improving kencc's code quality without making it bigger
.AU
raspi3b-port
." P1/P2 are Plan 9 troff additions and groff -ms does not define
." them: without this every .P1 block renders as FILLED PROSE, which
." is not an error so no lint catches it.  Checked by
." tests/troff-p1.sh.
.de P1
.DS L
..
.de P2
.DE
..
.NH 1
What this is for, and what it refuses to do
.LP
kencc is small, and that is a feature.
.CW utils/7l
is 20734 lines for a whole linker and
.CW utils/7c/txt.c
is 1538 for a code generator's whole text layer.
.B "Anything proposed here that costs more lines than the pass it protects is the wrong answer,"
however correct it would be, because the next person's ability to read the
compiler end to end is itself the property that has let this tree find eleven
silent miscompiles.
.LP
So the budget is stated first and numerically:
.B "about 1 per cent of"
.CW utils/ ,
roughly 200 lines total, and three of the five items below are expected to come
out
.I negative .
A plan that needs more than that is a plan to replace kencc rather than improve
it, and that is a different document.
.NH 1
The evidence, which is not generic
.LP
This tree has caught eleven defects in kencc, every one of them a
.I "silent miscompile"
\(em the compiler exited 0 and the program was wrong:
.P1
 1  7c gmove dropped a narrowing cast        a (s32) cast emitted nothing
 2  7c gmove dropped the widening move       negative int zero-extended
 3  7l addpool sized the slot by opcode      64-bit constant, 4-byte slot
 4  7l/6l emitted a branch to itself         inside panic(), both arches
 5  7l conditional branch to an indirect one  BEQ to a B (R) target
 6  loader spliced a pool into a CASE table  jump tables silently broken
 7  kencc emitted an UNDEFINED instruction   all-ones logical immediate
 8  6l -u recorded relocations a byte early   every DLM relocation
 9  unsigned switch of >=5 cases miscompiled
10  7c pointer + negative int, no sign extend
11  6c -S writes the object as a side effect
.P2
.B "They fall into four shapes, and only four."
That is what makes a small plan possible: there is no need to verify the
compiler in general, only to make these four shapes loud.
.NH 2
Shape A: a predicate decides from the wrong property
.LP
Defects 1, 2 and 3.
.CW gmove 's
.CW samaddr()
test answers
.I "are the source and destination the same address?"
and the caller treats a yes as
.I "the move is redundant."
.B "On a target with 32-bit subregisters that implication is false:"
a same-register
.CW MOVW
on AArch64 is
.CW SXTW ,
which truncates and sign-extends and is not a no-op.  Defect 3 is the same
shape in the loader \(em
.CW addpool
chose a slot width from
.CW "p->as == AMOV"
rather than from the constant it was storing.
.B "In both cases the code asks about identity or opcode when the question is about WIDTH."
.NH 2
Shape B: an impossible state is declared and handled
.LP
Defect 3 again, from the other side.
.CW C_VCON
is declared in
.CW utils/7l/l.h
and
.CW cmp()
has a case for it at
.CW span.c:845
that aliases it to
.CW C_LCON
\(em but
.B "aclass() never returns it,"
so that case cannot fire and 7l classifies every integer constant as
.CW C_LCON
whatever its width.  A reader seeing
.CW "case C_VCON"
reasonably concludes the loader distinguishes constant widths, and writes code
that relies on it.
.B "Verified: C_VCON is the only such value."
A sweep of every
.CW C_*
matched in
.CW optab.c
against everything produced in
.CW span.c
finds zero others \(em and the first version of that sweep reported twelve,
because it looked only inside
.CW aclass() 's
body and missed the
.CW autoclass[]
and
.CW oregclass[]
tables that
.CW constclass()
indexes.
.NH 2
Shape C: a layout or peephole pass emits what cannot be accepted
.LP
Defects 4, 5, 6, 7.  A branch to itself, a conditional branch whose target is an
indirect branch, a literal pool landing inside a jump table, an unencodable
logical immediate.
.B "All four are properties of a single instruction or of one pair,"
checkable at the moment the bytes are produced, with no dataflow and no
analysis.
.NH 2
Shape D: host-type leakage
.LP
Defects 8 and 11, and a hazard behind several others: kencc's own source assumes
a
.B "32-bit"
.CW long
and is compiled on a host where it is 64.
.B "This bit the author of this plan today,"
while auditing compilers for exactly this class: a probe written with
.CW long
as "the 64-bit type" made 6c look like it was dropping sign extensions on four
paths out of five, and 6c was correct.
.NH 1
The five items
.NH 2
1. One emit-time invariant check per loader
.LP
.B "The single highest-value item, and it needs one call site."
.CW utils/7l/asm.c:63
already reads
.P1
o = oplook(p);
asmout(p, o);
.P2
for every instruction in the program.  A
.CW checkout(p, o)
between those two lines sees every instruction with its chosen encoding.
.LP
.B "It asserts; it does not transform."
That distinction is the whole complexity argument \(em a check that refuses adds
a conditional, while a check that repairs adds a pass.  Each assertion is three
to eight lines and uses the existing
.CW diag() ,
which
.CW asmout.c
already calls sixty times:
.P1
a branch whose target is itself                     defect 4
a conditional branch to an unconditional indirect   defect 5
a pool entry inside a CASE/BCASE span               defect 6
a logical immediate that is not encodable           defect 7
a pool slot narrower than the constant in it        defect 3
.P2
.B "Five of the eleven become build failures,"
in the tree that produced them, with no test to run and nothing to remember.
.B "The marginal gain is smaller than that and should be said:"
the suite already catches 3, 4 and 5 after the fact, so what item 1 adds
outright is 6 and 7 \(em the pool spliced into a CASE table and the
unencodable immediate, which nothing covers today \(em and for the other three
it moves the catch from "a test notices later" to "the build refuses now".
.B "That difference is not cosmetic:"
defect 4 was in
.CW panic()
of
.B "every real kernel"
and was found by scanning a binary rather than by any test \(em and a test only
fires when someone runs it, whereas the build refuses every time.
Cost: about 60 lines in a new
.CW utils/7l/check.c
plus one call.  The same file ports to
.CW 6l
with the branch and immediate rules changed.
.LP
.B "The thing to resist"
is making this a verifier.  It must not know about registers, liveness or
types; the moment it needs a second pass over the program it has left the
budget.
.NH 2
2. Make the redundancy predicate about width, and delete the patches around it
.LP
.CW samaddr()
has
.B "exactly one call site"
\(em
.CW txt.c:1053
\(em and one definition at
.CW txt.c:1358 .
Two of the eleven defects are in that one
.CW if .
.LP
Today the call site is guarded by patches, including one added by this tree
keyed on
.CW "f->reg == REGSP"
\(em a register test standing in for a type that is wrong.
.B "Those patches are symptoms of the predicate being the wrong question."
Replace the question: a move is redundant iff the source and destination are the
same address
.I and
the destination's full width is already correct, which on this target means the
widths and signedness agree.
.LP
.B "This item should come out NEGATIVE."
One correct predicate replaces one wrong predicate plus two special cases, and
the
.CW REGSP
test \(em which is this tree's own patch, and which the comment beside it admits
is keyed on a register because the type is untrustworthy \(em goes away.
.B "Correctness and simplicity point the same way here,"
which is rare enough to spend the effort on first.
.NH 2
3. WITHDRAWN: do not delete C_VCON
.LP
.B "This item was wrong, and reading the code to execute it is what showed that."
It is left in the plan rather than quietly removed, because the error is the
same one the plan accuses kencc of \(em a conclusion drawn from the wrong
property.
.LP
.CW C_VCON
is never returned by
.CW aclass() ,
which is what the old comment in
.CW l.h
said, and I read that as dead code.
.B "It is an OPTAB-SIDE class and it is load-bearing."
.CW optab.c 's
only
.CW ADWORD
row is
.CW "{ ADWORD, C_NONE, C_NONE, C_VCON, 11, 8, 0 }" ,
and the matcher is
.I asymmetric :
.CW span.c
builds
.CW "xcmp[i][n] = cmp(n, i)"
and
.CW oplook
indexes
.CW xcmp[actual][optab] ,
so
.CW cmp() 's
.B first
argument is the
.I "optab's"
class.
.B "So cmp(C_VCON, C_LCON) runs on every ADWORD,"
hits
.CW "case C_VCON: return cmp(C_LCON, b)" ,
and returns 1 \(em which is the only reason an 8-byte literal ever matches an
operand
.CW aclass()
called a
.CW C_LCON .
.LP
.B "Deleting it would have broken the 64-bit literal pool fixed earlier today."
Proof rather than argument:
.CW tests/7l-bigconst.sh
reports four DWORD pool entries and
.CW ADWORD
has no other optab row, so that case fired four times in that run.
.LP
.B "The plan's claim that the case could not fire was FALSE,"
and the lesson generalises to item 1: an invariant checker written from the
same misreading would have rejected valid output.
.CW l.h 's
comment is corrected to say the class is optab-side and why.
.NH 2
3b. What was actually worth doing here
.LP
.B "The real defect here was the COMMENT, and it has been fixed."
It described a load-bearing optab-side class in words that read as dead code,
which is what made defect 3 hard to see
.B "and what made this plan propose a change that would have broken the build."
A comment that misleads a reader into deleting working code is worse than no
comment at all.
.LP
The alternative \(em making
.CW aclass()
return
.CW C_VCON
for a constant that does not fit 32 bits, and giving the optab a real entry \(em
is the textbook fix and
.B "costs more than it is worth here,"
because
.CW addpool
now sizes from the constant and that is where the width actually matters.
.B "Deleting the dead state is the simplification; adding the live one is a feature."
.NH 2
4. A peephole off-switch, purely so the compiler can be differentially tested
.LP
.CW peep()
is called unconditionally from
.CW utils/7c/reg.c:393 .
Gating it on an existing debug letter is
.B "three lines"
and buys the cheapest powerful test available: compile the suite with the
peephole on and off and compare
.I behaviour ,
not instructions.
.LP
Four of the eleven defects are in layout or peephole passes, and this tree
already has the analogous lever on the other side of the fence \(em
.CW "emu -c0"
against
.CW -c1 ,
which has found real bugs.
.B "A difference in output between peep-on and peep-off is a bug in peep, with no judgement required,"
which is the property that makes it worth three lines.
.NH 2
5. One static assertion for the host-type assumption
.LP
Rather than auditing uses of
.CW long
across
.CW utils/ ,
one assertion per util's shared header makes the assumption explicit and fails
the build where it is violated.
.B "A static assertion is documentation that cannot go stale,"
which is the failure mode the rest of this tree's comments keep having.
.NH 1
What NOT to do, with the reason
.LP
Each of these is a correct engineering answer and each costs more than the thing
it protects:
.IP \(bu
.B "A dataflow or verification pass."
More code than the passes it checks, and it would need a second IR to express
what it knows.
.IP \(bu
.B "A target abstraction layer"
to stop the arm64 and amd64 backends diverging.  The divergence is real \(em
defect 4 appeared in both \(em but the layer costs more than both backends'
differences.
.IP \(bu
.B "Rewriting the optab as a generated table."
The optab is 418 lines and legible; a generator is not.
.IP \(bu
.B "Property-based or fuzz testing in-tree."
Worth doing OUT of tree, against the suite below, but a fuzzer's corpus and
harness in
.CW utils/
would dwarf
.CW span.c .
.LP
.B "And one rule about where new complexity goes:"
into the tests, not the compiler.  The suite already works this way \(em
.CW kencc-narrowcast ,
.CW kencc-widencast ,
.CW kencc-brloop ,
.CW kencc-selfbranch ,
.CW 7l-bigconst
\(em and those are host-only, so they cost the compiler nothing.
.LP
.B "The rule for writing one, learned from narrowcast's own history:"
encode the shape that
.I bites ,
not the shape convenient to write.  Its first version probed
.CW "(u64)(u32)x" ,
where source and destination naturally land in different registers, and
.B "passed while the live defect sat in the same-register shape."
A probe for a bug whose symptom is a missing instruction cannot be a count of
instructions that happen to be present.
.NH 1
Order, and how to tell it worked
.LP
.B "Item 2 first,"
because it is the only one where correctness and simplification point the same
way, and it removes this tree's own patches rather than adding to them.
.B "Then item 1,"
which is where most of the defect classes go loud.  Then 3, 4 and 5, which are
small and independent.
.LP
.B "The criterion is countable and should be stated before starting:"
.IP 1.
Every one of the eleven known defects either fails the build or is covered by a
host-only test.
.B "Checked rather than asserted:"
the suite covers 1
.RB ( kencc-narrowcast ),
2 and 10
.RB ( kencc-widencast ),
3
.RB ( 7l-bigconst ),
4
.RB ( kencc-selfbranch )
and 5
.RB ( kencc-brloop )
\(em six of the eleven.  Item 1 adds 6 and 7.
.B "That leaves 8, 9 and 11 uncovered by anything,"
and this plan does not address them: 8 is a 6l relocation bug, 9 a switch
miscompile, 11 a
.CW -S
side effect, and none of the three is one of the four shapes above.  Naming them
as out of scope is better than implying a plan covers eleven when it covers
eight.
.IP 2.
.CW utils/
grows by less than 1 per cent, with items 2 and 3 negative.
.IP 3.
.B "Each check has a demonstrated failure, not just a demonstrated pass."
A check nobody has seen fire is an instrument with no known failure mode, and
this tree has spent a day learning what those cost.  The fixture for each must
be the shape that bites.
.LP
.B "What this plan does not claim."
It does not improve code generation, it does not reduce the compilers' real
complexity, and it does not touch the backends' divergence.  It makes four
specific failure shapes loud and removes one misleading state, on the argument
that a compiler which fails loudly on the mistakes it actually makes is higher
quality than one which is merely tidier.
.NH 1
Generating faster code: what the output actually wastes
.LP
Measured over
.B "255407 instructions"
of this tree's own C \(em
.CW os/inferno/port ,
.CW libmemdraw ,
.CW libinterp
\(em 164 files compiled, 28 failed and accounted for.
.B "60.7 per cent of all instructions are data movement:"
.P1
MOV    28.48%      BL      7.92%      ADD   3.84%
MOVW   24.71%      B       5.27%      CMPW  3.43%
MOVWU   6.04%      MOVBU   1.48%      ADDW  1.45%
.P2
Arithmetic
.RB ( ADD
plus
.CW ADDW )
is 5.3 per cent.
.B "So any optimisation that does not remove a move is working on the small half."
.NH 2
The decisive finding: peep is not missing a pass, it has one restriction
.LP
.CW peep()
is already 1561 lines and already does
.CW copyprop ,
.CW subprop ,
.CW constprop ,
.CW xtramodes ,
.CW CMP/branch
fusion and conditional execution.
.B "So the question was never what is MISSING but why the waste SURVIVES."
.LP
Counting same-register moves by what the
.I previous
instruction's source was:
.P1
previous source     MOVW Rx,Rx    MOVWU Rx,Rx
MEMORY (D_OREG)          0             0
REGISTER (D_REG)      1576           291
CONST (D_CONST)         18             2
MOV Rx,Rx (true no-op)   0             0
.P2
.B "Zero memory-source pairs survive and zero true no-ops survive"
\(em the existing rule and
.CW copyprop
both work perfectly.  The 1867 register-source pairs were rejected by a single
condition,
.CW "if(p->from.type != D_OREG) continue" ,
whose comment said a register move "may not" extend.
.B "The loader proves it does:"
.CW asmout.c
encodes
.CW "AMOVW reg,reg"
in the same case arm as
.CW ASXTW ,
and
.CW SXTW
is idempotent.
.B "Fixed as one allow-list condition"
\(em
.CW -0.59
per cent of instructions, 3072 out of the kernel's text, no measurable compile
cost.
.NH 2
What the remaining candidates are worth, and the argument against each
.IP 1.
.B "Adjacent same-register spill/reload."
A two-instruction window.  131 occurrences, 0.05 per cent \(em but each removed
instruction is a LOAD, so the cycle saving exceeds the count.
.B Against :
0.05 per cent is under the noise floor of anything measurable on this board, and
the real fix is in
.CW reg.c 's
allocation rather than a peephole.
.IP 2.
.B "constprop for AMOVW/AMOVWU."
554 duplicate constant loads, 0.22 per cent.
.B "Against, and it is strong:"
this reaches into the same
.CW "p->as == AMOV"
gate the big inline comment exists to protect, and the 20
.CW D_CONST
cases in the table above are evidence the hazard is real.  Small win, and the
blast radius is the family that has already produced two silent miscompiles
here.
.IP 3.
.B "shiftprop, which is disabled with"
.CW "if(0 && shiftprop(r))"
.B "and no comment saying why."
5797 shifts, 2.27 per cent, is the headline number and the ceiling.
.B "Against, and this is why it ranks LAST despite that:"
an optimisation switched off with
.CW "if(0 &&"
and no explanation was almost certainly switched off because it was wrong; the
ceiling assumes every shift has a foldable consumer, which it will not; and it
was written for ARM32's shifted-operand forms, which differ on AArch64.
.B "Treat 2.27 per cent as a bound, not an estimate."
.NH 2
The honest state of ""faster""
.LP
.B "Nothing here is a demonstrated speed-up, and the instrument matters more than the number."
.CW disbench
is the WRONG instrument for a 7c change: with
.CW cflag=1
its hot loops are JIT-generated code, which no 7c peephole touches.
.CW wm/gfxstress
exercises
.CW libmemdraw ,
which is the right target, but a single run of it against an earlier recorded
figure compared 750 operations with 500 \(em different workloads, no control.
.LP
.B "And 0.59 per cent is under this board's own measurement floor:"
the within-arm coefficient of variation measured here today is 2.2 to 2.6 per
cent.
.B "A static instruction count is the honest unit for this work;"
a runtime claim needs a two-install A/B that has not been run, and would need
more samples than the effect size justifies.
.NH 1
The other compilers and loaders
.NH 2
The loaders: priority was the reverse of what I assumed
.LP
Surveying which loader actually links something here:
.P1
jl  riscv64   6 boards   spike virt virts sifiveu shakti mangopi
tl            3 boards
7l  aarch64   3 boards
zl            2 boards
8l, 6l, 5l    1 each
.P2
.B "7l, where the defect was found, is not the loader with the widest reach."
.CW jl
links six of seventeen, twice as many, and had
.B "no coverage from either side"
\(em
.CW selfbranch.py
accepts
.CW e_machine
183 only and every riscv64 image is 243, so the scan reports all six as
skipped.
.CW 6l
was worse still: its defect was real and fixed in
.CW b97ac24d0 ,
and
.CW os/inferno/pc64/ipc64
is Plan 9 a.out, which the scan cannot read at all.
.LP
.B "So 7l, 6l and jl now refuse at emit time"
\(em 10 of 17 boards \(em each verified with a positive control (refuses, exits
nonzero, leaves no output file), a negative control (an unconditional
self-branch still links, because
.CW "for(;;)"
compiles to one), a clean build of every board that loader serves, and a
mutation test in which the check is stubbed and the test must report DEFECT.
.LP
.B "tl, zl, 8l and 5l are NOT done, and that is a decision."
Each
.CW check.c
is about 85 lines; the plan's whole budget was 200; three is already 255 for 10
of 17 boards.  The next 85 lines buy 3 boards, then 2, then 1 \(em a declining
return against a budget whose point is that kencc staying readable is what lets
anyone find these defects at all.
.NH 2
The compilers: the peephole fix does not port, for a reason
.LP
.B "The restriction I widened exists only in 7c."
A grep for it across all eleven
.CW peep.c
files finds one hit.  It was added for aarch64's
.CW SXTW
semantics and there is nothing to port.
.LP
.B "But the WASTE is worth comparing, and the answer differs by architecture."
Same 38 files of
.CW libmemdraw
and
.CW libmemlayer ,
three compilers:
.P1
       instructions   reg-to-reg extension moves   redundant pairs
7c            25941          2487   (9.59%)              0  (0.000%)
6c            22207          2220  (10.00%)             34  (0.153%)
jc            24587            37   (0.15%)              0  (0.000%)
.P2
.B "7c's zero is the fix, confirmed independently:"
the redundant pairs it used to leave are gone from this corpus entirely.
.LP
.B "jc has almost no extension moves AT ALL \(em 0.15 per cent against 10 \(em"
and that is architectural rather than lucky: RISC-V's W-form operations
sign-extend their result into the full register, so the compiler rarely needs
to emit an extension at all.
.B "There is nothing here to optimise, and the reason is the ISA."
.LP
.B "6c has the same density as 7c and 34 genuine redundant pairs, unaddressed"
\(em
.CW "MOVL CX,AX"
followed by
.CW "MOVL AX,AX"
\(em and
.CW MOVL
on amd64 is idempotent for the same reason
.CW SXTW
is.
.B "It is NOT worth doing here:"
6c has no such rule to widen, so it is about 25 lines of new code rather than
one, for 0.153 per cent, on the one board in this tree that uses it.  Recorded
so the next person has the number instead of the question.
.LP
.B "And the 32-bit compilers have no such defect to have:"
5c, 8c, kc, qc, vc, 0c, tc and zc target machines where pointer and int are the
same width, so there is no widening to drop or to repeat.
.NH 2
A tool bug found by trying the other architecture
.LP
.CW tools/jtag/kbuild
counted
.CW "^7l -o i$CONF"
in the build log
.I "whatever the board was."
On
.CW pc64 ,
whose loader is
.CW 6l ,
it counted zero and REFUSED a build that had linked perfectly.
.B "A false refusal, in the safe direction, but it meant the one tool whose"
.B "whole purpose is making the link observable was blind on every architecture"
.B "but one"
\(em and said nothing about that.  It now derives the loader from the board's
.CW OBJTYPE
and
.CW mkfiles/mkfile-Inferno-<objtype> ,
the way
.CW tests/kencc-selfbranch.sh
already did, and exits 2 rather than guessing if it cannot tell.
.NH 1
Against clang: how big is the gap, and what would each closing step cost
.LP
Six functions of strictly portable C \(em a summing loop, a struct-plus-arith
address computation, a byte-copy loop, a five-case switch, a shift/xor hash and
a leaf multiply-add \(em compiled verbatim by both toolchains.
.B "No GCC was available:"
.CW gcc
on this host is Apple clang, so this is a clang comparison and is labelled as
one.
.P1
fn         7c   clang-O0   clang-O1   clang-O2    7c/O1
sum        25         25         13         62     1.9x
addr       13         16          6          6     2.2x
blit       19         22          9         53     2.1x
cls        27         43          6          6     4.5x
hash       25         25         14         14     1.8x
leaf       10         10          2          2     5.0x
TOTAL     119        141         50        143     2.4x
.P2
.B "-O1 is the honest comparison and -O2 is not."
At
.CW -O2
clang
.I unrolls
and
.I vectorises :
.CW sum
goes from 13 instructions to 62 and
.CW blit
from 9 to 53.
.B "More instructions, faster code"
\(em so instruction count stops measuring quality there, and a kernel does not
want that trade anyway.
.B "Against -O1, kencc emits 2.4 times the instructions."
.NH 2
Where the 2.4x actually goes
.LP
.CW "int leaf(int a, int b) { return a*b + a; }"
is the clearest case, 10 instructions against 2:
.P1
clang -O1          7c
  madd w0,w0,w1,w0   MOVW  b+8(FP),R10     <- b comes off the STACK
  ret                MOVW  R0,R9           <- a is already in R0
                     MOVW  R9,R4              and is copied three times
                     MOVW  R10,R3
                     MULW  R3,R4
                     MOVW  R9,R5
                     ADDW  R5,R4           <- MUL then ADD, not MADD
                     MOVW  R4,R0
                     RETURN ,
                     RETURN ,              <- emitted twice
.P2
.B "That one function contains four INDEPENDENT causes,"
and they have wildly different prices.  The whole argument of this section is
that they must be priced separately rather than as "kencc is 2.4x worse".
.NH 2
The price of each, cheapest first
.IP 1.
.B "The duplicate RETURN. 76 pairs across 135 functions, 0.29 per cent."
A two-instruction window: a
.CW RETURN
immediately after a
.CW RETURN
is unreachable.
.B "About five lines in the existing peep loop, no new state, no analysis."
Nothing argues against it.
.IP 2.
.B "MUL followed by ADD is MADD."
AArch64 has a fused multiply-add and 7c never emits it.  A fixed two-instruction
window with a register-liveness question kencc can already answer:
.B "roughly twenty lines."
.B Against :
it needs the multiply's destination to be dead after the add, and getting that
wrong is a silent miscompile in the family that has already produced two here.
.IP 3.
.B "The copy chains."
.CW copyprop
and
.CW subprop
exist in
.CW peep.c
and
.B "deliberately exclude AMOVW and AMOVWU,"
with the reason in an inline comment: an int -1 became 0xffffffff downstream.
So this is a KNOWN defect being worked around, not a missing optimisation.
.B "Moderate:"
the fix is to make the propagation width-aware rather than to relax the
exclusion.
.B Against :
it is the exact code path of this tree's two silent miscompiles.
.IP 4.
.B "Branchless select."
.CW peep.c
already has
.CW predicate() .
Whether it fires on these shapes was not measured here and should be before
anything is written.
.IP 5.
.B "The switch compiled to arithmetic."
clang noticed every arm of
.CW cls
is affine in the selector and emitted
.CW "add/lsl/cmp/csel"
with no branches at all.
.B "That is whole-function value analysis, not a peephole,"
and needs an IR carrying value ranges.
.B "Expensive, and the honest answer is not to."
.IP 6.
.B "Arguments on the stack."
.CW leaf
loads
.CW b
from
.CW b+8(FP)
while
.CW a
arrives in
.CW R0 .
.B "This is the Plan 9 ABI, not an optimisation gap."
No pass can remove it; changing it means changing every hand-written
.CW .s
in the tree and the Dis JIT's assumptions about frames.
.B "Enormous, and it is a large part of the remaining 2.4x."
.IP 7.
.B "Unrolling and vectorising."
Large, and
.I "not wanted"
\(em it is where clang's instruction count triples, and a kernel pays for code
size.
.NH 2
The compile-time budget, which is the surprising part
.P1
7c          6.3 ms per compile
clang -O0  34.2 ms
clang -O1  31.5 ms
clang -O2  35.1 ms
.P2
.B "clang is five times slower than 7c with its optimiser switched OFF,"
and the whole distance from
.CW -O0
to
.CW -O2
is under a millisecond \(em about 3 per cent of its own compile time.
.LP
.B "So the expensive thing is not the optimisations.  It is the infrastructure"
.B "they are built on"
\(em a full IR, SSA construction, generalised pass management.  That inverts the
usual framing of this tradeoff and it is what makes "best quality, near
instantly" a coherent goal rather than a contradiction:
.B "an optimisation costs kencc almost nothing if it fits the data structures kencc already has."
.NH 2
What kencc already has, which decides what is affordable
.LP
.CW utils/7c/reg.c
is not just a register allocator.  It builds a flow graph and computes
.CW loopit()
for loop nesting,
.CW prop()
for dataflow propagation,
.CW synch()
for register/variable synchrony, and bit-vector liveness used throughout.
.B "So liveness and loop structure are NOT missing"
\(em they are already paid for, because the allocator needs them, and
.CW peep.c 's
.CW copyprop
and
.CW subprop
already use them.
.LP
That gives three honest tiers:
.P1
tier                     infrastructure   verdict
fixed-window peephole    none needed      DO: MADD, duplicate RETURN,
                                          the extension pair already fixed
uses the existing flow   already built    MAYBE: width-aware copyprop,
graph and liveness                        if-conversion via predicate()
needs SSA or value       does not exist   DO NOT: switch-to-arithmetic,
ranges                                    loop strength reduction
.P2
.B "The remaining gap after tier one is mostly tiers two and three plus the ABI,"
and the ABI is not an optimisation at all.  So the reachable target is not
clang's 2.4x; it is the part of it that lives in tier one and the cheaper half
of tier two, bought at a few tens of lines and no measurable compile time.
.NH 1
The tradespace, and what is appropriate for kencc
.LP
Measured on
.B "135333 instructions over 1938 functions"
\(em
.CW libmemdraw ,
.CW libmemlayer ,
.CW libdraw
and
.CW libinterp ,
136 files compiled, 4 failed.  Every pattern below was validated by printing its
actual matches, because an unvalidated count is the thing this document keeps
being about.
.NH 2
What kencc already does
.LP
Reading
.CW peep.c
and
.CW reg.c
rather than guessing:
.CW copyprop ,
.CW subprop ,
.CW constprop ,
.CW xtramodes
(folding indexed and pre/post-increment addressing),
.CW "EOR -1 -> MVN" ,
.CW CMP /branch
fusion, zero-register substitution,
.CW predicate()
for conditional execution, and
.CW shiftprop
\(em which is
.B DISABLED
with
.CW "if(0 && shiftprop(r))"
and no comment saying why.
.CW reg.c
additionally builds a flow graph and computes
.CW loopit() ,
.CW prop() ,
.CW synch()
and bit-vector liveness.
.B "So the infrastructure for anything short of SSA is already paid for,"
because the register allocator needs it.
.NH 2
The tradespace
.P1
                    sites  /1000   lines  infra   risk   VERDICT
duplicate RETURN       77   0.57       1  none    HIGH   NO, see below
shift fold (shiftprop)164   1.21     ~30  flow    med    DONE, ported
branch to next instr  153   1.13      ~8  none    low    LISTING only
adjacent spill/reload  69   0.51      ~8  none    low    marginal
width-aware copyprop   5231  38.66     ~55  flow    HIGH   bndstest ok
MUL+ADD -> MADD        18   0.13     ~20  flow    med    NO -- too rare
extension pair         14   0.10       1  none    med    DONE (see below)
switch -> arithmetic    -      -    ~300  SSA     high   NO
loop strength reduction -      -    ~400  SSA     high   NO
unroll / vectorise      -      -   ~1000+ SSA     high   NO, and unwanted
register-arg ABI        -      -   huge   n/a     huge   NO, not an optzn
.P2
The "extension pair" row is done: its 14 residual sites are the
.CW D_CONST
case the allow-list correctly excludes, and the validated example is
.CW "MOVW $0,R2"
followed by
.CW "MOVW R2,R2"
\(em exactly the one a constant materialisation makes unsafe.
.LP
.B "MADD is the item this measurement killed."
The
.CW leaf
example made it look like the obvious win \(em clang does
.CW "a*b+a"
in one instruction where 7c takes nine \(em but across 135333 real instructions
there are
.B "eighteen"
sites where a multiply is immediately followed by an add consuming its product.
0.013 per cent for about twenty lines in the family that has already produced
two silent miscompiles here.
.B "One unrepresentative function is not a workload,"
and I recommended this before measuring it.
.NH 2
And the cheapest item is not free either
.LP
"Delete the second of two consecutive RETURNs" sounds like it needs no analysis.
.B "It does: 7 of 403 duplicate RETURNs are the target of a branch."
Removing those breaks the program.  The check must ask whether anything jumps to
the instruction \(em which
.CW reg.c 's
flow graph can answer, so the cost is eight lines using infrastructure that
exists rather than five lines using none.
.LP
.B "That is the shape of nearly every entry in the table:"
the optimisation is trivial and the precondition is where the work is.  A
tradespace that prices the transformation and not its precondition is the same
error as quoting a point estimate.
.NH 2
What is appropriate for kencc, as a rubric
.LP
Not taste \(em six criteria, each derived from something measured in this
document:
.IP 1.
.B "Does it fit the data structures that already exist?"
A fixed window over the
.CW Prog
list costs nothing.  The flow graph and liveness are already built.
.B "SSA and value ranges are not,"
and building them is larger than every pass in
.CW peep.c
put together.
.IP 2.
.B "Is the compile time still invisible?"
7c compiles at 6.3ms against clang's 34.2 at
.CW -O0 .
.B "clang's whole optimiser costs about 3 per cent of clang's own compile time"
\(em so optimisation is not what makes a compiler slow, infrastructure is.  An
O(n) pass over an existing list stays invisible; a pass that needs its own IR
does not.
.IP 3.
.B "Does it have to be written eleven times?"
There are eleven
.CW peep.c
files.  An arch-specific peephole is eleven copies or one copy helping one
architecture, and that multiplies both the lines and the chances of getting one
of them wrong.
.IP 4.
.B "Can it be silently wrong?"
.B "Every kencc defect this tree has found was a silent miscompile"
\(em eleven of them, exit status 0 and a wrong program.  The width and extension
family has produced two on its own.  So an optimisation there is appropriate
ONLY with a test that has been seen to fail, and
.CW shiftprop
being disabled with
.CW "if(0 &&"
and no explanation is the warning sign, not an invitation.
.IP 5.
.B "Does it trade size for speed?"
This is a kernel.  clang at
.CW -O2
takes a 13-instruction loop to 62 by unrolling and vectorising.  Faster, and
the wrong trade here.
.IP 6.
.B "Is the win bigger than the noise?"
The board's within-arm coefficient of variation is 2.2 to 2.6 per cent.
.B "Nothing in the table above is individually measurable on hardware."
They are code-size and instruction-count wins, and saying so is more useful
than a speed claim that cannot be supported.
.NH 2
Which of the 32-bit moves are redundant, by producer
.LP
The ceiling for the width-aware row is 38886.
.B "The question that decides the row is what fraction of those is REDUNDANT,"
and a classification by what produced the move's source separates the removable
class from the class that must never be touched.  Five large kernel sources
\(em
.CW chan.c ,
.CW proc.c ,
.CW qio.c ,
.CW xalloc.c ,
.CW tcp.c
\(em 21333 listing lines:
.P1
same-register MOVW/MOVWU (pure SXTW/UXTW)        192   never removable
reg-to-reg 32-bit moves, different source       1162

  producer of the source register:
    MOVW        515   44.3%   already sign-extended -> REDUNDANT
    MOV         264   22.7%   64-bit value; SXTW truncates, NOT redundant
    MOVWU       134   11.5%   zero-extended; SXTW differs, NOT redundant
    ADD          92    7.9%   64-bit, NOT redundant
    ADDW         62    5.3%   W-form ZERO-extends -- THE DOCUMENTED BUG
    SUBW         37    3.2%   same
    SUB          22    1.9%   64-bit, NOT redundant
    other        33    2.9%   ANDW, MULW, UDIVW, LSLW, NEGW, MOVHU, MOVBU
    unknown       3    0.3%
.P2
.LP
.B "The removable class is the idempotent SXTW chain, and nothing else."
A
.CW MOVW
whose source was itself produced by a
.CW MOVW
sign-extends a value that is already sign-extended, and
.CW "MOVW reg,reg"
assembles to
.CW "SBFM 0,31"
\(em the same
.CW asmout
arm as
.CW ASXTW
\(em which is idempotent.  That is 515 of 1162.
.LP
.B "And the 110 W-form producers are the miscompile this tree already has"
.B "written down."
A W-form result
.I zero -extends
to 64 bits on aarch64, so a following
.CW SXTW
is
.B not
redundant \(em dropping it is exactly how
.CW "int -1"
became
.CW 0xffffffff
in
.CW peep.c 's
inline comment.  A width-aware propagation that keys on \(lqis the source 32
bits\(rq rather than \(lqwas the source SIGN-extended\(rq reintroduces it.
.B "The distinction is sign versus zero extension, not width,"
and that is the whole design constraint on the forty lines.
.LP
.B "Three reasons this 44.3 per cent is still an upper bound and not a payoff."
.IP 1.
.B "It is a LISTING proportion applied to an IMAGE count,"
which is the error this document made twice already.  38886 is measured in the
linked kernel; 44.3 per cent is measured in 7c's output.  Multiplying them is
not licensed and no number is quoted here from doing so.
.IP 2.
.B "The survey has no basic blocks."
It records the last instruction seen writing a register, in source order,
across branches.  A producer on the other side of a branch is not a producer,
so the real figure is lower.
.IP 3.
.B "A producer being a MOVW does not prove the value is still sign-extended at"
.B "the point of use;"
anything between can clobber the register, which is what the real analysis has
to establish and the survey does not.
.LP
.B "So the row stays open with a sharper statement than it had:"
the mechanism is known, the removable class is named, the class that must not be
touched is named and is the one with a recorded miscompile, and the bound is
44.3 per cent of the different-source population rather than a question mark.
.B "The forty lines are not written here,"
because the measurement that would justify them is basic-block-aware and that
is the same work as the pass.
.NH 2
The flow-aware count, and why 7273 is not 7273 instructions
.LP
The listing survey above gave 44.3 per cent and said so as an upper bound,
because it recorded the last writer of a register in source order with no
basic blocks.
.B "Doing it inside the compiler, where reg.c's flow graph is already paid for,"
.B "lowers it \(em as predicted."
A single extra pass, 50 lines, no transformation: for each surviving 32-bit
register-to-register move, walk back through
.CW uniqp()
only, so a basic-block boundary is crossed exactly when that block has one
predecessor, and stop at a merge.
.P1
total surviving 32-bit reg-to-reg moves   22493
  same register (pure conversion)           2937   13.1%  never removable
  producer at a MERGE (unknown)             5887   26.2%  conservatively not
  producer is a CALL return (W0 zero-ext)   2904   12.9%  NOT redundant
  W-form producer (zero-extends)            2030    9.0%  THE MISCOMPILE CLASS
  IDEMPOTENT (MOVW/MOVW, MOVWU/MOVWU)       7273   32.3%  pure copy, CANDIDATE
  narrower zero-extending load                87    0.4%  also a no-op
  other (64-bit MOV, cross-kind)            1375    6.1%  NOT redundant
.P2
.LP
As a share of the different-source moves that is 7273 of 19556, or
.B "37.2 per cent against the listing survey's 44.3,"
and the direction is the one the caveat predicted: the awk credited producers
that sit on the other side of a branch.
.LP
.B "TWO CROSS-CHECKS MADE THIS INSTRUMENT TRUSTWORTHY, and it failed both"
.B "before it passed them."
.IP 1.
.B "Placed before loop1 it counted 338 moves in chan.c where 287 reach the"
.B "listing."
The 51 difference is moves that
.CW copyprop
and its neighbours remove anyway, and a survey that counts those overstates
what a new pass could win.  Moved to the end of
.CW peep() ,
after every existing pass, it counts 287 \(em
.B "exactly the independent listing count,"
which is the check that makes the number usable at all.
.IP 2.
Run twice it gives the same figure, which is what says the fixed-point loop is
no longer being counted.
.LP
.B "AND 7273 IS NOT 7273 INSTRUCTIONS SAVED.  This is the reading to refuse."
An idempotent
.CW "MOVW Rx,Ry"
with
.CW Rx
already sign-extended is still a
.I copy :
the value has to reach
.CW Ry .
Nothing about knowing the source is already extended deletes it.
.B "What the knowledge buys is permission to PROPAGATE it,"
which
.CW copyprop
currently refuses outright for
.CW AMOVW
and
.CW AMOVWU ,
and only after propagation succeeds does the copy become dead and get excised.
So 7273 is a count of
.I candidates ,
and the fraction of candidates whose uses copyprop can actually rewrite is a
further unknown that this measurement does not touch.
.LP
.B "What it does settle is the shape of the pass."
The condition is
.B "\(lqwas the source extended the SAME WAY\(rq,"
not \(lqis the source 32 bits\(rq:
.P1
MOVW  after MOVW   idempotent SXTW        propagate
MOVWU after MOVWU  idempotent UXTW        propagate
MOVWU after MOVW   sign- then zero-ext    DO NOT: differs when bit 31 is set
MOVW  after MOVWU  zero- then sign-ext    DO NOT: same
MOVW  after ADDW   W-form ZERO-extends    DO NOT: this is the recorded bug
MOVW  after a call  W0 ZERO-extends       DO NOT: same, and 2904 of them
.P2
.LP
The two
.CW "DO NOT"
rows that matter are worth 4934 sites between them \(em W-form producers and
call returns \(em and both are the
.CW "int -1 -> 0xffffffff"
miscompile recorded in
.CW peep.c 's
own comment.
.B "A pass keyed on width rather than on signedness reintroduces it in 4934"
.B "places,"
which is why the exclusion that exists today is the right conservative default
and why relaxing it needs the producer's extension kind and not its size.
.LP
.B "The remaining 5887 merges are the measurable headroom beyond this."
They are unknown only because the survey stops at a merge;
.CW reg.c
already computes bit-vector liveness and
.CW prop() ,
so a real pass could resolve some fraction of them.  That makes the candidate
range 7273 to 13160, and narrowing it is the same work as writing the pass.
.NH 2
The width-aware propagation, written and measured
.LP
.B "Rule 4 was satisfied first:"
.CW tests/kencc-widthprop.sh
landed before the pass, with five probes drawn from the measured unsafe classes
and a demonstrated failure on the naive relaxation.  Only then was the pass
written.
.LP
.B "The condition is one function, and it is about signedness."
.CW sameext()
walks back through
.CW uniqp()
to the instruction that writes the move's source and returns true only when
that instruction applied the
.I same
extension:
.CW MOVW
after
.CW MOVW ,
.CW MOVWU
after
.CW MOVWU .
A merge, a call, or any other producer is a refusal.
.LP
.B "It asks copyu rather than testing q->to, and that choice is load-bearing."
.CW to
is not always the destination:
.CW copyu 's
.CW ABL
arm returns 2 for every caller-saved register while a call's
.CW to
is the callee symbol, and its
.CW ARET
and
.CW ATEXT
arms are keyed on
.CW REGRET
and
.CW REGARG .
A hand-rolled
.CW to
test has to enumerate those and be re-audited whenever the switch grows.
.B "The first implementation did test q->to, and it was too permissive in 22"
.B "places."
.P1
                                 surviving reg-to-reg 32-bit moves
base (exclusion intact)                       22483
v1, tested q->to                              20071   removed 2412
v2, copyu but refused "only used"             20914   removed 1569
v3, copyu, correct                            20093   removed 2390
.P2
.LP
.B "v2 is the more instructive mistake."
.CW copyu
returns 1 for \(lqv only used\(rq, which does
.B not
modify the register, and v2 refused on it \(em so it gave up 843 sites and
looked at first like evidence that v1 had been unsound in 843 places.  It was
not; it was my own bug in the instrument I was using to judge v1.
.B "A more conservative implementation is not automatically a more correct one,"
and the gap between two implementations is not a count of defects in either
until you know why they differ.
.LP
.B "5231 instructions leave the kernel."
.CW iraspi3b
3353257 to 3332333 bytes, which is 20924, which is 5231 instructions.  The two
exact counters corroborate:
.CW SXTW
27533 to 23884 and
.CW "MOV Wd,Wn"
11353 to 9813, a sum of 5189, agreeing with the mask-free byte figure to within
0.8 per cent.  Both masks score zero on the random-bytes control.
.B "That is 31 times the shiftprop win,"
and against the survey's 7273 candidates it is a 72 per cent realisation \(em
the rest being candidates whose uses copyprop could not rewrite, which is the
unknown the survey said it could not resolve.
.LP
.B "And it costs nothing to compile."
Three runs of
.CW chan.c :
24, 24, 23 ms before and 23, 23, 23 ms after.  The pass is a bounded pointer
chase over a flow graph the register allocator had already built, which is
exactly the tier-one property this document set out to exploit.
.LP
.B "RUN ON THE BOARD, and a control stopped me reporting a regression that"
.B "was not one."
Installed as build 1791504169 and running from the card,
.CW bndstest
gives 11 ok, 0 fail.
.B "But drawink printed NOTHING,"
where on the previous kernel it had printed seven PASS lines with pixel
verification \(em and
.CW /dev/screen
was 0 bytes, so there was no framebuffer at all.  5231 rewritten sites in the
kernel's integer arithmetic makes a broken draw path entirely plausible.
.LP
.B "The control says otherwise."
Reinstalling the PREVIOUS kernel, build 1791496543, the one whose drawink had
passed earlier the same day:
.CW /dev/screen
is 0 bytes there too and drawink is equally silent.
.B "So the framebuffer is absent on both kernels and drawink cannot"
.B "distinguish them."
What changed between the working run and the failing one was not the compiler
but a
.B "cold power cycle"
of the board, which the wedge above had made necessary.  The VideoCore
allocates the framebuffer at firmware start and a warm reboot inherits one a
previous boot obtained; a cold start without that does not produce one, and
nothing on the ARM side reports it.
.LP
.B "Two things to take from it."
The compiler change is exonerated, by a control and not by argument.  And
.B "a board-level test can stop being a test without saying so:"
drawink exits 0 and prints nothing when it has no screen, so in a suite that
checks only exit status it would have read as a pass on every kernel from here
on.  The gate it was supposed to be is gone until the board is warm-booted
again.
.LP
.B "Still owed:"
drawink and a styx throughput number on a board with a framebuffer.
.CW bndstest
passing 11 of 11 exercises the Dis bounds path and is real; it is not the draw
path.
.LP
.B "(The earlier text of this paragraph said the install had refused twice and"
.B "needed a power cycle, which it did.)"
The install refused twice.  The first attempt hit
.CW DSCR.ERR=1 ,
which
.CW tools/jtag/unwedge
cleared \(em EDSCR 0x13147d53 to 0x03147d13, the sticky bit gone and no human
needed \(em but the retry reported that the
.B core
is stuck and not merely the bit, and
.CW hardreset
then could not read
.CW Rstc
at all.  The board answers neither JTAG nor ping.
.B "It needs a power cycle at the switch,"
so
.CW kinstall
left the card on the previous build and said so, which is the tool behaving
correctly.
.LP
So for this row:
.B "real"
are the 5231 instructions, the byte-level corroboration, the zero loader
diagnostics, the unchanged compile time, and that
.CW tests/kencc-widthprop.sh
and the other eleven toolchain tests pass.
.B "Not done"
is any execution of a kernel built this way.  5231 sites is 31 times the
shiftprop change and it rewrites integer-to-pointer arithmetic throughout the
kernel, so until it has booted and run
.CW bndstest ,
.CW drawink
and a styx transfer, this row is implemented and unproven \(em and the
tree's
.CW kernel8.img
is the unproven build, which disarms the stamp-checked tools until it is
installed.
.LP
.B "162 emissions against 145 did NOT mean new warnings,"
and reading the wrong one of kbuild's two numbers nearly made it a finding.
.CW kbuild
prints
.CW "162 emission(s), 145 distinct" ;
the distinct count is unchanged, and the 17 extra emissions are seventeen
pre-existing warnings printed twice because 41 more compiles ran in that build.
.B "Comparing the two runs with sort -u reported no new diagnostics and was"
.B "also wrong to,"
for the opposite reason: dedup hides a count change.  Only the per-text counts
answered it.
.NH 1
Making the compiler itself faster
.LP
A separate question from everything above, which is about the code 7c emits.
.B "7c already compiles about 5.4 times faster than clang -O0"
(6.3 ms against 34.2 ms, measured earlier in this document), so the question is
where its own time goes and whether any of it is recoverable.
.NH 2
Where the time actually goes
.LP
.CW -N
turns off
.CW regopt
and
.CW peep ,
which splits the compile for free: on
.CW ../ip/tcp.c
11.6 ms becomes 5.3 ms, and on
.CW sdhcibcm.c
7.4 ms becomes 5.2 ms.
.B "So the optimiser is 30 to 54 per cent and the front end is the rest."
.LP
Timers around each phase of
.CW regopt ,
five real sources:
.P1
                 tcp.c   chan.c  proc.c  sdhci  devusb
peep               65%      37%     41%    31%     45%
liveness-prop      19%      32%     27%    39%     28%
allreg-paint        3%       6%      7%     7%      6%
synch, loopit,      -        -       -      -       -
  paint1 costs    <10% between them on every file
.P2
.LP
.B "Register allocation is 3 to 7 per cent."
The phase with the reputation for being expensive is not worth touching here.
.B "peep is the cost,"
and the first guess about why was wrong: counting its
.CW loop1
iterations gives about 2 per function on every file, so it is not
iteration-bound and a worklist would buy at most half of it.
.NH 2
peep was quadratic in function size
.LP
.B "A controlled experiment: 640 statements, held constant, spread over a"
.B "varying number of functions."
Same total work, different function sizes.
.P1
stmts/fn      10      40     160     640
peep (us)    390     641    1888   49450
liveness      112     124     218     316
.P2
.LP
That is about
.B "n to the 2.4"
in function size: one 640-statement function spent
.B "49 ms in peep alone,"
eight times an entire average compile, while liveness over the same code stayed
nearly flat.
.LP
.B "The cause is two O(n) sweeps performed once per CANDIDATE instruction."
.CW copyprop()
and
.CW finduse()
each began with
.P1
	for(r=firstr; r!=R; r=r->link)
		r->active = 0;
.P2
.LP
and each is attempted once per candidate, so the clears alone are O(n squared)
in function size before either of the recursive walks they precede.
.NH 2
The fix, and what it is worth
.LP
.B "A generation counter."
.CW Reg.active
is a
.CW long ,
so instead of clearing n flags, bump a counter and compare equality.
.B "The idiom is already used in the neighbouring file:"
.CW reg.c 's
.CW paint1()
tests
.CW "r->active == head" .
.CW active
is cleared
.I once
per function and the counter only increases, so no stale value can equal a live
generation \(em and
.CW finduse()
can share the counter because it is called only from
.CW xtramodes() ,
never from inside
.CW copy1() ,
which was checked rather than assumed.
.P1
                            v3 (sweep)   generation   speedup
640 stmts in  1 function      54.2 ms       4.7 ms     11.5x
640 stmts in  4 functions      6.0 ms       4.1 ms      1.45x
640 stmts in 16 functions      4.2 ms       3.7 ms      1.11x
640 stmts in 64 functions      3.9 ms       3.7 ms      1.05x

tcp.c                         12.0 ms       9.1 ms      1.31x
six real kernel sources       43.1 ms      39.0 ms      1.10x
full kernel build              6.0 s         5.7 s      1.05x
.P2
.LP
.B "And the output is byte-identical,"
which is the only acceptable result for a change that is purely about speed:
152 of 152 kernel objects compare equal, and the two linked
.CW iraspi3b
images differ in
.B "one byte,"
the build stamp.
.LP
.B "So the honest value is 5 per cent end to end and a cliff removed."
Typical kernel functions are small enough that the quadratic barely shows; the
file with the largest functions gains 31 per cent, and a single large generated
function gains an order of magnitude.
.B "The 5 per cent is not the reason to do it \(em the removed cliff is,"
because nothing warns you when you cross it and the symptom is a compiler that
feels fine until one file takes a second.
.LP
.B "What is NOT worth doing, measured rather than assumed:"
a peep worklist (about 2 iterations per function, so at most a halving of what
remains), anything in register allocation (3 to 7 per cent), and anything in
.CW synch ,
.CW loopit
or the
.CW paint1
cost pass (under 10 per cent between them).
.B "The front end is 50 to 70 per cent and is the real floor;"
it is a yacc parser plus
.CW cgen ,
and making it faster is a restructuring rather than an optimisation.
.NH 2
The same sweep is in every compiler, and fixing it helps only 7c
.LP
.B "All eleven compilers have the clear."
.CW "grep 'active = 0;' utils/*c/peep.c"
finds it once in each of 0c, 6c, 8c, jc, kc, qc, tc, vc and zc, and twice in
5c, which has
.CW finduse
as well.  So the quadratic is a family property, not a 7c defect.
.LP
.B "But 6c does not blow up, and the reason is instructive."
Applying the identical generation counter to
.CW utils/6c/peep.c
and measuring with 21 samples an arm, interleaved:
.P1
                  base min/med/max      gen min/med/max   overlap
640 stmts /1 fn   10.9  11.5  12.1      11.0  11.4  12.1    YES
640 stmts /4 fn    3.7   4.0   4.6       3.8   4.0   4.5    YES
.P2
.LP
.B "Indistinguishable."
A first pass at five samples an arm had reported 0.71x and 0.95x, which looked
like a regression and was sampling noise \(em
.B "the ranges answer a question five samples cannot."
.LP
The cause is the candidate set.
.CW 6c 's
.CW copyprop
is reached only for
.CW AMOVQ ,
.CW AMOVSS
and
.CW AMOVSD ,
because
.CW AMOVL
is deliberately excluded \(em on amd64 a 32-bit move zeroes the upper half and
is a truncation, the same family of exclusion 7c has for
.CW AMOVW .
7c's candidate set includes
.CW AMOV
AND, since this document's width-aware change,
.CW AMOVW
and
.CW AMOVWU ,
which is thousands of extra calls per kernel.
.B "The sweep only costs what it is called."
.LP
.B "So the 6c change was reverted,"
because a change with no measured benefit should not ship even when its output
is byte-identical \(em which it was, 98 of 98 pc64 objects.
.B "What is worth recording is the conditional:"
if width-aware propagation is ever done for 6c \(em and
.CW peep.c 's
own comment invites it, saying the cost of the exclusion is a redundant
.CW MOVL
\(em then the candidate set grows the way 7c's did and
.B "the generation counter has to come with it,"
or the new pass pays for itself in sweep time.
.NH 2
The shiftprop kernel on silicon
.LP
.B "Installed to the card and exercised, which the port's commit said was"
.B "still owed."
Build 1791496543, no
.CW #Q ,
running from the card with the poller answering.
.P1
bndstest             11 ok, 0 fail
drawink              all checks passed, pixel-verified
#Q present?          ls '#Q' -> errors (absent, as intended)
ping loss            0% at 64, 1400, 4000 and 8000 bytes
1MB styx read (s)    1.6  1.9  1.6
1MB styx write (s)   2.4  2.4  2.4
.P2
.LP
.B "What this is and is not evidence for."
It is evidence that a kernel whose array indexing was rewritten in 164 places
boots, runs the Dis bounds checks, draws verified pixels and moves a megabyte
each way over styx without loss.  It is
.B "not"
evidence that the fold made anything faster, and there is no control arm here
on purpose:
.B "this document's own rule 6 says nothing in the tradespace is individually"
.B "measurable on hardware,"
the board's within-arm coefficient of variation being 2.2 to 2.6 per cent
against 164 instructions in 135333.  Quoting these as a speed result would be
the error the rule exists to prevent.  The write arm's 2.4/2.4/2.4 is reported
because zero spread across three repeats is itself worth seeing.
.LP
.B "And one operational finding that cost two failed installs."
Both earlier attempts died at
.CW "build <stamp> boots but its command poller never answered" ,
and a bare
.CW boardrun
returned nothing either, on a board that had answered twenty minutes before.
The cause was a background
.CW netwatch
loop left running against the board's address from earlier in the session \(em
its script file already deleted from the scratchpad, so it did not even appear
as a readable script.  Stopping it and the next install reached
.CW "the poller answers" .
.B "A kernel that boots, confirms its build stamp from the ring, and cannot be"
.B "driven is not necessarily faulty;"
check for strays before diagnosing it.
.NH 2
Width-aware copyprop is now the largest row, and its ceiling is measured
.LP
The table carried
.CW ?
in both numeric columns for this row.  It no longer has to.
.LP
.B "The shipping kernel contains 38886 32-bit register moves:"
27533
.CW SXTW ,
which is what
.CW "MOVW reg,reg"
assembles to, and 11353
.CW "MOV Wd,Wn" ,
which is
.CW "MOVWU reg,reg" .
Both masks score
.B zero
on a random-bytes control of the same size, so unlike the two loose counters
above these are exact.  That is 5.9 per cent of the image and 58.6 per 1000,
.B "two orders of magnitude larger than anything else in the table."
.LP
.B "But that is a CEILING and not a payoff, and the difference is the whole row."
.CW copyprop
and
.CW subprop
exclude
.CW AMOVW
and
.CW AMOVWU
because register to register they are
.CW SXTW
and
.CW UXTW
\(em a conversion, not a copy \(em and most of those 38886 are
.I required :
they are the sign extension that makes an
.CW int
usable in pointer arithmetic.  The exclusion is not declining propagable
copies, it is correctly keeping conversions.
.B "How many are REDUNDANT cannot be counted without the width analysis itself,"
which is the forty lines.
.LP
.B "Which is nevertheless enough to re-rank the row."
If one in twenty of those moves is redundant that is 1944 instructions, ten
times the shiftprop win; if one in a thousand it is 39 and the row dies.
.B "So the measurement that decides this row is \(lqwhat fraction of a"
.B "same-register MOVW is already 32-bit clean\(rq,"
and the honest statement of the verdict is not \(lqonly with a test\(rq but
\(lqthe test IS the work, and it is the largest remaining item in this
document\(rq.
.LP
.B "A third counting error was made getting here, and the lesson did not take"
.B "the first two times."
An instrumented
.CW 7c
that printed at the exclusion reported 42157 sites \(em 31 per cent of the
kernel's instructions, which is not a believable number for a register copy.
The counter sat inside
.CW loop1 ,
which re-runs until nothing changes, so it counted sites times passes for the
third time in this document.
.B "A counter inside a fixed-point loop counts iterations."
The usable figure came from the shipping image instead, where there are no
passes to count.
.NH 2
Why shiftprop was off, and what porting it cost
.LP
.B "It was never ported from 32-bit ARM, and that is a different answer"
.B "from \(lqit was tried and it broke\(rq."
.CW shiftprop
exists in exactly two compilers,
.CW 5c
where it is enabled and
.CW 7c
where it is not, and
.CW 7c
is
.CW 5c
with the aarch64 parts rewritten.  Six defects, each found from a primary
source rather than reasoned about:
.IP 1.
.B "The operand layout is 5c's."
.CW 7c
encoded the shift into
.CW D_SHIFT
as register at bits 0\-4, amount at 7\-12, kind at 5\-6.
.CW 7l
decodes register at 16\-20, amount at 10\-15, kind at 22\-23, and so does
.CW 7a
\(em and
.CW asmout
case 3 is
.CW "o1 |= p->from.offset" ,
which ORs the field straight into the instruction word, so the layout is not a
convention but the encoding itself.  A correctly folded
.CW R10<<3
came out as
.CW R0<<24 .
.IP 2.
.B "There was no default arm on the opcode switch."
Any consuming instruction outside
.CW ABIC ,
.CW ACMP ,
.CW ACMN
and
.CW AMVN
fell through the \(lqcan the substitution be done\(rq test straight into the
substitution.
.IP 3.
.B "The allow-list it did have named an opcode the loader cannot encode."
.CW optab.c
has a
.CW C_SHIFT
row for
.CW AADD ,
.CW AAND ,
.CW ABIC ,
.CW ACMP ,
.CW AMVN
and
.CW ANEG
only.
.CW ACMN
is not among them, and
.CW AADD
\(em which is where every fold in this kernel actually goes \(em was reached
only by the fall-through in defect 2.
.IP 4.
.B "The call site admits the 32-bit forms."
.CW ALSLW ,
.CW ALSRW
and
.CW AASRW
reach
.CW shiftprop ,
the kind switch had no case for them and no default, so a 32-bit shift would
have folded as a 64-bit
.CW "LSL #0" .
There is no
.CW C_SHIFT
row for any W-form, so they cannot be folded at all.
.IP 5.
.B "The register-amount case has no aarch64 encoding."
.CW "ADD Rd, Rn, Rm, LSL Rs"
does not exist; that is two instructions.  The ported code refuses it.
.IP 6.
.B "7c's own listing printer was 5c's too."
.CW list.c
read the register as
.CW v&15
\(em not expressible past R15 on a machine with 31 \(em the amount from bit 7
and the kind from bit 5.  So the listing would have shown garbage for a
correctly encoded operand, and this is the defect that would have sent the next
reader after the encoder instead of the printer.  Fixed to
.CW 7l 's
layout.
.LP
.B "The fold is verified at the byte level, not from the listing,"
because defect 6 is exactly the trap where a listing reads correct and the
bytes are wrong.
.CW "a + (b<<3)"
must assemble to
.CW "ADD X0, X0, X10, LSL #3" ,
which is
.CW 0x8B0A0C00
hand-computed from the architecture manual; the linked output contains that
word once, and the ASR variant
.CW 0x8B8A0C00
once.  The word the old layout would have produced,
.CW 0x8B00018A ,
is absent, as is the amount-lost
.CW 0x8B0A0000 .
.LP
.B "Five adversarial shapes are refused:"
a result used as both the shifted and the unshifted operand
.CW "(a <<= 3; return a + a)" ,
the same through
.CW "reg == NREG"
where
.CW asmout
substitutes the destination, a result used twice downstream, a shift amount
outside 0\-63, and the W-forms.
.B "Two of those refusals were briefly deleted"
because a toy test case did not fold without them, which is the wrong reason to
delete a check; they are restored with a comment saying what deleting them
miscompiles.
.LP
.B "168 instructions leave the kernel, measured three independent ways"
\(em but only one of the three is free of a mask, and that distinction was
nearly missed.
.P1
                            control    on     delta   random
UBFM immediate (LSL $n)      4077     3909    -168     658
shifted ADD, amount != 0      294      463    +169    1334
iraspi3b bytes            3353929  3353257    -672       -
.P2
.LP
The
.I random
column is the same counter run over 2655592 bytes from
.CW /dev/urandom ,
and it is the reason this table has four columns instead of three.
.B "Two of the three masks match data,"
and match it heavily: the shifted-ADD mask fixes only nine bits, so it finds
1334 matches in noise, which is more than the 463 it finds in the kernel.
.B "So the ABSOLUTE counts 4077, 3909, 294 and 463 are not instruction counts"
and must not be quoted as such.
.LP
.B "The DELTAS survive, and the reason is worth stating because it is a"
.B "property of the measurement and not a hope."
The two images differ in 1299724 bytes \(em removing 168 instructions shifts
every later address \(em but the shift is 672 bytes, a multiple of four, so
every embedded data word keeps its value and its alignment and therefore its
contribution to both arms is identical and cancels.
.LP
.B "And the third measurement needs no mask at all:"
.CW iraspi3b
shrinks by 672 bytes, which is exactly 168 instructions, and the
.CW SXTW ,
.CW "MOV Wd,Wn"
and
.CW RET
masks used elsewhere in this document score
.B zero
on the same random control, so the method is sound where it is tight and only
these two counters were loose.
.LP
.B "The 345 in the first version of the table was wrong, and so was 333."
Both came from a counting build that printed at the substitution and then
returned 0, which prevented
.CW excise
and left
.CW t
at zero \(em so
.CW loop1
re-ran and tagged the same site on every pass.  Counting at a
.I successful
fold, where the site is consumed, gives 164 across the 152 kernel sources that
compile standalone, against 168 in the full 460-source image.  A counter placed
where the work is abandoned counts attempts, not work.
.LP
.B "One thing found by accident and worth more than the optimisation."
.CW copyu ,
whose third argument is nil for a query and an
.CW Adr*
for a substitution,
.B "mutates the program when it is merely asked a question:"
.CW "if(copyas(&p->to, v)) { if(p->reg == NREG) p->reg = p->to.reg;"
at
.CW peep.c :1168.
It normalises a two-operand
.CW ADD
into three-operand form as a side effect.  It is semantically inert \(em
.CW "ADD R4,R2"
and
.CW "ADD R4,R2,R2"
are the same instruction \(em which is why nobody has noticed, and it cost an
hour here because enabling a pass that only
.I asks
changed the output of three functions.
.B "An analysis pass in this compiler cannot be assumed not to transform."
.NH 2
The honest summary
.LP
.B "BOTH OF THE YES ROWS WERE TRIED, AND BOTH ANSWERS CHANGED,"
which is the most useful thing in this section.
.LP
.B "branch-to-next: implemented, and it buys NOTHING in the shipped kernel."
The compiler emitted 153 of them in 135333 instructions and emits none now
\(em measured, exactly 153 fewer, compile time unchanged.  But a full rebuild
produced a kernel image of
.B "exactly the same size,"
2655592 bytes, and the built image contains
.B "zero"
branch-to-next instructions either way.
.CW 7l
has
.CW xfol() ,
a branch-following pass called from
.CW follow() ,
which straightens them at link time.
.B "So the win is in the LISTING, not in the code that ships."
It is kept at eight lines because a branch to the next instruction is noise
when reading generated code to hunt a codegen bug, which is what most of this
document was written while doing \(em but it is
.B "not a code-quality improvement"
and the row above says so.
.LP
.B "duplicate RETURN: tried, removed, and the reason is the useful part."
Neither a
.CW uniqp()
test nor an unreachability test fires, because
.CW reg.c
leaves
.CW p1
SET on the second RETURN \(em instrumented and confirmed, 456 sites and 0
removed.  The epilogue is emitted
.I unconditionally
by the SHARED front end:
.CW utils/cc/pgen.c
calls
.CW gbranch(ORETURN)
after the body even when its own
.CW canreach
already says the body returned.
.B "So the fix belongs in the front end, where it is one line and eleven compilers' blast radius,"
not in a per-architecture peephole.  The dead case was deleted rather than left
in place, because code that looks like an optimisation and never fires is worse
than no code.
.LP
.B "THE FRONT-END FIX WAS THEN TRIED, AND IT IS A NO ON TWO INDEPENDENT"
.B "GROUNDS."
.LP
First,
.B "456 is the LISTING count and 77 is the shipping count."
A duplicate RETURN pair appears at the end of essentially every function in
.CW 7c 's
listing \(em 31 pairs in
.CW chan.c
alone \(em but the linked kernel contains 9936
.CW RET
instructions and only
.B 77
adjacent
.CW "RET - RET"
pairs.  So something between the listing and the image already removes about 99
per cent of them, and the ceiling on the fix is 77 instructions, not 456.  That
is 0.57 per 1000, which this table calls marginal at 69, for a change to the
shared front end rather than eight lines in one compiler.
.B "This is the same error as the branch-to-next row,"
made again: a count taken from the compiler's output is not a count of what
ships.
.LP
Second, and decisively,
.B "the one line does not work."
The guard is
.P1
	noretval(3);
	if(canreach)
		gbranch(ORETURN);
.P2
.LP
and with it every object file in the kernel becomes unreadable to
.CW 7l :
.P1
	iseve: truncated object file: auth.7
	now: truncated object file: clock.7
	segflush: truncated object file: main.7
	...
.P2
.LP
one line per object, naming the symbol the loader was reading when the text ran
out, and then
.CW "too many errors" .
.B "The trailing epilogue is load-bearing in the object encoding,"
not merely a redundant instruction \(em so \(lqdelete the unreachable
RETURN\(rq is not a one-line change in the front end either, and the row is
closed.
.LP
.B "What it cost to find out, which is the reason it is written down:"
the failed build removes
.CW kernel8.img ,
and it ran while a
.CW kinstall
was in its pre-flight with that file as the candidate \(em so the rebuild that
repaired the tree also invalidated a card install in flight, which had to be
stopped and restarted.
.B "A measurement build of a shared front end is not a side-effect-free experiment."
.LP
.B "shiftprop: investigated, and the investigation licensed the port."
It was switched off with no comment, which in this tree has meant "it was
wrong" more often than "nobody got round to it" \(em and the answer turned out
to be neither.
.B "It had never been ported from 32-bit ARM,"
in six places, of which the field layout and 7c's own listing printer are the
two that produced visibly wrong output.  Ported, and
.B "168 instructions leave the kernel,"
measured three ways that agree to within one.  The section above has the
defects and the byte-level verification;
.CW tests/kencc-shiftfold.sh
is the guard, and it has been seen to fail in both directions.
.B "The 345 in the table was also wrong,"
by the same mechanism twice: a counter at the point where the pass gives up
counts attempts, not work.  The real figure is 164 over the kernel sources that
compile standalone.
.LP
.B "Not appropriate, and the reason differs:"
MADD and spill/reload are too rare to pay for their risk; width-aware copyprop
is the right fix for a known defect but belongs behind a test first;
switch-to-arithmetic and the loop transforms need infrastructure larger than the
compiler; and the register-argument ABI is not an optimisation at all \(em it is
a large part of the 2.4x and no pass can touch it.
.LP
.B "What that means for ""best quality, near instantly""."
The reachable target is not clang's 2.4x.  It is the tier-one half of one per
cent, bought for nothing, plus a correctness story that is already better than
clang's for this tree's purposes \(em because
.CW tests/toolchain
and the loaders' own refusals now catch defect classes that clang's optimiser
would simply not have.
.B "kencc's advantage was never its code quality; it is that you can read it,"
and every entry in the "no" column above is there to keep that true.
.NH 1
REAL Plan 9 code, which halves the gap my synthetic benchmark reported
.LP
.B "The suggestion was Harvey, and it was the right instinct for a reason"
.B "worth stating:"
Harvey OS exists because Plan 9's kernel and userspace were made to compile
under clang, so it is the proof that this comparison can be done on real code
rather than on six functions somebody wrote to make a point.  Harvey is not in
this tree, but
.B "what it proves is available locally:"
.CW 9front/src
is 392 files of actual Plan 9 userspace \(em
.CW libc ,
.CW libdraw ,
.CW libframe ,
.CW libmemdraw ,
.CW lib9p ,
.CW cmd
\(em and both toolchains accept it.
.LP
.B "333 files compiled by BOTH, the only honest denominator:"
.P1
6c      74623 instructions
clang   50665 instructions
aggregate ratio   1.47x
median per file   1.27x
clang WORSE than 6c on 51 of 333 files (15%)
deciles  0.39 0.91 1.03 1.13 1.21 1.27 1.36 1.43 1.57 1.77
.P2
.B "MY SYNTHETIC BENCHMARK OVERSTATED THE GAP BY ABOUT TWO TIMES."
It reported 2.4x; real Plan 9 userspace is 1.27x at the median.
.B "The reason is the benchmark's shape, not clang's:"
five of those six functions were tiny leaves, where kencc's per-function cost
\(em the stack-argument ABI and the prologue copies \(em is most of the
instruction count and amortises over nothing.
.CW leaf
at 5.0x was measuring the ABI.
.B "Real library functions are bigger, so that fixed cost is divided by more work."
That is this tree's own rule about testing the shape that bites, applied to a
benchmark I wrote myself four hours earlier.
.LP
.B "Use the MEDIAN here and not the mean."
The mean per-file ratio is
.B 5.29x
against a median of 1.27, because a handful of files are enormous outliers.
A mean that sits four times its own median is describing the tail, which is the
same mistake as range-disjointness being decided by one sample.
.NH 2
Two findings that only real code could give
.LP
.B "clang is WORSE on 15 per cent of the files,"
and the first decile is
.B 0.39x
\(em
.CW atan.c
is 75 instructions from 6c against 192 from clang.
.CW -O1
still inlines and unrolls, so on small numeric code it spends instructions
kencc does not.
.B "A single aggregate ratio hides that entirely."
.LP
.B "And clang could not compile 57 of the 390 files at all \(em 15 per cent \(em"
.B "while 6c failed on 2."
Nothing compiled only under clang.
.B "That is the real price of the clang route and it is exactly the work Harvey did:"
not optimisation, but changing Plan 9 source until a standards-checking front
end accepts it.
.B "So the comparison is not kencc against clang on equal terms."
It is kencc on the code as written against clang on the 85 per cent of it that
clang agrees to read.
.NH 2
What that does to the tradespace
.LP
.B "It lowers the ceiling, which makes the reject column easier rather than harder."
The reachable prize was never 2.4x; on real code the whole distance is 1.27x at
the median, and a large part of that is the ABI, which is not an optimisation.
.B "The tier-one items are worth about half a per cent of that distance."
Closing the rest means SSA, value ranges, inlining and loop transforms \(em and
the measured consequence of having them is a front end that rejects 15 per cent
of this tree's own source and a compiler that takes five times longer with its
optimiser switched off.
