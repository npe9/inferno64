/*
 * Atomic add on an ARMv7-M core, built the way the RISC-V one is: the
 * assembler has no word for the exclusive monitor, so the encodings are
 * written down as raw halfword pairs.  See os/inferno/armv7m/armv7m.h,
 * which spells out the same two instructions for the kernel's own use;
 * this file cannot include that header because libkern is built for
 * every board and knows about none of them.
 *
 *	LDREX Rt, [Rn]		e850+Rn  (Rt<<12)|0f00
 *	STREX Rd, Rt, [Rn]	e840+Rn  (Rt<<12)|(Rd<<8)
 *	DMB SY			f3bf     8f5f
 *
 * Both return the value the memory holds afterwards, which is what a
 * caller freeing on "did I take it to zero" needs.
 */

#define	T2(hw1, hw2)		WORD	$((((hw2)&0xffff)<<16)|((hw1)&0xffff))
#define	LDREXW(rt, rn)		T2(0xe850|(rn), ((rt)<<12)|0x0f00)
#define	STREXW(rd, rt, rn)	T2(0xe840|(rn), ((rt)<<12)|((rd)<<8))
#define	DMBSY			T2(0xf3bf, 0x8f5f)

TEXT	ainc(SB), 1, $-4		/* int ainc(int*) */
	MOVW	R0, R3
_incloop:
	LDREXW(1, 3)
	ADD	$1, R1
	STREXW(2, 1, 3)
	CMP	$0, R2
	BNE	_incloop
	DMBSY
	MOVW	R1, R0
	RET

TEXT	adec(SB), 1, $-4		/* int adec(int*) */
	MOVW	R0, R3
_decloop:
	LDREXW(1, 3)
	SUB	$1, R1
	STREXW(2, 1, 3)
	CMP	$0, R2
	BNE	_decloop
	DMBSY
	MOVW	R1, R0
	RET

/*
 * Atomic read-and-clear of an int: return what *p held and leave zero.
 * One core here, but the exclusive pair costs nothing and says what is
 * meant; see the amd64 file for what the collector wants it for.
 */
TEXT	aclr(SB), 1, $-4		/* int aclr(int*) */
	MOVW	R0, R3
	MOVW	$0, R2
_clrloop:
	LDREXW(1, 3)
	STREXW(4, 2, 3)
	CMP	$0, R4
	BNE	_clrloop
	DMBSY
	MOVW	R1, R0
	RET
