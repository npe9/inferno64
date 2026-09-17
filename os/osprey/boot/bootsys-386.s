/*
 * The same stubs for 386, which is the other object type this tree
 * builds.  The convention is the classic Plan 9 one and it is the
 * kernel's own trap entry that names it: os/osprey/pc/trap.c takes the
 * number from AX and the arguments from the user stack at sp+BY2WD, and
 * os/osprey/pc/l.s vectors INT $64 (VectorSYSCALL) to _syscallintr.  So
 * a stub is the number in AX and the interrupt; the arguments are
 * already where the kernel looks for them, which is why there is no
 * counterpart here to the amd64 file's moving the first one.
 */
#define SYSCALL1(name, number) \
	TEXT name(SB), 1, $0; \
	MOVL $number, AX; \
	INT $64; \
	RET

SYSCALL1(bind, 2)
SYSCALL1(exec, 7)
SYSCALL1(_exits, 8)
SYSCALL1(open, 14)
SYSCALL1(rfork, 19)
SYSCALL1(errstr, 41)
SYSCALL1(await, 47)
SYSCALL1(pread, 50)
SYSCALL1(pwrite, 51)
