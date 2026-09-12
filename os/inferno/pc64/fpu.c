#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "ureg.h"
#include "io.h"

enum {
	CR4Osfxsr  = 1 << 9,
	CR4Oxmmex  = 1 << 10,
	CR4Oxsave  = 1 << 18,
};

/*
 * SIMD Floating Point.
 * Assembler support to get at the individual instructions
 * is in l.s.
 */
extern void _clts(void);
extern void _fldcw(u16int);
extern void _fnclex(void);
extern void _fninit(void);
extern void _fxrstor(void*);
extern void _fxsave(void*);
extern void _xrstor(void*);
extern void _xsave(void*);
extern void _xsaveopt(void*);
extern void _fwait(void);
extern void _ldmxcsr(u32);
extern void _stts(void);

static void
fpssesave(FPsave *s)
{
	_fxsave(s);
	_stts();
}
static void
fpsserestore(FPsave *s)
{
	_clts();
	_fxrstor(s);
}

static void
fpxsave(FPsave *s)
{
	_xsave(s);
	_stts();
}
static void
fpxrestore(FPsave *s)
{
	_clts();
	_xrstor(s);
}

static void
fpxsaves(FPsave *s)
{
	_xsaveopt(s);
	_stts();
}
static void
fpxrestores(FPsave *s)
{
	_clts();
	_xrstor(s);
}

static void
fpxsaveopt(FPsave *s)
{
	_xsaveopt(s);
	_stts();
}

static char* mathmsg[] =
{
	nil,	/* handled below */
	"denormalized operand",
	"division by zero",
	"numeric overflow",
	"numeric underflow",
	"precision loss",
};

static void
mathnote(ulong status, uintptr pc)
{
	char *msg, note[ERRMAX];
	int i;

	/*
	 * Some attention should probably be paid here to the
	 * exception masks and error summary.
	 */
	msg = "unknown exception";
	for(i = 1; i <= 5; i++){
		if(!((1<<i) & status))
			continue;
		msg = mathmsg[i];
		break;
	}
	if(status & 0x01){
		if(status & 0x40){
			if(status & 0x200)
				msg = "stack overflow";
			else
				msg = "stack underflow";
		}else
			msg = "invalid operation";
	}
	snprint(note, sizeof note, "sys: fp: %s fppc=%#p status=0x%lux",
		msg, pc, status);
	postnote(up, 1, note, NDebug);
}

/*
 *  math coprocessor error
 */
static void
matherror(Ureg *, void*)
{
	/*
	 * Save FPU state to check out the error.
	 *
	 * _clts() first.  fpsave is fpssesave (or fpxsaves/fpxsaveopt),
	 * every one of which begins with the save instruction itself and
	 * ends with _stts().  Called with TS already set, it faults on
	 * its own first instruction -- reported at _fxsave+0x0, which is
	 * exactly the pc the "math emu pid 1" capture printed, with no
	 * intermediate step needed.
	 *
	 * The window where TS is set while a process is still live is the
	 * ordinary one: fpusave() sets TS and stores FPpush|..., and
	 * os/inferno/port/dis.c holds every Dis program between
	 * fpusave() and fpurestore() around r->xec(r).  A #MF or #XM
	 * delivered in that window lands here.
	 *
	 * Found by the cloud-port session.  os/9front/pc64/fpu.c's
	 * matherror does three things this copy does not: return early
	 * for a trap from kernel mode, guard on fpstate != FPinactive,
	 * and _clts() before fpsave().  The two that cannot change the
	 * state machine are taken here; the kernel-mode early return is
	 * left alone, because this file's design is not 9front's -- that
	 * copy has no fpusave, fpurestore, FPpush, FPnouser, FPkernel or
	 * fpslot at all, and uses m->fpsave and up->kfpsave instead.  So
	 * it is not the upstream of this file and cannot settle what the
	 * third change should be.
	 */
	if(up->fpsave == nil)
		return;
	_clts();
	fpsave(up->fpsave);
	up->fpstate = FPinactive | (up->fpstate & (FPnouser|FPkernel|FPindexm));
	mathnote(up->fpsave->fsw, up->fpsave->rip);
}

/*
 *  SIMD error
 */
static void
simderror(Ureg *ureg, void*)
{
	/* same as matherror(); see its comment */
	if(up->fpsave == nil)
		return;
	_clts();
	fpsave(up->fpsave);
	up->fpstate = FPinactive | (up->fpstate & (FPnouser|FPkernel|FPindexm));
	mathnote(up->fpsave->mxcsr & 0x3f, ureg->pc);
}

void
fpinit(void)
{
	/*
	 * A process tries to use the FPU for the
	 * first time and generates a 'device not available'
	 * exception.
	 * Turn the FPU on and initialise it for use.
	 * Set the precision and mask the exceptions
	 * we don't care about from the generic Mach value.
	 */
	_clts();
	_fninit();
	_fwait();
	_fldcw(0x0232);
	_ldmxcsr(0x1900);
}

/*
 * Whose floating-point state is this?
 *
 * NOT the same question as userureg(), which asks whether a trap frame
 * came from user mode, and this used to call it.
 *
 * Honesty about why this is here.  It was written when correcting
 * userureg() was followed by a "math emu" panic that 880 earlier boots
 * had not shown, and the panic looked like the flip reaching this
 * file.  That reading is superseded: the real fault was kprocchild()
 * starting every kproc's stack inside the Tos, so kexit()'s accounting
 * landed on the interrupt frame (see the comment in trap.c), and the
 * cloud-port session separately established that FPnouser and FPkernel
 * are write-only on this board -- every other test of them masks, and
 * fpuprocfork(), the one unmasked reader, is never called here.
 *
 * So this changes nothing reachable today, and the evidence that
 * prompted it is gone.  It stays because the reasoning below stands on
 * its own and the alternative is a call to userureg() that is right
 * only by coincidence.
 *
 * The flags say why the two questions differ.  dat.h: FPnouser is
 * "fpslot[0] is kernel regs", FPkernel is "fp use in kernel", and the
 * whole scheme "is biased so that FPinit, FPactive and FPinactive
 * without any flags refer to user fp state in fpslot[0]".  So slot 0
 * belongs to the user's floating point.  On this port the user is a
 * Dis program, and a Dis program runs in a kernel process -- there is
 * no other userland.  Its fp state is the user's fp state, whatever
 * privilege the frame was taken at.
 *
 * So this returns what userureg() used to return by accident, and says
 * why it is the right answer here rather than leaving it to look like
 * the bug that was just fixed.
 */
static int
disfp(Ureg *ur)
{
	if(ur == nil || ur->r14 == 0)
		return 0;
	return ((Proc*)(ur->r14))->kp != 0;
}

/*
 *  math coprocessor emulation fault
 */
static void
mathemu(Ureg *ureg, void*)
{
	ulong status, control;
	int index;

	if(up->fpstate & FPillegal){
		/* someone did floating point in a note handler */
		postnote(up, 1, "sys: floating point in note handler", NDebug);
		return;
	}
	switch(up->fpstate & ~(FPnouser|FPkernel|FPindexm)){
	case FPactive	| FPpush:
		_clts();
		fpsave(up->fpsave);
	case FPinactive	| FPpush:
		up->fpstate += FPindex1;
	case FPinit	| FPpush:
	case FPinit:
		fpinit();
		index = up->fpstate >> FPindexs;
		if(index < 0 || index > (FPindexm>>FPindexs))
			panic("fpslot index overflow: %d", index);
		if(disfp(ureg)){
			if(index != 0)
				panic("fpslot index %d != 0 for user", index);
		} else {
			if(index == 0)
				up->fpstate |= FPnouser;
			up->fpstate |= FPkernel;
		}
		while(up->fpslot[index] == nil)
			up->fpslot[index] = mallocalign(sizeof(FPsave), FPalign, 0, 0);
		up->fpsave = up->fpslot[index];
		up->fpstate = FPactive | (up->fpstate & (FPnouser|FPkernel|FPindexm));
		break;
	case FPinactive:
		/*
		 * Before restoring the state, check for any pending
		 * exceptions, there's no way to restore the state without
		 * generating an unmasked exception.
		 * More attention should probably be paid here to the
		 * exception masks and error summary.
		 */
		status = up->fpsave->fsw;
		control = up->fpsave->fcw;
		if((status & ~control) & 0x07F){
			mathnote(status, up->fpsave->rip);
			break;
		}
		fprestore(up->fpsave);
		up->fpstate = FPactive | (up->fpstate & (FPnouser|FPkernel|FPindexm));
		break;
	case FPactive:
		panic("math emu pid %d %s pc %#p", 
			up->pid, up->text, ureg->pc);
		break;
	}
}

/*
 *  math coprocessor segment overrun
 */
static void
mathover(Ureg*, void*)
{
	pexit("math overrun", 0);
}

void
mathinit(void)
{
	trapenable(VectorCERR, matherror, 0, "matherror");
	if(m->cpuidfamily == 3)
		intrenable(IrqIRQ13, matherror, 0, BUSUNKNOWN, "matherror");
	trapenable(VectorCNA, mathemu, 0, "mathemu");
	trapenable(VectorCSO, mathover, 0, "mathover");
	trapenable(VectorSIMD, simderror, 0, "simderror");
}

/*
 * fpuinit(), called from cpuidentify() for each cpu.
 */
void
fpuinit(void)
{
	u64 cr4;
	u32 regs[4];

	cr4 = getcr4() | CR4Osfxsr|CR4Oxmmex;
	if((m->cpuidcx & (Xsave|Avx)) == (Xsave|Avx) && getconf("*noavx") == nil){
		cr4 |= CR4Oxsave;
		putcr4(cr4);
		m->xcr0 = 7; /* x87, sse, avx */
		putxcr0(m->xcr0);
		cpuid(0xd, 1, regs);
		if(regs[0] & Xsaves){
			fpsave = fpxsaves;
			fprestore = fpxrestores;
		} else {
			if(regs[0] & Xsaveopt)
				fpsave = fpxsaveopt;
			else
				fpsave = fpxsave;
			fprestore = fpxrestore;
		}
	} else {
		putcr4(cr4);
		fpsave = fpssesave;
		fprestore = fpsserestore;
	}
}

void
fpuprocsetup(Proc *p)
{
	p->fpstate = FPinit;
	_stts();
}

void
fpuprocfork(Proc *p)
{
	int s;

	/* save floating point state */
	s = splhi();
	switch(up->fpstate & ~FPillegal){
	case FPactive	| FPpush:
		_clts();
	case FPactive:
		fpsave(up->fpsave);
		up->fpstate = FPinactive | (up->fpstate & FPpush);
	case FPactive	| FPkernel:
	case FPinactive	| FPkernel:
	case FPinactive	| FPpush:
	case FPinactive:
		while(p->fpslot[0] == nil)
			p->fpslot[0] = mallocalign(sizeof(FPsave), FPalign, 0, 0);
		memmove(p->fpsave = p->fpslot[0], up->fpslot[0], sizeof(FPsave));
		p->fpstate = FPinactive;
	}
	splx(s);
}

void
fpuprocsave(Proc *p)
{
	switch(p->fpstate & ~(FPnouser|FPkernel|FPindexm)){
	case FPactive	| FPpush:
		_clts();
	case FPactive:
		if(p->state == Moribund){
			_fnclex();
			_stts();
			break;
		}
		/*
		 * Fpsave() stores without handling pending
		 * unmasked exeptions. Postnote() can't be called
		 * so the handling of pending exceptions is delayed
		 * until the process runs again and generates an
		 * emulation fault to activate the FPU.
		 */
		fpsave(p->fpsave);
		p->fpstate = FPinactive | (p->fpstate & ~FPactive);
		break;
	}
}

void
fpuprocrestore(Proc*)
{
}


/*
 * Fpusave and fpurestore lazily save and restore FPU state across
 * system calls and the pagefault handler so that we can take
 * advantage of SSE instructions such as AES-NI in the kernel.
 */
int
fpusave(void)
{
	int ostate = up->fpstate;
	if((ostate & ~(FPnouser|FPkernel|FPindexm)) == FPactive)
		_stts();
	up->fpstate = FPpush | (ostate & ~FPillegal);
	return ostate;
}
void
fpurestore(int ostate)
{
	int astate = up->fpstate;
	if(astate == (FPpush | (ostate & ~FPillegal))){
		if((ostate & ~(FPnouser|FPkernel|FPindexm)) == FPactive)
			_clts();
	} else {
		/*
		 * Masked, like every other test of fpstate in this file.
		 * This was a bare == against FPinit, the state value 0, so a
		 * process carrying FPnouser, FPkernel or a non-zero FPindex
		 * never matched and fell through instead of returning.
		 *
		 * Hygiene, and no more than that.  I first claimed this
		 * explained the "math emu ... pc _fxsave+0x0" capture, and
		 * it does not: falling through reaches the demotion three
		 * lines down, "if(ostate & FPactive) ostate = FPinactive |
		 * ...", so the store below cannot leave fpstate saying
		 * active.  The cloud-port session asked whether this copy
		 * had that line.  It does, and that kills the mechanism.
		 * The capture is matherror()/simderror() calling fpsave()
		 * with TS set -- see the comment there.
		 */
		if((astate & ~(FPnouser|FPkernel|FPindexm)) == FPinit)
			return;		/* procexec()/procsetup() */
		if((astate & ~(FPnouser|FPkernel|FPindexm)) == FPactive)
			_stts();
		up->fpsave = up->fpslot[ostate>>FPindexs];
		if(ostate & FPactive)
			ostate = FPinactive | (ostate & ~FPactive);
	}
	up->fpstate = ostate;
}
