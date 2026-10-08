#include	"l.h"

/*
 * checkout - refuse to emit an instruction that cannot be right.
 *
 * The amd64 half of utils/7l/check.c, and the loader that needs it MORE.
 *
 * WHY 6l ESPECIALLY.  A conditional branch to itself inside panic() was real
 * here too and was fixed in b97ac24d0 ("6l: finish the amd64 half -- it was
 * emitting a self-branch inside panic()").  But 7l's defect is now covered two
 * ways, by this check and by tests/kencc-selfbranch.sh scanning built kernels,
 * while 6l's is covered by NEITHER: selfbranch.py reads 64-bit ELF of machine
 * 183 only, and os/inferno/pc64/ipc64 is Plan 9 a.out -- the scan reports it as
 * "not ELF" and skips it.  So before this file, nothing in the tree could see
 * the defect come back on amd64.
 *
 * Same discipline as the aarch64 one: it ASSERTS and does not transform.  A
 * check that refuses is a conditional; a check that repairs is a pass.
 *
 * CONDITIONAL ONLY.  `for(;;) ;' is legitimate C and compiles to an
 * unconditional JMP to itself, so a blanket self-branch test would reject
 * correct programs -- the kernels are full of idle loops.  A conditional jump
 * to itself cannot be anything but wrong: it either spins forever on a
 * condition nothing in the loop can change, or falls through once.
 *
 * The opcode list is relinv()'s in pass.c, which exists to map every
 * conditional jump to its inverse and is therefore authoritative -- taking it
 * from there rather than writing one out means a jump added to the assembler
 * cannot be silently missed by this check as long as relinv knows about it.
 */
static int
condjump(int a)
{
	switch(a) {
	case AJCC:
	case AJCS:
	case AJEQ:
	case AJGE:
	case AJGT:
	case AJHI:
	case AJLE:
	case AJLS:
	case AJLT:
	case AJMI:
	case AJNE:
	case AJOC:
	case AJOS:
	case AJPC:
	case AJPL:
	case AJPS:
		return 1;
	}
	return 0;
}

void
checkout(Prog *p)
{
	if(p->pcond == P)
		return;

	if(p->pcond == p && condjump(p->as))
		diag("%s: conditional jump to itself at %llux: %P",
			"REFUSING", p->pc, p);
}
