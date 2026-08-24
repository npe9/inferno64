/*
 * The two 64 bit helpers utils/tc calls out to, for an ARMv7-M core.
 *
 * UMULL, UMLAL and MUL are all in the Thumb-2 instruction set; as
 * elsewhere in this directory the encodings are written down because the
 * assembler has no word for them.  vlong words are in memory low half
 * first, which is the order ../libkern/vlrt-arm.c uses and the order a
 * little-endian core stores them in.
 *
 *	UMULL RdLo, RdHi, Rn, Rm	fba0+Rn  (RdLo<<12)|(RdHi<<8)|Rm
 *	UMLAL RdLo, RdHi, Rn, Rm	fbe0+Rn  (RdLo<<12)|(RdHi<<8)|Rm
 *	MUL   Rd, Rn, Rm		fb00+Rn  f000|(Rd<<8)|Rm
 */

#define	T2(hw1, hw2)	WORD	$((((hw2)&0xffff)<<16)|((hw1)&0xffff))
#define	UMULLW(rdlo, rdhi, rn, rm)	T2(0xfba0|(rn), ((rdlo)<<12)|((rdhi)<<8)|(rm))
#define	UMLALW(rdlo, rdhi, rn, rm)	T2(0xfbe0|(rn), ((rdlo)<<12)|((rdhi)<<8)|(rm))
#define	MULW(rd, rn, rm)		T2(0xfb00|(rn), 0xf000|((rd)<<8)|(rm))

/* void _mulv(Vlong *r, Vlong a, Vlong b) */
TEXT	_mulv(SB), 1, $-4
	MOVW	4(FP), R1		/* a.lo */
	MOVW	8(FP), R2		/* a.hi */
	MOVW	12(FP), R3		/* b.lo */
	MOVW	16(FP), R4		/* b.hi */
	UMULLW(5, 6, 1, 3)		/* R6:R5 = a.lo * b.lo */
	MULW(7, 2, 3)			/* a.hi * b.lo */
	ADD	R7, R6
	MULW(7, 1, 4)			/* a.lo * b.hi */
	ADD	R7, R6
	MOVW	R5, 0(R0)
	MOVW	R6, 4(R0)
	RET

/*
 * ulong _mularsv(ulong m0, ulong m1, ulong a, uint rs)
 * (m0*m1 + a) >> rs, with the multiply done to 64 bits.
 */
TEXT	_mularsv(SB), 1, $-4
	MOVW	4(FP), R1		/* m1 */
	MOVW	8(FP), R2		/* a: the low half of the sum */
	MOVW	12(FP), R3		/* rs */
	MOVW	$0, R4			/* and the high half */
	UMLALW(2, 4, 0, 1)		/* R4:R2 += R0 * R1 */
	SRL	R3, R2
	MOVW	$32, R5
	SUB	R3, R5			/* 32 - rs; a shift of 32 gives zero */
	SLL	R5, R4
	ORR	R4, R2
	MOVW	R2, R0
	RET
