typedef struct Conf	Conf;
typedef struct Confmem	Confmem;
typedef struct FPU	FPU;
typedef struct FPenv	FPenv;
typedef struct Label	Label;
typedef struct Lock	Lock;
typedef struct Mach	Mach;
typedef struct Proc	Proc;
typedef struct Ureg	Ureg;
typedef struct ISAConf	ISAConf;
typedef struct PFPU	PFPU;
typedef struct PMMU	PMMU;

typedef ulong Instr;
typedef s64	Tval;

struct Confmem
{
	uintptr	base;
	uintptr	npage;
};

#define NISAOPT 8
struct Conf
{
	ulong	nmach;
	ulong	nproc;
	ulong	npage0;
	ulong	npage1;
	uintptr	topofmem;
	ulong	npage;
	uintptr	base0;
	uintptr	base1;
	ulong	ialloc;
	ulong	cpuspeed;
	ulong	monitor;
	uintptr	pipeqsize;	/* size in bytes of pipe queues */
	Confmem	mem[16];
};

struct ISAConf {
	char	*type;		/* pointer — matches port/devether.c */
	ulong	port;
	ulong	irq;
	ulong	dma;
	ulong	mem;
	ulong	size;
	ulong	freq;
	int	nopt;
	char	*opt[NISAOPT];
};

enum
{
	FPinit = 0,
	FPINIT = FPinit,
	FPactive = 1,
	FPACTIVE = FPactive,
	FPinactive = 2,
	FPINACTIVE = FPinactive,
	FPillegal = 1<<8,
};

struct	FPenv
{
	ulong	status;
	ulong	control;
};

struct	FPU
{
	FPenv	env;
};

struct Label
{
	uintptr	sp;	/* must match XLEN in l.s (8 on arm64) */
	uintptr	pc;
};

struct Lock
{
	ulong	key;
	ulong	sr;
	ulong	pc;
	int	pri;
	u32	priority;
	u16	isilock;
	Mach	*m;
	Proc	*p;
};

struct PFPU
{
	int	fpstate;
	FPU	*fpsave;
};

#define NCOLOR 1
struct PMMU
{
	int	dummy;
};

#include "../port/portdat.h"

/*
 * Hardware config blob used by #S (devsd).  Full type required once sd is in.
 */
typedef struct {
	u32	port;
	s32	size;
} Devport;

struct DevConf
{
	u32	intnum;
	char	*type;
	s32	nports;
	Devport	*ports;
};

struct Mach
{
	/* OFFSETS OF THE FOLLOWING KNOWN BY l.s */
	uintptr	splpc;	/* 8 bytes: l.s stores R30 here with a 64-bit MOV */

	int	machno;
	Proc	*proc;

	Proc*	readied;
	Label	sched;
	ulong	ticks;
	ulong	schedticks;
	int	pfault;
	int	cs;
	int	syscall;
	int	load;
	int	intr;
	int	ilockdepth;
	int	flushmmu;
	int	tlbfault;
	int	tlbpurge;
	Perf	perf;
	uvlong	cyclefreq;

	Lock	alarmlock;
	void	*alarm;
	ulong	cpuhz;
	ulong	delayloop;

	int	stack[1];
};

struct
{
	Lock;
	char	machs[MAXMACH];
	s32	exiting;
	s32	ispanic;
	s32	thunderbirdsarego;
}active;

#define	MACHP(n)	((Mach*)(void*)&mach0)

extern Mach mach0;
/*
 * m, up and curP are machine registers (R27/R26/R25), not memory, and
 * they come from include/disreg.h so that this kernel and libinterp
 * agree on which register is which: kencc assigns external registers
 * per file in declaration order, and libinterp for aarch64 is built
 * with DISCTXREG, so every aarch64 board has to declare the same three
 * in the same order or its link has no definition for libinterp's curP.
 * This board has one processor; the registers are here for the link and
 * for the Dis context, not for SMP.  l.s's boot1 sets m and up before
 * any C runs, and vectrap already saves and restores R25-R27 in the
 * Ureg like every other general register.
 */
#include	"../../../include/disreg.h"
