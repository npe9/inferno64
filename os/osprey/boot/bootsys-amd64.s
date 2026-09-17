/*
 * The system-call stubs the boot programs use, amd64.  This was
 * bootsys.s, named unconditionally, and it is written in MOVQ and RARG
 * - the number goes in the first argument register and the first
 * argument moves to the stack - so nothing else could use it.  The
 * mkfile picks by OBJTYPE now, the way os/osprey/kernlib picks
 * getcallerpc.
 */
#define SYSCALL1(name, number) \
	TEXT name(SB), 1, $0; \
	MOVQ RARG, a0+0(FP); \
	MOVQ $number, RARG; \
	SYSCALL; \
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
