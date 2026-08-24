/*
 * Integer division for an ARMv7-M core.
 *
 * Every ARMv7-M core has SDIV and UDIV, so the shift-and-subtract
 * routine the ARM port carries (../libkern/div-arm.s) is not needed
 * here.  The assembler has no word for either instruction, so they are
 * written down as raw halfword pairs, the way ../libkern/ainc-thumb.s
 * writes the exclusive monitor.
 *
 * The calling sequence is the linker's, not C's: utils/tl/noop.c turns a
 * DIV into "SUB $8,SP; MOVW divisor,4(SP); MOVW dividend,REGTMPT; BL;
 * MOVW REGTMPT,dst; ADD $8,SP".  So the dividend arrives in R7 and
 * leaves in R7, the divisor is at 4(SP), 0(SP) is a spare word, and
 * every other register has to come back unchanged.
 *
 *	SDIV Rd, Rn, Rm		fb90+Rn  f0f0|(Rd<<8)|Rm
 *	UDIV Rd, Rn, Rm		fbb0+Rn  f0f0|(Rd<<8)|Rm
 *	MLS  Rd, Rn, Rm, Ra	fb00+Rn  (Ra<<12)|(Rd<<8)|0010|Rm
 */

#define	T2(hw1, hw2)	WORD	$((((hw2)&0xffff)<<16)|((hw1)&0xffff))
#define	SDIVW(rd, rn, rm)	T2(0xfb90|(rn), 0xf0f0|((rd)<<8)|(rm))
#define	UDIVW(rd, rn, rm)	T2(0xfbb0|(rn), 0xf0f0|((rd)<<8)|(rm))
#define	MLSW(rd, rn, rm, ra)	T2(0xfb00|(rn), ((ra)<<12)|((rd)<<8)|0x0010|(rm))

TEXT	_div(SB), 1, $-4
	MOVW	R1, 0(R13)		/* the caller's spare word */
	MOVW	4(R13), R1
	SDIVW(7, 7, 1)
	MOVW	0(R13), R1
	RET

TEXT	_divu(SB), 1, $-4
	MOVW	R1, 0(R13)
	MOVW	4(R13), R1
	UDIVW(7, 7, 1)
	MOVW	0(R13), R1
	RET

TEXT	_mod(SB), 1, $-4
	SUB	$8, R13
	MOVW	R1, 0(R13)
	MOVW	R2, 4(R13)
	MOVW	12(R13), R1		/* the divisor, 8 lower than it was */
	SDIVW(2, 7, 1)
	MLSW(7, 2, 1, 7)		/* R7 -= R2*R1 */
	MOVW	0(R13), R1
	MOVW	4(R13), R2
	ADD	$8, R13
	RET

TEXT	_modu(SB), 1, $-4
	SUB	$8, R13
	MOVW	R1, 0(R13)
	MOVW	R2, 4(R13)
	MOVW	12(R13), R1
	UDIVW(2, 7, 1)
	MLSW(7, 2, 1, 7)
	MOVW	0(R13), R1
	MOVW	4(R13), R2
	ADD	$8, R13
	RET
