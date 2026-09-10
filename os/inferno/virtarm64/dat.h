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
	ulong	splpc;

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
	uintptr	gicr;			/* this cpu's GICv3 redistributor RD_base */
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

/*
 * MACHP(n) was a macro that ignored n and returned the one Mach there
 * was.  It is an array now, filled by machinit() for machno 0 and by
 * startcpus() for each processor it starts, and nil for a slot no
 * processor occupies.  Every MACHP() in the portable code that walks
 * to MAXMACH is guarded by active.machs[], which is why nil is safe:
 * see the comment in startcpus() about why a parked processor does
 * not set it.
 */
#define	MACHP(n)	(machp[n])

extern Mach mach0;
extern Mach *machp[MAXMACH];

/*
 * m and up are registers rather than globals, which is what makes them
 * per-processor at all: on a machine with more than one processor
 * every one of them needs its own "which Mach am I" and "which Proc am
 * I running", and a global has exactly one of each.  7c reserves R27
 * and R26 for this (REGEXT and REGEXT-1 in utils/7c/7.out.h) and never
 * allocates them for anything else, in any translation unit, whether
 * or not it has seen this declaration -- so libinterp, libsec and the
 * rest, none of which include this header, are unaffected.
 *
 * The order of these two lines is the register assignment: 7c's
 * exreg() hands out registers counting down from REGEXT, so the first
 * extern register it sees gets R27.  m must stay first, and nothing
 * earlier on the include path may declare another one, or m would be
 * R27 in one file and R26 in another with nothing to say so.
 *
 * l.s must keep them: _main loads R27 before calling main(), and the
 * trap path saves and restores both as UR_R27 and UR_R26.
 */
extern register Mach* m;			/* R27 */
extern register Proc* up;			/* R26 */
