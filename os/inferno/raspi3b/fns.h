#include "../port/portfns.h"

void	archconfinit(void);
void	archconsole(void);
void	archreboot(void);
void	archreset(void);
void	pciarchinit(void);
void	clockcheck(void);
void	clockinit(void);
void	clockintr(Ureg*);
void	clockpoll(void);
uvlong	timersoon(void);
uvlong	fastticks(uvlong*);
ulong	tk2ms(ulong);
void	coherence(void);
u32	getctr(void);			/* CTR_EL0, for the cache line sizes */
u32	getclidr(void);			/* CLIDR_EL1 */
u32	getccsidr(void);		/* CCSIDR_EL1 selected by CSSELR_EL1 */
void	setcsselr(u32);
void	dcisw(u32);			/* invalidate D-cache line by set/way */
void	dccvac(uintptr);		/* clean one D-line to PoC */
void	dcivac(uintptr);		/* invalidate one D-line */
void	dccivac(uintptr);		/* clean+invalidate one D-line */
void	cacheiinv(void);		/* invalidate the whole I-cache */
void	cacheinit(void);		/* invalidate reset-state data caches */
void	cacheflush(void*, usize);	/* clean a D-cache range to PoC */
void	cacheflushinv(void*, usize);	/* clean+invalidate a D-cache range */
void	cacheinval(void*, usize);	/* invalidate a D-cache range */
void	delay(int);
void	dumpstack(void);
void	fpinit(void);
int	fpusave(void);
void	fpurestore(int);
ulong	getcallerpc(void*);
ulong	getfcr(void);
ulong	getfsr(void);
char*	getconf(char*);
void	idle(void);
void	idlehands(void);
void	init0entry(void);
void	intrdisable(int, void (*)(Ureg*, void*), void*, int, char*);
void	intrenable(int, void (*)(Ureg*, void*), void*, int, char*);	/* (irq, handler, arg, tbdf, name): the portable order */
int	islo(void);
void	kbdinit(void);
void	screeninit(void);
void	links(void);
void	microdelay(int);
void	mmuinit(void);
void	setfcr(ulong);
void	setfsr(ulong);
void	trap(Ureg*);
void	trapinit(void);
void	vectorinit(void*);
void	gicinit(void);
void	timerie(void);
void	uartconsole(void);
void	uartconsolesetup(void);
void	serialputc(int);
void	serialputs(char*, int);
void	(*screenputs)(char*, int);
ulong	va2pa(void*);

#define procsave(p)
#define procrestore(p)
#define tas(x)		_tas((int*)(x))
#define TK2SEC(t)	((t)/HZ)
#define MS2HZ		(1000/HZ)

#define KADDR(p)	((void*)(uintptr)(p))
#define PADDR(v)	va2pa((void*)(v))

int	cmpswap(s32*, s32, s32);
long	archkprofmicrosecondspertick(void);
void	archkprofenable(int);
int	isaconfig(char*, int, void*);
void	cycles(uvlong*);		/* also in io.h; proc.c includes fns.h, not io.h */

/*
 * PCI on the MMU-off board: physical == virtual, RAM is below 4 GiB
 * so a DMA address is its own physical address, and with no data cache
 * (SCTLR.M=0 makes RAM device memory) there is nothing to flush.  ECAM
 * config space is accessed directly by ../port/pciecam.c, not vmap'd.
 */
#define	vmap(pa, size)		((void*)(uintptr)(pa))
#define	vunmap(va, size)
#define	PCIWADDR(va)		PADDR(va)
#define	dmaflush(clean, addr, len)
extern int	(*pcicfgrw8)(int, int, int, int);
extern int	(*pcicfgrw16)(int, int, int, int);
extern int	(*pcicfgrw32)(int, int, int, int);
uvlong	psci(uvlong, uvlong, uvlong, uvlong);
