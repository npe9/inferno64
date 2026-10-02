/*
 * The devices of the x86 platform a guest sees (vmplat.c, vmdev.c):
 * an 8259 pair, a 16550 on IRQ 4, and a local APIC per vCPU.  Each is
 * modelled on the part's datasheet (Intel 8259A, TI/NS 16550A, Intel
 * SDM volume 3 chapter 11), and where this file is less than the part
 * the comment says so.
 */
typedef struct Vpic Vpic;
typedef struct Vpicchip Vpicchip;
typedef struct Vuart Vuart;
typedef struct Vlapic Vlapic;

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

enum {
	Uartfifo	= 16,
	Uartin		= 4096,	/* console input waiting for the FIFO */
};

struct Vuart
{
	uchar	ier, lcr, mcr, lsr, msr, scr, dll, dlm, fcr;
	uchar	thripend;	/* a THRE interrupt is owed until IIR is read */
	uchar	rx[Uartfifo];
	int	rxr, rxw;	/* count of bytes in, out */
	uchar	in[Uartin];	/* typed but not yet in the FIFO */
	int	inr, inw;
	Queue	*out;		/* what the guest wrote, for #H/vm/N/console */
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

/* vmdev.c */
void	vpicreset(Vpic*);
void	vpicsetirq(Vpic*, int irq, int level);
int	vpicpending(Vpic*);
int	vpicack(Vpic*);
int	vpicio(Vpic*, int port, int in, u32int *val);

void	vuartreset(Vuart*);
int	vuartio(Vuart*, int off, int in, u32int *val);
int	vuartirq(Vuart*);
int	vuartinput(Vuart*, uchar*, int);

void	vlapicreset(Vlapic*, int id);
u32int	vlapicread(Vlapic*, int reg);
int	vlapicwrite(Vlapic*, int reg, u32int val);
int	vlapicpending(Vlapic*);
int	vlapicack(Vlapic*);
int	vlapicextint(Vlapic*);
void	vlapictimer(Vlapic*, uvlong now);
void	vlapicsetdeadline(Vlapic*, uvlong tsc, uvlong now);
void	vlapicsetirr(Vlapic*, int vec);
