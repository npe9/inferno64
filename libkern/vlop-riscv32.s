/*
 * _mulv: 64x64->64 (truncated) unsigned multiply, the one vlong helper
 * every other vlop-*.s hand-writes in native multiply/high-multiply
 * instructions instead of leaving to vlrt-riscv32.c's portable C.
 * za's own convention (utils/zc/z.out.h): REGARG/REGRET is R1, used
 * here as kencc's usual hidden-result-pointer register -- same
 * mechanism vlop-mips.s relies on, just RISC-V's MUL/MULHU in place
 * of MIPS's MULU + LO/HI.  Vlong is {ulong lo; ulong hi;} (see
 * vlrt-riscv32.c): lo at offset 0, hi at offset 4, because RISC-V is
 * little-endian.  This file used to say hi first, having been written
 * against a vlrt-riscv32.c copied from big-endian vlrt-mips.c; that
 * whole chain is corrected now, and the offsets here are half of the
 * correction -- with only the C side swapped, every vlong multiply on
 * the machine returns zero, because this routine reads a.lo out of the
 * slot the caller put a.hi in.  Arg layout (4(FP)..19(FP), 0(FP)
 * unused) matches vlop-mips.s's own -- this ABI's FP-relative call
 * frame is the same shape regardless of architecture.
 */
TEXT	_mulv(SB), $0
	MOVW	4(FP), R10		/* a.lo */
	MOVW	8(FP), R11		/* a.hi */
	MOVW	12(FP), R12		/* b.lo */
	MOVW	16(FP), R13		/* b.hi */

	MUL	R10, R12, R14		/* lo = a.lo * b.lo */
	MULHU	R10, R12, R15		/* hi = high32(a.lo * b.lo) */

	MUL	R11, R12, R16		/* a.hi * b.lo, low bits only matter */
	ADD	R16, R15
	MUL	R10, R13, R16		/* a.lo * b.hi, low bits only matter */
	ADD	R16, R15

	MOVW	R14, 0(R1)		/* lo */
	MOVW	R15, 4(R1)		/* hi */
	RET
