/*
 * userregtorture for 386: does a SYSTEM CALL give back every register?
 *
 * The same question os/osprey/pc64/userregtorture.s asks, asked of this
 * kernel's other entry.  Here that entry is INT $64: l.s vectors it to
 * _syscallintr, which saves every general register with PUSHAL, and the
 * call returns through forkret, which restores them with POPAL.  trap.c
 * writes one of them, ureg->ax, with the call's answer.  So everything
 * but AX is expected back, and the six that can be are BX, CX, DX, SI,
 * DI and BP - on 386 none of them is spent on the call itself, unlike
 * CX, R11 and RARG on amd64.  SP is not among them: the loop reads its
 * own frame through it, so a lost SP would fail the loop in a way no
 * comparison needs to name.
 *
 * The call is pwrite(2, sp, 0, -1), a write of no bytes to the console,
 * for the reasons the amd64 file gives.  Its arguments go on the stack
 * where trap.c reads them, at sp+BY2WD, and the offset is a vlong, so
 * the arguments are five words - which is MAXSYSARG here, so there is
 * nothing above them the kernel could read as one.
 *
 * Nothing is stored in a global, since the program is flat-loaded with
 * no data segment of its own; the value a register came back with goes
 * through the pointer the caller supplies.
 *
 *	long userregtorture(long n, uvlong *badp)
 *
 * Answers 0 if every register survived n system calls, with the number
 * made stored through badp; otherwise the register's index, 1 for BX
 * through 6 for BP (the first four as the amd64 file numbers them), with
 * the value it came back as stored through badp.
 *
 * After the SUBL:
 *	0(SP)	the counter, in the word the kernel skips
 *	4(SP)	a0, the console
 *	8(SP)	a1, an address the zero-length write can name
 *	12(SP)	a2, no bytes
 *	16(SP)	a3, the offset, low word
 *	20(SP)	a3, the offset, high word
 *	24(SP)	the return address
 *	28(SP)	n, and 32(SP) badp, as the caller passed them
 *
 * The caller's two words are read where the caller put them rather than
 * copied: on 386 8c passes every argument on the stack, and the kernel
 * reads the five words below them and writes none.
 */
TEXT userregtorture(SB), 1, $0
	SUBL	$24, SP

	MOVL	$0, AX
	MOVL	AX, 0(SP)		/* how many have been made */
	MOVL	AX, 12(SP)		/* a2: no bytes */
	MOVL	$2, AX
	MOVL	AX, 4(SP)		/* a0: the console */
	LEAL	24(SP), AX		/* a stack address, valid to name */
	MOVL	AX, 8(SP)		/* a1 */
	MOVL	$-1, AX
	MOVL	AX, 16(SP)		/* a3: the offset */
	MOVL	AX, 20(SP)

	MOVL	$0x21111111, BX
	MOVL	$0x22222222, DX
	MOVL	$0x23333333, SI
	MOVL	$0x24444444, DI
	MOVL	$0x25555555, CX
	MOVL	$0x26666666, BP

_urloop:
	MOVL	$51, AX			/* PWRITE */
	INT	$64

	CMPL	BX, $0x21111111
	JNE	_urbad1
	CMPL	DX, $0x22222222
	JNE	_urbad2
	CMPL	SI, $0x23333333
	JNE	_urbad3
	CMPL	DI, $0x24444444
	JNE	_urbad4
	CMPL	CX, $0x25555555
	JNE	_urbad5
	CMPL	BP, $0x26666666
	JNE	_urbad6

	MOVL	0(SP), AX
	ADDL	$1, AX
	MOVL	AX, 0(SP)
	CMPL	AX, 28(SP)
	JNE	_urloop

	/* how many calls were actually made, for the caller to print */
	MOVL	32(SP), BX
	MOVL	0(SP), AX
	MOVL	AX, 0(BX)
	MOVL	$0, 4(BX)

	ADDL	$24, SP
	MOVL	$0, AX
	RET

/*
 * Each of these stores what the register came back as through the
 * caller's pointer, a uvlong, and answers with the register's number.
 * AX is free to hold the pointer: it is the call's answer and was
 * never compared.
 */
_urbad1:
	MOVL	32(SP), AX
	MOVL	BX, 0(AX)
	MOVL	$1, BX
	JMP	_urdone
_urbad2:
	MOVL	32(SP), AX
	MOVL	DX, 0(AX)
	MOVL	$2, BX
	JMP	_urdone
_urbad3:
	MOVL	32(SP), AX
	MOVL	SI, 0(AX)
	MOVL	$3, BX
	JMP	_urdone
_urbad4:
	MOVL	32(SP), AX
	MOVL	DI, 0(AX)
	MOVL	$4, BX
	JMP	_urdone
_urbad5:
	MOVL	32(SP), AX
	MOVL	CX, 0(AX)
	MOVL	$5, BX
	JMP	_urdone
_urbad6:
	MOVL	32(SP), AX
	MOVL	BP, 0(AX)
	MOVL	$6, BX

_urdone:
	MOVL	$0, 4(AX)
	MOVL	BX, AX
	ADDL	$24, SP
	RET

/*
 * How many registers the loop above compares, so the caller can say so
 * without knowing which object type it was built for.
 */
TEXT userregcount(SB), 1, $0
	MOVL	$6, AX
	RET
