#include	"l.h"

/*
 * checkout - refuse to emit an instruction that cannot be right.
 *
 * Called from asmb() between oplook() and asmout(), so it sees every
 * instruction in the program together with the optab entry chosen for it,
 * once, with no extra pass.
 *
 * IT ASSERTS AND IT DOES NOT TRANSFORM.  That is the whole reason it is
 * affordable: a check that refuses is a conditional, while a check that
 * repairs is a pass, and this loader is 20000 lines precisely because nobody
 * has added passes to it.  If something here ever wants to know about
 * registers, liveness or types, it has outgrown this file and should not be
 * fixed by growing it.
 *
 * WHY AT ALL.  Every defect this tree has found in 7l and 6l was a SILENT
 * miscompile: the loader exited 0 and the program was wrong.  A branch to
 * itself inside panic() shipped in every real kernel and was found by scanning
 * a binary, not by any test.  tests/kencc-selfbranch.sh now scans, but a scan
 * only runs when someone runs it and can only read the images it understands --
 * 3 of 17 in this tree, because selfbranch.py takes aarch64 ELF only and the
 * rest are riscv64, ELF32 or Plan 9 a.out.  A refusal here covers every image
 * on every target, every time.
 *
 * WHAT IT DELIBERATELY DOES NOT CHECK, learned the expensive way an hour
 * before this file was written: C_VCON looks like a dead operand class --
 * aclass() never returns it -- and a checker written from that reading would
 * reject every ADWORD, because C_VCON is an OPTAB-SIDE class and cmp() is
 * asymmetric.  So nothing here reasons about what a class "should" be.  The
 * rule is: only assert properties that are wrong under every reading.
 */

/*
 * A CONDITIONAL branch to itself, which is the shape that shipped.
 *
 * Not any self-branch: `for(;;) ;' is legitimate C and compiles to an
 * unconditional B to itself, so a blanket test would reject correct programs.
 * A conditional branch to itself cannot be anything but wrong -- it either
 * spins forever on a condition nothing in the loop can change, or falls
 * through, and no source construct asks for that.  The defect was B.cond +0.
 *
 * The opcode list is noop.c's, minus AB and ABCASE which are unconditional,
 * and minus ABL which is a call.
 */
static int
condbranch(int a)
{
	switch(a) {
	case ACBZ:
	case ACBNZ:
	case ACBZW:
	case ACBNZW:
	case ATBZ:
	case ATBNZ:
	case ABEQ:
	case ABNE:
	case ABCS:
	case ABHS:
	case ABCC:
	case ABLO:
	case ABMI:
	case ABPL:
	case ABVS:
	case ABVC:
	case ABHI:
	case ABLS:
	case ABGE:
	case ABLT:
	case ABGT:
	case ABLE:
		return 1;
	}
	return 0;
}

void
checkout(Prog *p, Optab *o)
{
	USED(o);

	if(p->cond == P)
		return;

	if(p->cond == p && condbranch(p->as))
		diag("%s: conditional branch to itself at %llux: %P",
			"REFUSING", p->pc, p);
}
