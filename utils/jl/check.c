#include	"l.h"

/*
 * checkout - refuse to emit an instruction that cannot be right.
 *
 * The riscv64 copy of utils/7l/check.c.  jl is the loader with the WIDEST
 * reach in this tree: it links six of the seventeen boards -- spike, virt,
 * virts, sifiveu, shakti and mangopi -- against 7l's three and 6l's one.
 *
 * AND IT HAD NO COVERAGE AT ALL.  tests/kencc-selfbranch.sh scans built
 * kernels, but selfbranch.py accepts e_machine 183 (EM_AARCH64) only, and
 * every riscv64 image is machine 243 -- the scan reports them as skipped.  So
 * the defect that shipped in panic() of every real kernel on two other
 * architectures could have appeared here and nothing would have said so.
 *
 * Same discipline as the other two: it ASSERTS and does not transform.
 * Conditional branches only, because `for(;;) ;' is legitimate C, compiles to
 * an unconditional branch to itself, and every one of those six kernels has an
 * idle loop.
 *
 * The opcode list is relinv()'s in pass.c, which maps every conditional branch
 * to its inverse and is therefore authoritative: a branch added to the
 * assembler cannot be missed here as long as relinv knows about it.  RISC-V's
 * set is small -- six, against aarch64's twenty-two and amd64's sixteen --
 * because the ISA folds the comparison into the branch.
 */
static int
condbranch(int a)
{
	switch(a) {
	case ABEQ:
	case ABNE:
	case ABLT:
	case ABLTU:
	case ABGE:
	case ABGEU:
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

	/*
	 * %lux, not %llux: jl's Prog.pc is a long where 7l's is a vlong, and
	 * kencc's long is 32 bits.  Getting that wrong is the host-type
	 * leakage this tree has a memory about, in a diagnostic that only
	 * prints when something is already wrong.
	 */
	if(p->cond == p && condbranch(p->as))
		diag("%s: conditional branch to itself at %lux: %P",
			"REFUSING", p->pc, p);
}
