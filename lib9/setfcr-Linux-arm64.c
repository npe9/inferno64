/*
 * Linux ARM64 fpu support.
 * Plan 9 FCR/FSR bits (lib9.h) are translated to AArch64 FPCR/FPSR.
 *
 * This is the same file as setfcr-MacOSX-arm64.c, because FPCR and FPSR
 * are the architecture's registers and not the operating system's.  The
 * two are kept as separate files because lib9/mkfile-Posix names this
 * one setfcr-$SYSTARG-$OBJTYPE.c and there is no third place to put a
 * shared one without changing that rule for every platform.  Change
 * them together.  The one real difference is the signatures: this
 * header declares the four as taking and returning u32 where the Mac's
 * says ulong, and on LP64 those are not the same type.
 *
 * Important: never enable FPCR trap-enable bits (IOE/DZE/…).  The
 * reason was found on Apple Silicon -- they turn benign framework FP
 * ops into SIGILL on host threads that inherit the Inferno thread's
 * FPCR -- and it is kept here because it is not a Darwin rule: a
 * trapping FPCR is inherited by anything the host runs on that thread
 * either way.  Sticky FPSR flags still report status.
 */

#include "lib9.h"

/* AArch64 FPCR */
enum {
	FpcrIOE	= 1<<8,
	FpcrDZE	= 1<<9,
	FpcrOFE	= 1<<10,
	FpcrUFE	= 1<<11,
	FpcrIXE	= 1<<12,
	FpcrRModeShift = 22,
};

/* AArch64 FPSR cumulative exception flags */
enum {
	FpsrIOC	= 1<<0,
	FpsrDZC	= 1<<1,
	FpsrOFC	= 1<<2,
	FpsrUFC	= 1<<3,
	FpsrIXC	= 1<<4,
};

static ulong
readfpcr(void)
{
	ulong v;

	__asm__ volatile("mrs %0, fpcr" : "=r"(v));
	return v;
}

static void
writefpcr(ulong v)
{
	__asm__ volatile("msr fpcr, %0" : : "r"(v));
	__asm__ volatile("isb");
}

static ulong
readfpsr(void)
{
	ulong v;

	__asm__ volatile("mrs %0, fpsr" : "=r"(v));
	return v;
}

static void
writefpsr(ulong v)
{
	__asm__ volatile("msr fpsr, %0" : : "r"(v));
}

u32
getfcr(void)
{
	ulong fpcr;
	u32 fcr;
	ulong rm;

	fpcr = readfpcr();
	fcr = FPPDBL;	/* IEEE double; no x87 precision field on arm64 */
	rm = (fpcr >> FpcrRModeShift) & 3;
	switch(rm) {
	case 0: fcr |= FPRNR; break;
	case 1: fcr |= FPRPINF; break;
	case 2: fcr |= FPRNINF; break;
	case 3: fcr |= FPRZ; break;
	}
	return fcr;
}

void
setfcr(u32 fcr)
{
	ulong fpcr, rm;

	fpcr = readfpcr();
	/* Clear rounding and any trap bits Inferno or a prior set left on. */
	fpcr &= ~((3UL<<FpcrRModeShift) | FpcrIOE | FpcrDZE | FpcrOFE | FpcrUFE | FpcrIXE);

	rm = (fcr & FPRMASK) >> 10;
	/* Plan9: 0=NR, 1=NINF, 2=PINF, 3=Z  →  FPCR: 0=NR, 1=PINF, 2=NINF, 3=Z */
	switch(rm) {
	case 0: break;			/* FPRNR */
	case 1: fpcr |= 2UL<<FpcrRModeShift; break;	/* FPRNINF → RM */
	case 2: fpcr |= 1UL<<FpcrRModeShift; break;	/* FPRPINF → RP */
	case 3: fpcr |= 3UL<<FpcrRModeShift; break;	/* FPRZ */
	}
	/* Intentionally ignore FPINVAL/FPZDIV/… — see file comment. */

	writefpcr(fpcr);
}

u32
getfsr(void)
{
	ulong fpsr;
	u32 fsr;

	fpsr = readfpsr();
	fsr = 0;
	if(fpsr & FpsrIOC) fsr |= FPAINVAL;
	if(fpsr & FpsrDZC) fsr |= FPAZDIV;
	if(fpsr & FpsrOFC) fsr |= FPAOVFL;
	if(fpsr & FpsrUFC) fsr |= FPAUNFL;
	if(fpsr & FpsrIXC) fsr |= FPAINEX;
	return fsr;
}

void
setfsr(u32 fsr)
{
	ulong fpsr;

	/* Replace cumulative exception flags; other FPSR fields left alone */
	fpsr = readfpsr();
	fpsr &= ~(FpsrIOC | FpsrDZC | FpsrOFC | FpsrUFC | FpsrIXC);
	if(fsr & FPAINVAL) fpsr |= FpsrIOC;
	if(fsr & FPAZDIV) fpsr |= FpsrDZC;
	if(fsr & FPAOVFL) fpsr |= FpsrOFC;
	if(fsr & FPAUNFL) fpsr |= FpsrUFC;
	if(fsr & FPAINEX) fpsr |= FpsrIXC;
	writefpsr(fpsr);
}
