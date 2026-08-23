/*
 * Atomic add, the way this tree does an instruction the assembler has no
 * word for: build it out of a macro and link the function in.  l.s does
 * the same for load-reserved and store-conditional, and getcallerpc is
 * the same idea one step simpler.
 *
 * amoadd.w rd, rs2, (rs1):  rd = M[rs1]; M[rs1] = rd + rs2
 *
 *	31..27 funct5=00000   26 aq   25 rl   24..20 rs2
 *	19..15 rs1   14..12 funct3=010   11..7 rd   6..0 opcode=0101111
 *
 * Both return the value the memory holds afterwards, which is what a
 * caller freeing on "did I take it to zero" needs.
 */

#define RARG	R8
#define AQ	(1<<26)
#define RL	(1<<25)
#define AMOADDW(rs2, rs1, rd) \
	WORD $((0<<27)|AQ|RL|((rs2)<<20)|((rs1)<<15)|(2<<12)|((rd)<<7)|057)

TEXT	ainc(SB), 1, $-4		/* int ainc(int*) */
	MOV	RARG, R12
	MOV	$1, R10
	AMOADDW(10, 12, 8)		/* R8 = old, (R12) = old+1 */
	ADD	$1, R8
	RET

TEXT	adec(SB), 1, $-4		/* int adec(int*) */
	MOV	RARG, R12
	MOV	$-1, R10
	AMOADDW(10, 12, 8)		/* R8 = old, (R12) = old-1 */
	ADD	$-1, R8
	RET
