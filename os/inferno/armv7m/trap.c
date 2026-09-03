#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"
#include "armv7m.h"

/*
 * ARMv7-M exceptions.  There is one entry point, os/inferno/armv7m/l.s's
 * _trapentry, because the core tells the handler which exception it is
 * taking in IPSR; l.s puts that number in Ureg.type and everything is
 * dispatched from here.  A vector table of identical entries is cheaper
 * than a table of stubs and makes the numbering obvious.
 */

static void	(*irqhandler[NIRQ])(Ureg*, void*);
static void	*irqarg[NIRQ];

extern char	etext[];

static char *excname[16] = {
	"thread",
	"reset",
	"non-maskable interrupt",
	"hard fault",
	"memory management fault",
	"bus fault",
	"usage fault",
	"exception 7",
	"exception 8",
	"exception 9",
	"exception 10",
	"supervisor call",
	"debug monitor",
	"exception 13",
	"pendsv",
	"systick",
};

void
intrenable(int v, void (*f)(Ureg*, void*), void *a, int tbdf, char *name)
{
	ulong *iser, *ipr;

	USED(tbdf, name);
	if(v < 0 || v >= NIRQ)
		panic("intrenable: irq %d", v);
	irqhandler[v] = f;
	irqarg[v] = a;
	/*
	 * One priority for everything.  splhi is PRIMASK, which masks
	 * every configurable priority at once, so priorities would buy
	 * nothing until this kernel has a reason to nest interrupts.
	 */
	ipr = (ulong*)NVIC_IPR;
	ipr[v/4] = (ipr[v/4] & ~(0xffUL << (8*(v%4)))) | (0x80UL << (8*(v%4)));
	iser = (ulong*)NVIC_ISER;
	iser[v/32] = 1UL << (v%32);
	coherence();
}

void
intrdisable(int v, void (*f)(Ureg*, void*), void *a, int tbdf, char *name)
{
	ulong *icer;

	USED(tbdf, f, a, name);
	if(v < 0 || v >= NIRQ)
		return;
	icer = (ulong*)NVIC_ICER;
	icer[v/32] = 1UL << (v%32);
	coherence();
	irqhandler[v] = nil;
	irqarg[v] = nil;
}

void
trapinit(void)
{
	ulong *shcsr;

	/*
	 * Ask for the three configurable faults by name.  Without this
	 * every one of them escalates to a hard fault and the fault
	 * status registers say much less about what happened.
	 */
	shcsr = (ulong*)SCB_SHCSR;
	*shcsr |= ShcsrMemfault|ShcsrBusfault|ShcsrUsgfault;
	coherence();
}

static void
faultreport(Ureg *ur)
{
	ulong type;

	type = ur->type & 0x1ff;
	print("%s", type < nelem(excname)? excname[type]: "interrupt");
	print(" pc ");
	print("%.8lux", (ulong)ur->pc);
	print(" psr ");
	print("%.8lux\n", (ulong)ur->psr);
	print("  cfsr ");
	print("%.8lux", *(ulong*)SCB_CFSR);
	print(" hfsr ");
	print("%.8lux", *(ulong*)SCB_HFSR);
	print(" mmfar ");
	print("%.8lux", *(ulong*)SCB_MMFAR);
	print(" bfar ");
	print("%.8lux\n", *(ulong*)SCB_BFAR);
	print("  r0 ");
	print("%.8lux", (ulong)ur->r0);
	print(" r1 ");
	print("%.8lux", (ulong)ur->r1);
	print(" r2 ");
	print("%.8lux", (ulong)ur->r2);
	print(" r3 ");
	print("%.8lux\n", (ulong)ur->r3);
	print("  r12 ");
	print("%.8lux", (ulong)ur->r12);
	print(" sp ");
	print("%.8lux", (ulong)ur->sp);
	print(" lr ");
	print("%.8lux\n", (ulong)ur->r14);
	if(up != nil){
		print("  up ");
		print("%.8lux ", (ulong)up);
		print("%s\n", up->text);
	}
}

void
trap(Ureg *ur)
{
	ulong type;
	int irq;
	void (*f)(Ureg*, void*);

	type = ur->type & 0x1ff;
	if(type >= Excirq){
		irq = type - Excirq;
		if(irq < NIRQ && (f = irqhandler[irq]) != nil){
			f(ur, irqarg[irq]);
			return;
		}
		print("unhandled interrupt ");
		print("%lud\n", (ulong)irq);
		intrdisable(irq, nil, nil, 0, nil);
		return;
	}
	switch((int)type){
	case Excsystick:
		clockintr(ur);
		return;
	case Excsvc:
	case Excpendsv:
		/*
		 * Nothing asks for either yet: there is no user mode to
		 * cross and the scheduler switches with gotolabel.
		 */
		return;
	}
	faultreport(ur);
	dumpstack();
	panic("exception");
}

void
dumpstack(void)
{
	uintptr l, v, estack;
	int n;

	print("dumpstack\n");
	l = (uintptr)&l;
	if(up != nil
	&& l >= (uintptr)up->kstack
	&& l < (uintptr)up->kstack+KSTACK)
		estack = (uintptr)up->kstack+KSTACK;
	else
		estack = l + 64*sizeof(uintptr);
	n = 0;
	for(; l < estack; l += sizeof(uintptr)){
		v = *(uintptr*)l;
		if(v > (uintptr)KTZERO && v < (uintptr)etext){
			print("%.8lux\n", (ulong)v);
			if(++n >= 32)
				break;
		}
	}
}
