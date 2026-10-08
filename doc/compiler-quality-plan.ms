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
duplicate RETURN      456   3.37      ~8  flow    low    YES, first
shift fold (shiftprop)345   2.55       0  flow    HIGH   investigate only
branch to next instr  153   1.13      ~8  none    low    LISTING only
adjacent spill/reload  69   0.51      ~8  none    low    marginal
width-aware copyprop    ?      ?     ~40  flow    HIGH   only with a test
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
.B "Appropriate to INVESTIGATE, not to enable:"
.CW shiftprop ,
because 345 sites is the largest number in the table and the code already
exists \(em but it is switched off with no comment, which in this tree has
meant "it was wrong" more often than "nobody got round to it".
.B "Finding out why it is off is the task, not turning it on."
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
