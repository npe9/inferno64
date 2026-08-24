/*
 * The ARMv7-M floating point control and status word.  VFP has one
 * register, FPSCR, holding both, so the control pair and the status pair
 * read and write the same place; Inferno/thumb/include/u.h says which
 * bits mean what.
 *
 *	VMRS Rt, FPSCR		eef1 0a10 | Rt<<12
 *	VMSR FPSCR, Rt		eee1 0a10 | Rt<<12
 */

#define	T2(hw1, hw2)	WORD	$((((hw2)&0xffff)<<16)|((hw1)&0xffff))
#define	VMRSFP(rt)	T2(0xeef1, 0x0a10|((rt)<<12))
#define	VMSRFP(rt)	T2(0xeee1, 0x0a10|((rt)<<12))

TEXT	getfcr(SB), 1, $-4
	VMRSFP(0)
	RET

TEXT	setfcr(SB), 1, $-4
	VMSRFP(0)
	RET

TEXT	getfsr(SB), 1, $-4
	VMRSFP(0)
	RET

TEXT	setfsr(SB), 1, $-4
	VMSRFP(0)
	RET
