/*
 * Atomic add, the way this tree does an instruction the C compiler has
 * no word for: an assembly function, linked in.  getcallerpc is the
 * same idea.
 *
 * Both return the value the memory holds afterwards, which is what a
 * caller freeing on "did I take it to zero" needs.
 *
 * The amd64 file beside this one does it in one instruction with XADDL,
 * which 8a has no word for and the 386 did not have until the 486.  A
 * compare and exchange in a loop says the same thing: read what is
 * there, work out what it should become, and put it back only if
 * nothing else changed it meanwhile.  The 386 also takes its argument
 * off the stack rather than in RARG; this file was a copy of the amd64
 * one, RARG and all, and had never been assembled.
 */

TEXT	ainc(SB), $0			/* int ainc(int*) */
	MOVL	p+0(FP), BX
_incloop:
	MOVL	(BX), AX		/* AX is what CMPXCHGL compares */
	MOVL	AX, CX
	ADDL	$1, CX
	LOCK; CMPXCHGL CX, (BX)
	JNE	_incloop
	MOVL	CX, AX
	RET

TEXT	adec(SB), $0			/* int adec(int*) */
	MOVL	p+0(FP), BX
_decloop:
	MOVL	(BX), AX
	MOVL	AX, CX
	SUBL	$1, CX
	LOCK; CMPXCHGL CX, (BX)
	JNE	_decloop
	MOVL	CX, AX
	RET

/*
 * Atomic read-and-clear of an int: return what *p held and leave zero,
 * indivisibly.  XCHG with a memory operand carries an implied LOCK on
 * x86, so this one needs no loop.  See the amd64 file for what the
 * collector wants it for.
 */
TEXT	aclr(SB), $0			/* int aclr(int*) */
	MOVL	p+0(FP), BX
	MOVL	$0, AX
	XCHGL	AX, (BX)		/* AX = old *p, *p = 0 */
	RET
