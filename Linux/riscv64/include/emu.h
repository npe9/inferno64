/*
 * system- and machine-specific declarations for emu:
 * floating-point save and restore, signal handling primitive, and
 * implementation of the current-process variable `up'.
 */

typedef struct FPU FPU;
struct FPU
{
	uchar	env[32];
};

#define KSTACK (32 * 1024)

extern	Proc*	getup(void);

#define	up	(getup())

typedef sigjmp_buf osjmpbuf;
#define	ossetjmp(buf)	sigsetjmp(buf, 1)
