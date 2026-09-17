/*
 * userregtorture: does a SYSTEM CALL give back every register?
 *
 * regtorture.s asks that question of the interrupt path.  This one asks
 * it of the other entry, and the difference matters here: the interrupt
 * path in os/osprey/pc64/l.s is byte for byte 9front's, while the
 * syscall path is this kernel's own, written to carry two ABIs at once
 * (a Plan 9 program's number in RARG with its arguments on the user
 * stack, and a Linux binary's number in AX with its arguments in
 * registers), so syscallentry stores every register into the Ureg and
 * forkret restores them all.  That is more code doing more saving than
 * upstream does, and it is the code no other test on this branch
 * exercises: a kproc spinning with interrupts on is only ever preempted
 * through _strayintr and never goes near SYSCALL.
 *
 * The loop is a user-mode one because that is the only place a system
 * call can be made from.  It sets eleven registers to distinct values,
 * makes a real system call, and compares them, once per iteration.  The
 * call is pwrite(2, sp, 0, -1) - a write of no bytes to the console -
 * chosen because it is answered by even the cut microkernel, has no
 * effect, and can be made a great many times.
 *
 * Four registers cannot be tested and each for a stated reason.  AX is
 * the system call's return value.  CX and R11 are what SYSCALL puts the
 * user's ip and flags in and what SYSRET consumes, so a program cannot
 * expect them back - the Linux ABI says so in as many words.  BP is
 * RARG, which carries the call number.  That leaves BX, DX, SI, DI, R8,
 * R9, R10, R12, R13, R14 and R15, and the last two are the ones most
 * worth having: syscallentry loads m and up into them, so if any
 * register in this kernel were going to be lost across a call it would
 * be one of those.
 *
 * The system call's arguments go on the stack because that is where the
 * kernel reads them: syscall() in trap.c takes them from ureg->sp+BY2WD,
 * skipping the word a return address would occupy.  They are pushed once
 * before the loop and left there, so the loop body is the call and the
 * comparisons and nothing else.  Two pad words sit above them because
 * MAXSYSARG is 6, so the kernel may read six words as arguments; the
 * caller's pointer for the failed register's value is put above all six
 * where nothing can mistake it for one.
 *
 * Nothing is stored in a global: this program is flat-loaded, one
 * read-only text segment with no data segment of its own (init9.c), so
 * a writable global would not survive the load.  The value a register
 * came back with goes through a pointer the caller supplies, which is
 * on the caller's stack and writable.
 *
 *	long userregtorture(long n, uvlong *badp)
 *
 * Answers 0 if every register survived n system calls, otherwise the
 * register's index, 1 for BX through 11 for R15, with the value it came
 * back as stored through badp.
 *
 * The immediates are all under 2^31: CMPQ with a 64-bit immediate is not
 * encodable.
 */

/*
 * The frame is made with SUBQ rather than with PUSHQ, and declared $-4
 * rather than $64, because 6l counts pushes against pops and a loop that
 * pushes once and returns by adding to SP is unbalanced in its
 * arithmetic even when it is right.  syscallentry in l.s builds its Ureg
 * the same way for the same reason.
 *
 * After the SUBQ:
 *	0(SP)	the counter, in the word the kernel skips
 *	8(SP)	a0, the console
 *	16(SP)	a1, an address the zero-length write can name
 *	24(SP)	a2, no bytes
 *	32(SP)	a3, the offset
 *	40(SP)	pad	)  MAXSYSARG is 6, so the kernel may read six
 *	48(SP)	pad	)  words; nothing it reads is anything but these
 *	56(SP)	badp, above all six where it cannot be mistaken for one
 *	64(SP)	the return address
 *	72(SP)	n, and 80(SP) badp, as the caller passed them
 */
TEXT userregtorture(SB), 1, $-4
	/*
	 * The first argument arrives in RARG, not on the stack.  6c on
	 * amd64 passes it there and gives it a home in the caller's frame
	 * which the caller fills only if it has to spill - which is why
	 * ospreyxcall in xcall.s begins by storing RARG into that home
	 * before it makes its call.  Reading n from the stack instead
	 * read whatever happened to be in the slot, and the loop ran for
	 * a number nobody chose.
	 */
	MOVQ	RARG, AX		/* n */
	MOVQ	16(SP), CX		/* badp, the second argument */

	SUBQ	$64, SP

	MOVQ	AX, 40(SP)		/* how many to make */
	MOVQ	CX, 56(SP)		/* badp */
	MOVQ	$0, AX
	MOVQ	AX, 0(SP)		/* how many have been made */
	MOVQ	AX, 24(SP)		/* a2: no bytes */
	MOVQ	AX, 48(SP)		/* pad */
	MOVQ	$2, AX
	MOVQ	AX, 8(SP)		/* a0: the console */
	LEAQ	64(SP), AX		/* a stack address, valid to name */
	MOVQ	AX, 16(SP)		/* a1 */
	MOVQ	$-1, AX
	MOVQ	AX, 32(SP)		/* a3: the offset */

	MOVQ	$0x21111111, BX
	MOVQ	$0x22222222, DX
	MOVQ	$0x23333333, SI
	MOVQ	$0x24444444, DI
	MOVQ	$0x25555555, R8
	MOVQ	$0x26666666, R9
	MOVQ	$0x27777777, R10
	MOVQ	$0x28888888, R12
	MOVQ	$0x29999999, R13
	MOVQ	$0x2aaaaaaa, R14
	MOVQ	$0x2bbbbbbb, R15

_urloop:
	MOVQ	$51, RARG		/* PWRITE */
	SYSCALL

	CMPQ	BX, $0x21111111
	JNE	_urbad1
	CMPQ	DX, $0x22222222
	JNE	_urbad2
	CMPQ	SI, $0x23333333
	JNE	_urbad3
	CMPQ	DI, $0x24444444
	JNE	_urbad4
	CMPQ	R8, $0x25555555
	JNE	_urbad5
	CMPQ	R9, $0x26666666
	JNE	_urbad6
	CMPQ	R10, $0x27777777
	JNE	_urbad7
	CMPQ	R12, $0x28888888
	JNE	_urbad8
	CMPQ	R13, $0x29999999
	JNE	_urbad9
	CMPQ	R14, $0x2aaaaaaa
	JNE	_urbad10
	CMPQ	R15, $0x2bbbbbbb
	JNE	_urbad11

	MOVQ	0(SP), AX
	ADDQ	$1, AX
	MOVQ	AX, 0(SP)
	CMPQ	AX, 40(SP)
	JNE	_urloop

	/*
	 * How many calls were actually made, through the caller's
	 * pointer.  The caller prints that number rather than the one it
	 * asked for, and the check requires the two to agree - which is
	 * what would have caught the argument being read from the wrong
	 * place, since a loop running a number nobody chose still
	 * finishes and still finds every register intact.
	 */
	MOVQ	56(SP), BX
	MOVQ	0(SP), AX
	MOVQ	AX, 0(BX)

	ADDQ	$64, SP
	MOVQ	$0, AX
	RET

/*
 * Each of these stores what the register came back as through the
 * caller's pointer and answers with the register's number.
 */
_urbad1:
	MOVQ	56(SP), AX
	MOVQ	BX, 0(AX)
	MOVQ	$1, AX
	JMP	_urdone
_urbad2:
	MOVQ	56(SP), AX
	MOVQ	DX, 0(AX)
	MOVQ	$2, AX
	JMP	_urdone
_urbad3:
	MOVQ	56(SP), AX
	MOVQ	SI, 0(AX)
	MOVQ	$3, AX
	JMP	_urdone
_urbad4:
	MOVQ	56(SP), AX
	MOVQ	DI, 0(AX)
	MOVQ	$4, AX
	JMP	_urdone
_urbad5:
	MOVQ	56(SP), AX
	MOVQ	R8, 0(AX)
	MOVQ	$5, AX
	JMP	_urdone
_urbad6:
	MOVQ	56(SP), AX
	MOVQ	R9, 0(AX)
	MOVQ	$6, AX
	JMP	_urdone
_urbad7:
	MOVQ	56(SP), AX
	MOVQ	R10, 0(AX)
	MOVQ	$7, AX
	JMP	_urdone
_urbad8:
	MOVQ	56(SP), AX
	MOVQ	R12, 0(AX)
	MOVQ	$8, AX
	JMP	_urdone
_urbad9:
	MOVQ	56(SP), AX
	MOVQ	R13, 0(AX)
	MOVQ	$9, AX
	JMP	_urdone
_urbad10:
	MOVQ	56(SP), AX
	MOVQ	R14, 0(AX)
	MOVQ	$10, AX
	JMP	_urdone
_urbad11:
	MOVQ	56(SP), AX
	MOVQ	R15, 0(AX)
	MOVQ	$11, AX

_urdone:
	ADDQ	$64, SP
	RET

/*
 * How many registers the loop above compares, so the caller can say so
 * without knowing which object type it was built for.
 */
TEXT userregcount(SB), 1, $0
	MOVQ	$11, AX
	RET
