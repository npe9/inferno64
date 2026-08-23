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
void	intrdisable(int, int, void (*)(Ureg*, void*), void*, char*);
void	intrenable(int, int, void (*)(Ureg*, void*), void*, char*);
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
void	vectorinit(void);
void	mtimerie(void);
void	mextie(void);
void	plicinit(void);
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
void	cycles(uvlong*);
uvlong	rdcycle(void);
long	archkprofmicrosecondspertick(void);
void	archkprofenable(int);
