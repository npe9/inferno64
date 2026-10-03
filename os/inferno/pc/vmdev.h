/*
 * The devices of the x86 platform a guest sees (vmplat.c, vmdev.c):
 * an 8259 pair, a 16550 on IRQ 4, and a local APIC per vCPU.  Each is
 * modelled on the part's datasheet (Intel 8259A, TI/NS 16550A, Intel
 * SDM volume 3 chapter 11), and where this file is less than the part
 * the comment says so.
 */
#include	"../port/vuart.h"

typedef struct Vpic Vpic;
typedef struct Vpicchip Vpicchip;
typedef struct Vioapic Vioapic;
typedef struct Vlapic Vlapic;
typedef struct Vpit Vpit;
typedef struct Vpitch Vpitch;

struct Vpicchip
{
	uchar	irr;
	uchar	imr;
	uchar	isr;
	uchar	base;		/* vector of IRQ 0, from ICW2 */
	uchar	elcr;		/* level-triggered lines */
	uchar	level;		/* the input lines as they are now */
	uchar	icw;		/* next initialisation word expected, 0 if none */
	uchar	icw4;		/* ICW1 said an ICW4 follows */
	uchar	single;		/* ICW1 said no cascade */
	uchar	autoeoi;
	uchar	readisr;	/* OCW3: reads of the command port give ISR */
	uchar	poll;		/* OCW3 poll command pending */
};

struct Vpic
{
	Vpicchip c[2];		/* master at 0x20, slave at 0xA0 on IRQ 2 */
};

/*
 * 8254: three channels counting a 1.193182 MHz input, computed from
 * the host TSC rather than ticked.  Channel 0's output is IRQ 0;
 * channel 2's gate and output are port 0x61's bits 0 and 5.
 */
struct Vpitch
{
	int	mode;		/* 0-5 */
	int	rw;		/* 1 LSB, 2 MSB, 3 LSB then MSB */
	int	reload;		/* the count written; 0 means 65536 */
	int	writehi;	/* the next write is the MSB of an rw 3 count */
	int	readhi;		/* the next read is the MSB */
	int	latched;	/* a count is latched */
	int	latch;
	int	statlatched;	/* a status byte is latched (read-back) */
	int	status;
	int	gate;
	int	armed;		/* counting: a count has been written */
	int	nullcount;
	uvlong	start;		/* host TSC at which the count was loaded */
	uvlong	fire;		/* host TSC of the next output edge to raise, 0 if none */
};

struct Vpit
{
	Vpitch	ch[3];
	uvlong	tschz;
	int	spk;		/* port 0x61 bits 0-3 */
	int	refresh;	/* port 0x61 bit 4, toggled on each read */
};

struct Vlapic
{
	int	id;
	uvlong	base;		/* IA32_APIC_BASE */
	u32int	tpr;
	u32int	svr;
	u32int	ldr;
	u32int	dfr;
	u32int	esr;
	u32int	icrlo, icrhi;
	u32int	lvt[7];		/* timer, thermal, perf, lint0, lint1, error, cmci */
	u32int	tmict;
	u32int	tdcr;
	u32int	irr[8], isr[8], tmr[8];
	uvlong	tscdeadline;	/* IA32_TSC_DEADLINE as the guest wrote it */
	uvlong	fire;		/* host TSC at which the timer next fires; 0 if none */
	uvlong	start;		/* host TSC at which tmict was loaded */
};

enum {
	/* Vlapic.lvt */
	LvtTimer, LvtThermal, LvtPerf, LvtLint0, LvtLint1, LvtError, LvtCmci,

	Apicbase	= 0xFEE00000,
	ApicEnable	= 1<<11,
	ApicX2		= 1<<10,
	ApicBsp		= 1<<8,
};

enum {
	Nioapic		= 24,		/* redirection entries */
	Ioapicbase	= 0xFEC00000,
	Ioapicid	= 8,		/* after the vCPUs' APIC ids */
};

struct Vioapic
{
	u32int	sel;		/* IOREGSEL */
	uvlong	rte[Nioapic];
	uchar	level[Nioapic];	/* the input lines as they are now */
};

/* vmdev.c */
void	vpitreset(Vpit*, uvlong tschz);
int	vpitio(Vpit*, int port, int in, u32int *val, uvlong now);
int	vpittimer(Vpit*, uvlong now);
uvlong	vpitnext(Vpit*);
void	vpicreset(Vpic*);
void	vpicsetirq(Vpic*, int irq, int level);
int	vpicpending(Vpic*);
int	vpicack(Vpic*);
int	vpicio(Vpic*, int port, int in, u32int *val);


void	vlapicreset(Vlapic*, int id);
u32int	vlapicread(Vlapic*, int reg);
int	vlapicwrite(Vlapic*, int reg, u32int val);
int	vlapicpending(Vlapic*);
int	vlapicack(Vlapic*);
int	vlapicextint(Vlapic*);
void	vlapictimer(Vlapic*, uvlong now);
void	vlapicsetdeadline(Vlapic*, uvlong tsc, uvlong now);
void	vlapicsetirr(Vlapic*, int vec);
int	vlapicmatch(Vlapic*, u32int dest, int logical);

void	vioapicreset(Vioapic*);
u32int	vioapicread(Vioapic*, int off);
void	vioapicwrite(Vioapic*, int off, u32int val);
int	vioapicset(Vioapic*, int pin, int level, uvlong *rte);
