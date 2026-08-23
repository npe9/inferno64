#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"

enum {
	IrqTimer	= 7,
};

extern char	etext[];

void
plicinit(void)
{
	/* spike has no PLIC */
}

void
trapinit(void)
{
	vectorinit();
}

void
trap(Ureg *ur)
{
	uintptr cause, code;

	cause = ur->cause;
	if((vlong)cause < 0){
		code = cause & ~((uintptr)1 << 63);
		if((int)code == IrqTimer){
			clockintr(ur);
			return;
		}
		print("interrupt cause ");
		print("%#p\n", cause);
		panic("interrupt");
	}
	print("exception cause ");
	print("%#p", cause);
	print(" epc ");
	print("%#p\n", ur->pc);
	dumpstack();
	panic("exception");
}

void
intrenable(int v, int tbdf, void (*f)(Ureg*, void*), void *a, char *name)
{
	USED(v, tbdf, f, a, name);
}

void
intrdisable(int v, int tbdf, void (*f)(Ureg*, void*), void *a, char *name)
{
	USED(v, tbdf, f, a, name);
}

void
dumpstack(void)
{
	print("dumpstack\n");
}
