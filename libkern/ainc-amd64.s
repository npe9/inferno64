/*
 * Atomic add, the way this tree does an instruction the C compiler has
 * no word for: an assembly function, linked in.  getcallerpc is the
 * same idea.
 *
 * Both return the value the memory holds afterwards, which is what a
 * caller freeing on "did I take it to zero" needs.
 */

TEXT	ainc(SB), $0			/* int ainc(int*) */
	MOVL	$1, AX
	LOCK; XADDL AX, (RARG)		/* AX = old, (RARG) = old+1 */
	ADDL	$1, AX
	RET

TEXT	adec(SB), $0			/* int adec(int*) */
	MOVL	$-1, AX
	LOCK; XADDL AX, (RARG)		/* AX = old, (RARG) = old-1 */
	SUBL	$1, AX
	RET
