#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"

#include "mp.h"

#define DP	if(1){}else print

extern void _stts(void);
extern uintptr ilockwatchpc;
extern int ilockwatchhits;

/*
 * Point this processor's first debug register at cpu0's m->ilockdepth
 * and ask for a trap on any write to it.
 *
 * The question this answers is the one the counters cannot: cpu0's
 * ilockdepth changes under cpu0 while cpu0 has interrupts off, the
 * words around it in Mach stay sane, so it is a single stray store and
 * not a memset -- but nothing so far says which processor makes it.
 * This processor has no business writing cpu0's Mach at all, so any
 * trap here is the bug, and trap.c dumps the registers and panics with
 * the pc in them.  Equally, silence is a real answer: it means the
 * store comes from cpu0 itself.
 *
 * Off unless *ilockwatch is set in plan9.ini, and DR0-3 are otherwise
 * a per-process resource (main.c reloads them from p->dr), so this is
 * for a kernel booted to be watched, not for a shipped one.
 *
 * DR7: L0 enables DR0 for this processor, LE is the recommended exact
 * -match bit, R/W0 = 01 is "break on data write", LEN0 = 11 is four
 * bytes.  DR0 must be set before DR7 enables it, so putdr01236 (which
 * does not touch DR7) comes first.
 */
void
ilockwatch(void)
{
	static u64 dr[8];

	if(getconf("*ilockwatch") == nil)
		return;
	dr[0] = (u64)(uintptr)&MACHP(0)->ilockdepth;
	putdr01236(dr);
	putdr7(1 | (1<<8) | ((u64)1<<16) | ((u64)3<<18));
	print("cpu%d: watching %#p (cpu0 m->ilockdepth) for writes\n",
		m->machno, (void*)(uintptr)dr[0]);
	/*
	 * The positive control.  Silence from a watchpoint reads exactly
	 * like a watchpoint that was never armed, and this tree has
	 * already published one conclusion drawn from an instrument that
	 * could not have shown the thing either way.  With
	 * *ilockwatch=test this processor writes the watched word itself,
	 * on purpose, and the kernel is expected to die on the spot with
	 * a debug exception.  A boot that survives it means the trap does
	 * not work and no silence from it means anything.
	 */
	if(strcmp(getconf("*ilockwatch"), "test") == 0){
		print("cpu%d: control write to %#p, expect a trap\n",
			m->machno, (void*)(uintptr)dr[0]);
		MACHP(0)->ilockdepth += 0;
		if(ilockwatchhits == 0)
			print("cpu%d: CONTROL FAILED, the write did not trap\n",
				m->machno);
		else
			print("cpu%d: CONTROL OK, %d hit(s), writer pc %#p\n",
				m->machno, ilockwatchhits, (void*)ilockwatchpc);
	}
}

static void
squidboy(Apic* apic)
{
	machinit();
	mmuinit();
	cpuidentify();
	if(arch->clockinit)
		arch->clockinit();
	cpuidprint();
	syncclock();
	print("cpu%d: squidboy m %#p, MACHP(0) %#p, MACHP(1) %#p\n",
		m->machno, m, MACHP(0), MACHP(1));
	active.machs[m->machno] = 1;
	ilockwatch();
	apic->online = 1;
	lapicinit(apic);
	lapiconline();
	timersinit();
	_stts();
	schedinit();
}

void
mpstartap(Apic* apic)
{
	uintptr *apbootp, *pml4/*, *pdp0*/;
	Segdesc *gdt;
	Mach *mach;
	uchar *p /*, *q */;
	int i;

	DP("mpstartap apic->machno %d: \n", apic->machno);
	/*
	 * Initialise the AP page-tables and Mach structure.
	 * Xspanalloc will panic if an allocation can't be made.
	 */
	p = xspanalloc(1*PTSZ + BY2PG + MACHSIZE, BY2PG, 0);
	pml4 = (uintptr*)p;
	p += PTSZ;
	/* pdp0 = (uintptr*)p;
	p += PTSZ; */
	gdt = (Segdesc*)p;
	p += BY2PG;
	mach = (Mach*)p;

	memset(pml4, 0, PTSZ);
	/*memset(pdp0, 0, PTSZ);*/
	memset(gdt, 0, BY2PG);
	memset(mach, 0, MACHSIZE);

	mach->machno = apic->machno;
	mach->pml4 = pml4;
	mach->gdt  = gdt;	/* filled by mmuinit */
	MACHP(mach->machno) = mach;

	/*
	 * share the page tables across all processors except for pml4
	 * they should be static at this point
	 */
	for(i=0; i<BY2PG/8; i+=8){
		pml4[i] = MACHP(0)->pml4[i];
		if(pml4[i] != 0)
			DP("mpstartap i %d pml4[i] 0x%p MACHP(0)->pml4[i] 0x%p\n",
				i, pml4[i], MACHP(0)->pml4[i]);
	}

	/*
	 * Tell the AP where its kernel vector and pdb are.
	 * The offsets are known in the AP bootstrap code.
	 */
	apbootp = (uintptr*)(APBOOTSTRAP+0x08);
	apbootp[0] = (uintptr)squidboy;	/* assembler jumps here eventually */
	apbootp[1] = (uintptr)PADDR(pml4);
	apbootp[2] = (uintptr)apic;
	apbootp[3] = (uintptr)mach;
	apbootp[4] |= (uintptr)m->havenx<<11;	/* EFER */
	/*
	for(i=0;i<80;i++){
		print(" %x", *((uchar*)APBOOTSTRAP+i));
	}
	print("\n");
	*/

	/*
	 * Universal Startup Algorithm.
	 */
	p = KADDR(0x467);		/* warm-reset vector */
	*p++ = PADDR(APBOOTSTRAP);
	*p++ = PADDR(APBOOTSTRAP)>>8;
	i = (PADDR(APBOOTSTRAP) & ~0xFFFF)/16;
	/* code assumes i==0 */
	if(i != 0)
		print("mp: bad APBOOTSTRAP i 0x%ux\n", i);
	*p++ = i;
	*p = i>>8;
	/*
	print("p 0x%p PADDR(APBOOTSTRAP) 0x%p (PADDR(APBOOTSTRAP) & ~0xFFFF)/16 0x%p\n",
			p, PADDR(APBOOTSTRAP), (PADDR(APBOOTSTRAP) & ~0xFFFF)/16);
	for(q = (uchar*)KADDR(0x467); q<=p; q++){
		print("	q 0x%p *q 0x%x",q, *q);
	}
	print("\n");
	*/
	coherence();

	nvramwrite(0x0F, 0x0A);	/* shutdown code: warm reset upon init ipi */
	lapicstartap(apic, PADDR(APBOOTSTRAP));
	for(i = 0; i < 100000; i++){
		if(arch->fastclock == tscticks)
			cycles(&m->tscticks);	/* for ap's syncclock(); */
		if(apic->online){
			break;
		}
		delay(1);
	}
	nvramwrite(0x0F, 0x00);
}
