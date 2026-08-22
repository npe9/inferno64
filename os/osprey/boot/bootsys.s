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
