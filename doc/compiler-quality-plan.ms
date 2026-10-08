.TL
Improving kencc's code quality without making it bigger
.AU
raspi3b-port
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
