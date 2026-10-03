/*
 * The RISC-V backend's registers (vmrv.c), by index: x0 to x31, the
 * guest's pc, and the VS-mode CSRs the guest's supervisor sees as its
 * own.  vmplat.c reaches them through vmops, by these.
 */
enum {
	RvZero, RvRa, RvSp, RvGp, RvTp, RvT0, RvT1, RvT2,
	RvS0, RvS1, RvA0, RvA1, RvA2, RvA3, RvA4, RvA5,
	RvA6, RvA7, RvS2, RvS3, RvS4, RvS5, RvS6, RvS7,
	RvS8, RvS9, RvS10, RvS11, RvT3, RvT4, RvT5, RvT6,
	RvPc,
	RvVsstatus, RvVsie, RvVstvec, RvVsscratch, RvVsepc, RvVscause, RvVstval, RvVsatp,
	RvVsiselect,
	RvHvip,
	RvNreg,
};

/* interrupts, as bits of hvip and vsie */
enum {
	RvVssi	= 1<<2,
	RvVsti	= 1<<6,
	RvVsei	= 1<<10,
};

uvlong	rvtime(void);		/* the time CSR the guest reads */
void	rvvgein(Vcpu*, int);	/* the guest interrupt file it runs with (hstatus.VGEIN) */
uvlong	rvgeip(void);		/* hgeip: the guest files with an interrupt for their guest */
