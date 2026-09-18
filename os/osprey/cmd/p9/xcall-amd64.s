/*
 * The system call a task makes its own requests with - reserve, tick -
 * number 60, above the Plan 9 table, which an unmodified Plan 9 binary
 * uses whole (its read is pread, 50).  The stub is the shape libc's
 * are: the first argument back on the stack, the number in RARG.
 */
TEXT	ospreyxcall(SB), 1, $0
	MOVQ	RARG, a0+0(FP)
	MOVQ	$60, RARG
	SYSCALL
	RET

/*
 * Cooperative context switch for the personality's kprocs, the classic
 * Plan 9 pair: setlabel saves SP and the return PC and returns 0;
 * gotolabel restores them and returns 1, so a gotolabel to a saved label
 * resumes as if the setlabel there had just returned 1.  Only SP and PC
 * need saving - the callee-saved registers live in the stack frames each
 * side returns back through.
 */
TEXT setlabel(SB), 1, $-4
	MOVQ	SP, 0(RARG)			/* store SP */
	MOVQ	0(SP), BX			/* store return PC */
	MOVQ	BX, 8(RARG)
	MOVL	$0, AX				/* return 0 */
	RET

TEXT gotolabel(SB), 1, $-4
	MOVQ	0(RARG), SP			/* restore SP */
	MOVQ	8(RARG), AX			/* put return PC on the stack */
	MOVQ	AX, 0(SP)
	MOVL	$1, AX				/* return 1 */
	RET

/*
 * A user-mode port read, to prove the TSS I/O-permission bitmap: at CPL3
 * this INB faults unless the kernel has cleared the port's bit in the
 * bitmap.  Same shape as the kernel's own inb - the port in RARG, the
 * byte back in AX.
 */
TEXT	ospreyinb(SB), 1, $-4
	MOVL	RARG, DX
	XORL	AX, AX
	INB
	RET

/*
 * A user-mode port write, the write half of the i8042 driver: at CPL3
 * this OUTB faults unless the kernel has granted the port.  Same shape as
 * the kernel's own outb - port in RARG, byte the second argument.
 */
TEXT	ospreyoutb(SB), 1, $-4
	MOVL	RARG, DX
	MOVL	byte+8(FP), AX
	OUTB
	RET

/*
 * The cycle counter, for a program measuring the ring: the same RDTSC
 * the kernel's _cycles reads, low word then high at the address given.
 */
TEXT	ospreycycles(SB), 1, $-4
	RDTSC
	MOVL	AX, 0(RARG)
	MOVL	DX, 4(RARG)
	RET
