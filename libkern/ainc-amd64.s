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

/*
 * Atomic exchange: store v at *p and return what was there, in one
 * indivisible step.
 *
 * What it is for.  OP(movp) assigns a Dis pointer variable as read,
 * store, drop the old value:
 *
 *	dv = P(d);  P(d) = sv;  destroy(dv);
 *
 * a read-modify-write.  Module-level variables live in the Modlink's
 * MP, which every Prog of that module shares, so two executors can read
 * the same dv, both store, and both destroy it -- one object, two
 * drops.  Swapping instead means each executor destroys exactly the
 * value it displaced and no value is displaced twice.
 *
 * XCHG with a memory operand is atomic on x86 without a LOCK prefix;
 * the prefix is implied by the architecture for this instruction.
 */
TEXT	aswap(SB), $0			/* void* aswap(void**, void*) */
	MOVQ	v+8(FP), AX
	XCHGQ	AX, (RARG)		/* AX = old *p, *p = v */
	RET

/*
 * Atomic read-and-clear of an int: return what *p held and leave zero,
 * indivisibly.  XCHG with a memory operand is atomic on x86 without a
 * LOCK prefix, as above; the L suffix because the caller's flag is an
 * int and the field beside it must not be touched.
 *
 * What it is for: the collector's "did anything get marked" flag,
 * nprop.  Testing it and then clearing it in two steps loses a mark
 * that lands in between, and a lost mark at an epoch boundary ends the
 * epoch with a grey object -- which the sweeper then takes.
 */
TEXT	aclr(SB), $0			/* int aclr(int*) */
	MOVL	$0, AX
	XCHGL	AX, (RARG)		/* AX = old *p, *p = 0 */
	RET
