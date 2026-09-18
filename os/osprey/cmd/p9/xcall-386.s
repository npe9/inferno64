/*
 * The personality's own machine layer for 386: the same six routines
 * os/osprey/cmd/p9/xcall-amd64.s has, in this object type's
 * instructions and calling convention.
 *
 * The convention is the one this kernel's trap entry names, and it is
 * simpler here than on amd64: os/osprey/pc/trap.c takes the call number
 * from AX and the arguments from the user stack at sp+BY2WD, so a stub
 * is the number and the interrupt, with nothing to move.  The amd64
 * file begins each stub by putting its first argument back on the
 * stack, because 6c passes that one in a register; 8c passes every
 * argument on the stack already.
 */

/*
 * The system call a task makes its own requests with - reserve, tick -
 * number 60, above the Plan 9 table, which an unmodified Plan 9 binary
 * uses whole (its read is pread, 50).
 */
TEXT	ospreyxcall(SB), 1, $0
	MOVL	$60, AX
	INT	$64
	RET

/*
 * Cooperative context switch for the personality's kprocs, the classic
 * Plan 9 pair: setlabel saves SP and the return PC and returns 0;
 * gotolabel restores them and returns 1, so a gotolabel to a saved
 * label resumes as if the setlabel there had just returned 1.  Only SP
 * and PC need saving - the callee-saved registers live in the stack
 * frames each side returns back through, and on 386 there are none
 * reserved besides.
 *
 * A Label is two uintptrs (nsdat.h), which is eight bytes here and
 * sixteen on amd64: the second word is at 4(AX), not 8(RARG).
 */
TEXT setlabel(SB), 1, $0
	MOVL	l+0(FP), AX
	MOVL	SP, 0(AX)			/* store SP */
	MOVL	0(SP), BX			/* store return PC */
	MOVL	BX, 4(AX)
	MOVL	$0, AX				/* return 0 */
	RET

TEXT gotolabel(SB), 1, $0
	MOVL	l+0(FP), AX
	MOVL	0(AX), SP			/* restore SP */
	MOVL	4(AX), BX			/* put return PC on the stack */
	MOVL	BX, 0(SP)
	MOVL	$1, AX				/* return 1 */
	RET

/*
 * A user-mode port read, to prove the TSS I/O-permission bitmap: at
 * CPL3 this INB faults unless the kernel has cleared the port's bit in
 * the bitmap.  Same shape as the kernel's own inb - the port in DX, the
 * byte back in AX - and this is the routine that would exercise
 * iogrant on this object type, which nothing does yet.
 */
TEXT	ospreyinb(SB), 1, $0
	MOVL	port+0(FP), DX
	XORL	AX, AX
	INB
	RET

/*
 * A user-mode port write, the write half of the i8042 driver: at CPL3
 * this OUTB faults unless the kernel has granted the port.
 */
TEXT	ospreyoutb(SB), 1, $0
	MOVL	port+0(FP), DX
	MOVL	byte+4(FP), AX
	OUTB
	RET

/*
 * The cycle counter, for a program measuring the ring: the same RDTSC
 * the kernel's _cycles reads, low word then high at the address given.
 *
 * Written as its bytes because this assembler does not know the
 * mnemonic - os/osprey/pc/l.s says the same thing the same way, and
 * 6a, which the amd64 file uses, does know it.
 */
#define RDTSC		BYTE $0x0F; BYTE $0x31	/* result in AX/DX (lo/hi) */

TEXT	ospreycycles(SB), 1, $0
	MOVL	p+0(FP), BX
	RDTSC
	MOVL	AX, 0(BX)
	MOVL	DX, 4(BX)
	RET
