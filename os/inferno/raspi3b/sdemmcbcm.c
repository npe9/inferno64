/*
 * Arasan SDHCI controller ("EMMC", 0x3f300000) as an Inferno storage
 * device on the Raspberry Pi 3.  The SD card can be wired either to the
 * BCM2835's own SDHOST controller (sdhostbcm.c) or to this one; GPIO
 * 48-53 in alt3 selects this one, and QEMU's raspi3b models the same
 * routing.
 *
 * This is a standard SD host controller, unlike SDHOST: block size and
 * count, argument and command in registers, the response in RESP0..3,
 * and the data through a 32-bit buffer register paced by the READ_RDY /
 * WRITE_RDY interrupt-status bits.  Everything here is polled; the
 * kernel has no use for a transfer interrupt while it has nothing else
 * to do, and polling keeps the same code working under QEMU, whose
 * model completes a transfer inside the register access.
 *
 * The Arasan needs every register touched as a 32-bit word, so the
 * 16-bit halves of BLKSIZECNT and the command register are written
 * together.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "../port/error.h"
#include "../port/sd.h"

extern void gpiofsel(int, int);		/* gpiobcm.c */
extern int dmaxfer(void*, u32, ulong, int, int);	/* dmabcm.c */
extern int mboxgetclock(int, u32*);	/* mailbox.c */
extern int mboxsetpower(int, int);

enum {
	Rarg2		= 0x00/4,
	Rblksizecnt	= 0x04/4,	/* block count<<16 | block size */
	Rarg1		= 0x08/4,
	Rcmdtm		= 0x0c/4,	/* command index<<24 | flags */
	Rresp0		= 0x10/4,
	Rresp1		= 0x14/4,
	Rresp2		= 0x18/4,
	Rresp3		= 0x1c/4,
	Rdata		= 0x20/4,
	Rstatus		= 0x24/4,
	Rcontrol0	= 0x28/4,
	Rcontrol1	= 0x2c/4,
	Rinterrupt	= 0x30/4,
	Rirptmask	= 0x34/4,
	Rirpten		= 0x38/4,
	Rcontrol2	= 0x3c/4,
	Rcaps0		= 0x40/4,	/* SDHCI capabilities */
	Rcaps1		= 0x44/4,
	Rslotisrver	= 0xfc/4,

	Capsdma		= 1<<22,	/* caps0: the controller can do SDMA */

	/* Rstatus */
	Scmdinhibit	= 1<<0,
	Sdatinhibit	= 1<<1,

	/* Rcontrol0 */
	C0power		= 1<<8,
	C0hctl4bit	= 1<<1,

	/* Rcontrol1 */
	C1clkintlen	= 1<<0,		/* internal clock enable */
	C1clkstable	= 1<<1,
	C1clken		= 1<<2,		/* clock to the card */
	C1srsthost	= 1<<24,
	C1srstdata	= 1<<26,
	C1toutshift	= 16,

	/* Rinterrupt and its masks */
	Icmddone	= 1<<0,
	Idatadone	= 1<<1,
	Iwriterdy	= 1<<4,
	Ireadrdy	= 1<<5,
	Ierr		= 1<<15,
	Ictoerr		= 1<<16,	/* command timeout */
	Iall		= 0x017f7137,

	/* Rcmdtm flags */
	Trdata		= 1<<4,		/* transfer is card to host */
	Tmulti		= 1<<5,		/* more than one block */
	Tautocmd12	= 1<<2,		/* the controller sends the stop itself */
	Tmblkcnt	= 1<<1,
	Cmdisdata	= 1<<21,
	Cmdcrcchk	= 1<<19,
	Cmdixchk	= 1<<20,
	Cmdresp136	= 1<<16,
	Cmdresp48	= 2<<16,
	Cmdresp48busy	= 3<<16,

	Maxblocks	= 64,		/* blocks in one multi-block command */
	/*
	 * This controller cannot do SDHCI's own SDMA.  Its capabilities
	 * register reads 0x0 0x0 on the board -- not a bit set anywhere,
	 * which is the Arasan on this SoC declining to describe itself --
	 * and a transfer set up the SDMA way starts and never completes:
	 *
	 *	emmc: read block 61798 failed: interrupt 0x0 status 0x1ff0206
	 *
	 * So the data moves the other way this SoC provides: the general
	 * DMA engine, paced by the EMMC's own DREQ line, reading or
	 * writing the data register while the controller raises it.  That
	 * is what dmabcm.c is for and what its header says the SD
	 * controller uses on a real Pi.
	 */
	Emmcdreq	= 11,		/* the DREQ this peripheral raises */
	Emmcdatabus	= 0x7e300020,	/* Rdata, as a bus master sees it */
	Waitms		= 3000,		/* how long a card may take over one transfer */
	Sleepms		= 20,		/* one sleep waiting for the interrupt */
	Emmcirq		= 62,		/* GPU IRQ: this controller */
	Spinreads	= 2000,		/* status reads before yielding: ~200us */
	Idclock		= 400000,
	Datclock	= 25000000,
	Secsize		= 512,
	Alt3		= 7,		/* GPIO fsel alt3: card to this controller */
};

typedef struct Ctlr Ctlr;
struct Ctlr {
	QLock;
	volatile u32* r;	/* every access must reach the SoC */
	uvlong	sectors;
	int	byteaddr;
	int	inited;
	int	errors;
	ulong	fclk;
	uint	rca;
	Rendez	irq;		/* woken by the controller's interrupt */
	u32	want;		/* the status bits a wait is for */
	int	armed;		/* the handler is registered */
	int	fired;		/* and it has actually run at least once */
	vlong	isr;		/* when it last ran, for the timing below */
	int	nointr;		/* or it has not: poll instead */
};

static Ctlr emmcctlr;
extern SDifc sdemmcbcmifc;

/*
 * Wait for a bit in the interrupt-status register, clearing it and any
 * error bits.  Returns 0, or -1 with the status in *stsp.
 */
/*
 * How many waits to report, and off by default.  The board's 1.5MB FAT
 * write measured 86 KB/s and this is where a block transfer waits, so
 * the question is whether the card is slow or this is.
 */
static int emmctrace = 0;

/*
 * Whether to sleep for the controller's interrupt.  On, since
 * 19 September 2026, and this is the measurement that turned it on.
 *
 * It used to be off, and the comment that turned it off said sleeping
 * was twelve times slower -- 86 KB/s spinning against 6 -- "because a
 * woken process on this kernel waits tens of milliseconds to be
 * scheduled".  It then said that fixing the wake-up latency is what
 * would make sleeping worth having, and that turning this on is how
 * such a fix gets measured.
 *
 * The fix landed.  Stage one of the scheduling work found that
 * clockintr() ends in canlock(), that canlock() raised its caller to
 * PriLock and nothing ever put it back, and so that every clock tick
 * pinned whatever was running at the top of the ordinary range -- which
 * is exactly what a process woken from the tsleep below had to outrank.
 * With that removed the old number does not survive.  Two pairs of
 * 1.5MB writes on the board, dd through dossrv onto the card:
 *
 *	                     spinning        sleeping
 *	write 1.5MB          15.6 s, 16.4 s  15.8 s, 17.4 s
 *	worst held window    203 ms, 178 ms  262 us, 262 us
 *	mean held window     376 us, 362 us  118 us, 117 us
 *
 * So it costs a few percent of throughput and takes the longest stretch
 * this driver holds the processor without yielding from a fifth of a
 * second to a quarter of a millisecond -- and 262us is the Spinreads
 * spin at the top of awaitirq, which is to say the whole of the rest of
 * it is gone.  That window was the largest in the kernel by two orders
 * of magnitude, and every wake that lands behind it pays for it.
 *
 * The interrupt does arrive and is what does the waking: 1815 of 1821
 * sleeps in the run above were ended by the handler rather than by the
 * timeout, about 1.8ms from the interrupt to the process running again.
 *
 * "echo sleep 0 >/dev/sdM0/ctl" puts it back, because the comparison
 * should stay takeable.
 */
static int emmcsleep = 1;

/*
 * Whether to let the controller move the data itself.
 *
 * Without this the CPU copies every word through Rdata: 128 MMIO
 * accesses per 512-byte sector, each one a trap out to the peripheral
 * bus, and that is where a transfer's time goes.  SDHCI's SDMA has the
 * controller read or write memory directly -- one address handed over
 * before the command, one completion at the end, and no per-word loop.
 *
 * Off by default until it is measured on the board beside the loop it
 * replaces, the same way emmcsleep was: "echo dma 1 >/dev/sdM0/ctl".
 * A DMA path that is wrong does not fail loudly, it writes the right
 * number of bytes to the wrong place, so it does not become the default
 * on the strength of it compiling.
 */
static int emmcdma = 0;
static ulong emmcnwait, emmcnslept, emmcwoke, emmctimeout;
static uvlong emmcwakeus;
static uvlong emmcus;

/*
 * The paragraph above is from before the scheduling work, and it names
 * the thing that work went and fixed: "a woken process on this kernel
 * waits tens of milliseconds to be scheduled".  Stage one found why --
 * clockintr() ends in canlock(), canlock() raised its caller to PriLock
 * and nothing ever put it back, so every tick pinned whatever was
 * running at the top of the ordinary range, which is precisely what a
 * process woken from the tsleep below then had to outrank.  That is
 * removed, and SCHED-LAT on silicon says a woken process now gets the
 * processor at once.  So the measurement this comment asks for is worth
 * taking again, and "echo emmc sleep 1 >/dev/sdM0/ctl" is how, without
 * a kernel to build and install first.
 *
 * And the spin is measured rather than argued about.  It is the largest
 * thing in this kernel that holds the processor without yielding: not a
 * fixed number of microseconds but a whole block, which is why the plan
 * asks for it as a measurement.  Two todget() calls per awaitirq, and
 * awaitirq runs a few hundred times a second at this board's rate, so
 * the instrument is always on -- an instrument that has to be switched
 * on is one nobody has the number from.
 */
static ulong emmcspinn;		/* windows held without yielding */
static uvlong emmcspinus;	/* microseconds held, in total */
static ulong emmcspinmax;	/* the longest single window */
static u32 emmcspinwant;	/* what that one was waiting for */

/*
 * The controller's interrupt, and the wait that uses it.
 *
 * A block transfer is mostly the card thinking: this driver spun a
 * hundred thousand status reads and then busy-waited a millisecond at a
 * time, so the processor was held for the whole of it, and the board's
 * 1.5MB FAT write measured 86 KB/s while everything else on the machine
 * stopped.  Both of the systems this port learns from wait instead --
 * 9front's bcm/emmc.c sleeps on datadone, Linux's bcm2835 driver is
 * interrupt-driven throughout.
 *
 * Its own Rendez and its own condition: an earlier attempt slept on
 * up->sleep with a condition that is never true, which is a way of
 * asking for a tick rather than for the hardware, and it panicked the
 * board in wakeup() when something else readied the process.
 *
 * Enabled only for the bits a wait asks for and disabled by the
 * handler, which is what stops a level-triggered status bit asserting
 * again before the waiter has read it.  A controller whose interrupt
 * never arrives is slow rather than broken: the first wait that times
 * out says so once and the driver goes back to polling for good.
 */
static int
irqready(void *v)
{
	Ctlr *c = v;

	return (c->r[Rinterrupt] & (c->want|Ierr)) != 0;
}

static void
emmcintr(Ureg*, void *a)
{
	Ctlr *c = a;

	c->fired = 1;
	c->isr = todget(nil);
	c->r[Rirpten] = 0;	/* disarm; the waiter re-arms what it needs */
	wakeup(&c->irq);
}

static void
emmcspinaccount(uvlong held, u32 want)
{
	emmcspinn++;
	emmcspinus += held;
	if(held > emmcspinmax){
		emmcspinmax = held;
		emmcspinwant = want;
	}
}

/*
 * Close the currently open non-preemptible window and add it to the
 * total.  A window is any stretch of awaitirq that does not yield: the
 * status spin at the top and the delay(1) loop at the bottom.  The
 * tsleep in between is not one, which is the whole point of it.
 */
static void
spinclose(vlong *hs, uvlong *held)
{
	if(*hs != 0){
		*held += (todget(nil) - *hs)/1000;
		*hs = 0;
	}
}

static int
awaitirq(volatile u32 *r, u32 want, u32 *stsp)
{
	u32 sts;
	int i, ms;
	vlong t0, hs;
	uvlong held;

	ms = 0;
	t0 = emmctrace? todget(nil): 0;
	held = 0;
	hs = todget(nil);

	/*
	 * Spin first, because the common case answers within a few reads,
	 * and then wait on the clock rather than on a loop count.  A card
	 * writing is allowed to take its time: it may be programming, or
	 * doing its own housekeeping, and how long a fixed number of MMIO
	 * reads takes is a property of the CPU, not of the card.  A FAT
	 * write on this board hit exactly that - the status said the data
	 * transfer was still running and no interrupt bit had been raised,
	 * the loop ran out, and dossrv took it as a hardware failure and
	 * panicked.
	 */
	for(i = 0; i < Spinreads; i++){
		sts = r[Rinterrupt];
		if((sts & (want|Ierr)) != 0)
			goto done;
	}
	/*
	 * Sleep for it, if the interrupt works here.  The spin above has
	 * already covered everything the card answers quickly.
	 */
	spinclose(&hs, &held);	/* the spin above is all this call has held */
	if(emmcsleep && emmcctlr.armed && !emmcctlr.nointr && up != nil && islo()){
		emmcctlr.want = want;
		r[Rirpten] = want|Ierr;
		for(ms = 0; ms < Waitms/Sleepms; ms++){
			if((r[Rinterrupt] & (want|Ierr)) != 0)
				break;
			emmcctlr.fired = 0;	/* per wait, not for ever */
			tsleep(&emmcctlr.irq, irqready, &emmcctlr, Sleepms);
			emmcnwait++;
			if(emmcctlr.fired){
				emmcwoke++;
				emmcwakeus += (todget(nil) - emmcctlr.isr)/1000;
			}else
				emmctimeout++;
			if(emmctrace && emmcnwait % 500 == 0)
				print("emmc: %lud sleeps, %lud woken by the interrupt, "
					"%lud timed out, %llud us from interrupt to running\n",
					emmcnwait, emmcwoke, emmctimeout,
					emmcwoke? emmcwakeus/emmcwoke: 0);
			/*
			 * One sleep is enough to tell.  If the handler has
			 * never run, the wait above ended on its timeout
			 * and every wait after it will too: that is 20ms a
			 * block, and the board measured 7 KB/s doing it --
			 * twelve times slower than the spin it replaced,
			 * with no EMMC-NOINTR printed because the status
			 * bit did eventually set.  The question is not
			 * whether the bit arrives, it is whether the
			 * interrupt does.
			 */
			if(emmctimeout > 8 && emmcwoke == 0)
				break;	/* it never wakes us; stop trying */
		}
		r[Rirpten] = 0;
		sts = r[Rinterrupt];
		if((sts & (want|Ierr)) != 0)
			goto done;
		if(emmctimeout > 8 && emmcwoke == 0){
			emmcctlr.nointr = 1;
			print("EMMC-NOINTR the controller's interrupt never ran; polling\n");
		}
		if((sts & (want|Ierr)) != 0)
			goto done;
	}
	hs = todget(nil);	/* and the busy wait below is another window */
	for(ms = 0; ms < Waitms; ms++){
		/*
		 * A busy wait, for a controller whose interrupt does not
		 * come and for anything early enough to have no process to
		 * sleep.
		 *
		 */
		delay(1);
		sts = r[Rinterrupt];
		if((sts & (want|Ierr)) != 0)
			goto done;
	}
	spinclose(&hs, &held);
	emmcspinaccount(held, want);
	if(stsp != nil)
		*stsp = r[Rinterrupt];
	return -1;
done:
	spinclose(&hs, &held);
	emmcspinaccount(held, want);
	if(emmctrace){
		emmcnwait++;
		if(ms > 0)
			emmcnslept++;
		emmcus += (todget(nil) - t0)/1000;
		if(emmcnwait % 2000 == 0)
			print("emmc: %lud waits, %lud slept, %llud us total, "
				"%llud us each\n", emmcnwait, emmcnslept,
				emmcus, emmcus/emmcnwait);
	}
	r[Rinterrupt] = sts & (want|Ierr|0xffff0000);
	if(stsp != nil)
		*stsp = sts;
	if((sts & Ierr) != 0)
		return -1;
	return 0;
}

static int
cmd(Ctlr *c, int index, u32 arg, u32 flags, u32 *stsp)
{
	volatile u32 *r = c->r;
	int i;

	for(i = 0; i < 100000; i++)		/* the command line must be free */
		if((r[Rstatus] & Scmdinhibit) == 0)
			break;
	if(r[Rstatus] & Scmdinhibit){
		if(stsp != nil)
			*stsp = r[Rstatus];
		return -1;
	}
	r[Rinterrupt] = r[Rinterrupt];		/* clear what is left over */
	r[Rarg1] = arg;
	r[Rcmdtm] = (u32)index<<24 | flags;
	return awaitirq(r, Icmddone, stsp);
}

/* Card clock: the SDHCI 10-bit divided clock, base/(2*div). */
static void
emmcclock(Ctlr *c, ulong want)
{
	volatile u32 *r = c->r;
	ulong div, base;
	u32 ctl;
	int i;

	base = c->fclk != 0? c->fclk: 250000000;
	div = base / (2*want);
	if(div * 2 * want < base)
		div++;
	if(div > 0x3ff)
		div = 0x3ff;

	ctl = r[Rcontrol1];
	ctl &= ~(u32)(C1clken|0xffc0);		/* stop the clock, clear divisor */
	r[Rcontrol1] = ctl;
	delay(2);
	ctl &= ~(u32)(0xf<<C1toutshift);
	ctl |= 0xe<<C1toutshift;		/* longest data timeout */
	ctl |= (div & 0xff)<<8 | ((div>>8) & 3)<<6;
	ctl |= C1clkintlen;
	r[Rcontrol1] = ctl;
	for(i = 0; i < 100000; i++)		/* wait for the clock to settle */
		if(r[Rcontrol1] & C1clkstable)
			break;
	r[Rcontrol1] = r[Rcontrol1] | C1clken;
	delay(2);
}

static int
emmcreset(Ctlr *c)
{
	volatile u32 *r = c->r;
	int i;

	r[Rcontrol0] = 0;
	r[Rcontrol1] = C1srsthost;
	for(i = 0; i < 100000; i++)
		if((r[Rcontrol1] & C1srsthost) == 0)
			break;
	if(r[Rcontrol1] & C1srsthost)
		return -1;
	r[Rcontrol1] = 0;
	emmcclock(c, Idclock);
	r[Rirpten] = 0;				/* poll: no interrupts to the core */
	r[Rirptmask] = Iall;			/* but every event visible in status */
	r[Rinterrupt] = r[Rinterrupt];
	return 0;
}

/*
 * Identification, as for any SD card: idle, interface condition, the
 * initialisation loop, then address, geometry, selection and a 512-byte
 * block length.  Returns 1 with the card selected and sized.
 */
static int
emmccardinit(Ctlr *c)
{
	volatile u32 *r = c->r;
	u32 ocr, csd[4], sts, clk;
	int i, rbl, cmult;
	uvlong cap;
	uchar b[16];

	for(i = 48; i <= 53; i++)		/* card to this controller */
		gpiofsel(i, Alt3);
	mboxsetpower(0, 1);			/* firmware power domain 0: SD */
	if(mboxgetclock(1, &clk) < 0)		/* EMMC clock */
		clk = 0;
	c->fclk = clk;
	if(emmcreset(c) < 0){
		print("emmc: controller will not reset (control1 %#lux)\n",
			(ulong)r[Rcontrol1]);
		return 0;
	}
	r[Rcontrol0] = C0power;
	delay(10);

	if(cmd(c, 0, 0, 0, &sts) < 0){		/* CMD0 GO_IDLE */
		print("emmc: CMD0 failed, interrupt %#lux\n", (ulong)sts);
		return 0;
	}
	delay(2);
	if(cmd(c, 8, 0x1aa, Cmdresp48|Cmdcrcchk|Cmdixchk, &sts) < 0 ||
	    (r[Rresp0] & 0xff) != 0xaa){
		print("emmc: no card answering CMD8 (resp %#lux interrupt %#lux)\n",
			(ulong)r[Rresp0], (ulong)sts);
		return 0;
	}
	ocr = 0;
	for(i = 0; i < 100; i++){		/* ACMD41 */
		if(cmd(c, 55, 0, Cmdresp48, &sts) < 0)
			continue;
		if(cmd(c, 41, 0x40ff8000, Cmdresp48, &sts) < 0)
			continue;
		ocr = r[Rresp0];
		if(ocr & 0x80000000)
			break;
		delay(10);
	}
	if((ocr & 0x80000000) == 0){
		print("emmc: card never left idle (ocr %#lux)\n", (ulong)ocr);
		return 0;
	}
	c->byteaddr = (ocr & 0x40000000)? 0: 1;

	if(cmd(c, 2, 0, Cmdresp136|Cmdcrcchk, &sts) < 0){	/* CMD2 CID */
		print("emmc: CMD2 failed, interrupt %#lux\n", (ulong)sts);
		return 0;
	}
	if(cmd(c, 3, 0, Cmdresp48|Cmdcrcchk|Cmdixchk, &sts) < 0){ /* CMD3 RCA */
		print("emmc: CMD3 failed, interrupt %#lux\n", (ulong)sts);
		return 0;
	}
	c->rca = r[Rresp0] >> 16;

	if(cmd(c, 9, c->rca<<16, Cmdresp136|Cmdcrcchk, &sts) < 0){ /* CMD9 CSD */
		print("emmc: CMD9 failed, interrupt %#lux\n", (ulong)sts);
		return 0;
	}
	/*
	 * A 136-bit response comes back without its CRC and low byte: RESP3
	 * holds CSD bits 127:104, RESP2 103:72, RESP1 71:40, RESP0 39:8.
	 * Laying those out as bytes gives b[0] = CSD 127:120 as the decoding
	 * below expects; b[15] (the CRC byte) is not returned at all.
	 * Reading them a word at a time, as if RESP3 were the first four
	 * bytes, shifts the whole CSD by a byte and gives a nonsense
	 * capacity, which is what the first version of this reported.
	 */
	csd[0] = r[Rresp3];
	csd[1] = r[Rresp2];
	csd[2] = r[Rresp1];
	csd[3] = r[Rresp0];
	b[0] = csd[0]>>16;
	b[1] = csd[0]>>8;
	b[2] = csd[0];
	for(i = 0; i < 3; i++){
		b[3+i*4] = csd[1+i]>>24;
		b[4+i*4] = csd[1+i]>>16;
		b[5+i*4] = csd[1+i]>>8;
		b[6+i*4] = csd[1+i];
	}
	b[15] = 0;
	if((b[0]>>6) == 0){			/* CSD v1 (SDSC) */
		rbl = b[5] & 0x0f;
		cap = ((b[6]&3)<<10) | (b[7]<<2) | (b[8]>>6);
		cmult = ((b[9]&3)<<1) | (b[10]>>7);
		c->sectors = (cap+1) << (cmult+2+rbl-9);
	}else{					/* CSD v2 (SDHC) */
		cap = ((uvlong)(b[7]&0x3f)<<16) | (b[8]<<8) | b[9];
		c->sectors = (cap+1) << 10;
	}

	if(cmd(c, 7, c->rca<<16, Cmdresp48busy|Cmdcrcchk|Cmdixchk, &sts) < 0){
		print("emmc: CMD7 select failed, interrupt %#lux\n", (ulong)sts);
		return 0;
	}
	if(cmd(c, 16, Secsize, Cmdresp48|Cmdcrcchk|Cmdixchk, &sts) < 0){
		print("emmc: CMD16 failed, interrupt %#lux\n", (ulong)sts);
		return 0;
	}
	emmcclock(c, Datclock);
	print("emmc: card rca %#ux %s %llud sectors, clock %lud Hz\n",
		c->rca, c->byteaddr? "byte": "block", c->sectors, c->fclk);
	return 1;
}

static SDev*
emmcpnp(void)
{
	SDev *s;

	if((uintptr)EMMC == 0)
		return nil;
	emmcctlr.r = (volatile u32*)EMMC;
	if((s = malloc(sizeof(*s))) == nil)
		return nil;
	s->ctlr = &emmcctlr;
	s->idno = 'M';
	s->ifc = &sdemmcbcmifc;
	s->nunit = 1;
	return s;
}

static int
emmcverify(SDunit *u)
{
	USED(u);
	return 1;
}

static int
emmconline(SDunit *u)
{
	Ctlr *c = u->dev->ctlr;
	int first;

	first = 0;
	if(!c->inited){
		c->inited = 1;
		emmccardinit(c);
		first = 1;
	}
	if(c->sectors == 0)
		return 0;			/* no media */
	if(!c->armed){
		/*
		 * After identification, which runs before there are
		 * processes to sleep, and only for a controller with a
		 * card: an interrupt armed with nothing waiting on it is
		 * the quiet fault that cost this port its console once.
		 */
		intrenable(Emmcirq, emmcintr, c, 0, "emmc");
		c->armed = 1;
	}
	u->sectors = c->sectors;
	u->secsize = Secsize;
	return first? 2: 1;
}

static void
bioerror(Ctlr *c, int write, uvlong bno, u32 sts)
{
	volatile u32 *r = c->r;
	int i;

	if(c->errors++ <= 5)
		print("emmc: %s block %llud failed: interrupt %#lux status %#lux\n",
			write? "write": "read", bno, (ulong)sts, (ulong)r[Rstatus]);
	/*
	 * Leave the controller usable.  A transfer that ends this way ends
	 * with the data line still claimed - the status after the failed
	 * FAT write read back with the transfer active and the line
	 * inhibited - and every later command would then wait for a line
	 * that is never released.  Reset the data circuit and clear what
	 * is pending, so the failure costs one request rather than the
	 * card.
	 */
	r[Rinterrupt] = r[Rinterrupt];
	r[Rcontrol1] |= C1srstdata;
	for(i = 0; i < 100000; i++)
		if((r[Rcontrol1] & C1srstdata) == 0)
			break;
	if(r[Rcontrol1] & C1srstdata)
		print("emmc: data line will not reset (control1 %#lux)\n",
			(ulong)r[Rcontrol1]);
}

static long
emmcbio(SDunit *u, int lun, int write, void *a, long nb, uvlong bno)
{
	Ctlr *c = u->dev->ctlr;
	volatile u32 *r = c->r;
	uchar *p = a;
	long i, nthis;
	int j, k, dma;
	u32 arg, w, sts, flags;

	USED(lun);
	qlock(c);
	/*
	 * As many blocks per command as the controller's block count allows.
	 * A single-block command per sector costs a command, a response and
	 * a data phase for every 512 bytes; READ_MULTIPLE_BLOCK streams them
	 * under one command, with the controller sending the stop itself
	 * (auto CMD12).  The FIFO still moves a word at a time, so this is
	 * fewer commands, not fewer reads.
	 */
	for(i = 0; i < nb; ){
		nthis = nb - i;
		if(nthis > Maxblocks)
			nthis = Maxblocks;
		arg = c->byteaddr? (u32)((bno+i)*Secsize): (u32)(bno+i);
		for(j = 0; j < 100000; j++)	/* the data line must be free */
			if((r[Rstatus] & Sdatinhibit) == 0)
				break;
		r[Rblksizecnt] = (u32)nthis<<16 | Secsize;
		flags = Cmdisdata|Cmdresp48|Cmdcrcchk|Cmdixchk|Tmblkcnt;
		if(!write)
			flags |= Trdata;
		if(nthis > 1)
			flags |= Tmulti|Tautocmd12;
		dma = emmcdma;
		/* READ/WRITE_SINGLE_BLOCK, or the MULTIPLE_BLOCK pair */
		if(cmd(c, write? (nthis > 1? 25: 24): (nthis > 1? 18: 17),
		    arg, flags, &sts) < 0){
			bioerror(c, write, bno+i, sts);
			break;
		}
		if(dma){
			/*
			 * The engine moves the whole run while the
			 * controller's DREQ paces it, so there is no
			 * per-block ready to wait for -- only the transfer
			 * done at the end.  dmabcm.c does the cache work,
			 * because it is the one that knows which side the
			 * engine reads and which it writes.
			 */
			if(dmaxfer(p, Emmcdatabus, nthis*Secsize,
			    Emmcdreq, !write) < 0){
				print("emmc: dma %s of %ld blocks at %llud failed\n",
					write? "write": "read", nthis, bno+i);
				bioerror(c, write, bno+i, r[Rinterrupt]);
				goto out;
			}
			p += nthis*Secsize;
		}else{
			for(k = 0; k < nthis; k++){
				if(awaitirq(r, write? Iwriterdy: Ireadrdy, &sts) < 0){
					bioerror(c, write, bno+i+k, sts);
					goto out;
				}
				if(write){
					for(j = 0; j < Secsize; j += 4){
						w = p[0] | p[1]<<8 | p[2]<<16 | p[3]<<24;
						r[Rdata] = w;
						p += 4;
					}
				}else{
					for(j = 0; j < Secsize; j += 4){
						w = r[Rdata];
						p[0] = w;
						p[1] = w>>8;
						p[2] = w>>16;
						p[3] = w>>24;
						p += 4;
					}
				}
			}
		}
		if(awaitirq(r, Idatadone, &sts) < 0){
			bioerror(c, write, bno+i, sts);
			break;
		}
		i += nthis;
	}
out:
	qunlock(c);
	return i * Secsize;
}

static char*
emmcrctl(SDunit *u, char *p, char *e)
{
	Ctlr *c = u->dev->ctlr;
	volatile u32 *r = c->r;

	p = seprint(p, e, "geometry %llud %lud\n", u->sectors, u->secsize);
	p = seprint(p, e, "emmc rca %#ux %s sectors %llud clock %lud\n",
		c->rca, c->byteaddr? "byteaddr": "blockaddr", c->sectors, c->fclk);
	p = seprint(p, e, "emmc status %#lux control0 %#lux control1 %#lux interrupt %#lux ver %#lux errors %d\n",
		(ulong)r[Rstatus], (ulong)r[Rcontrol0], (ulong)r[Rcontrol1],
		(ulong)r[Rinterrupt], (ulong)r[Rslotisrver], c->errors);
	/*
	 * The capabilities, and the one bit in them this driver has a
	 * question about: bit 22 of caps0 is whether the controller can
	 * do SDMA at all.  Printed rather than remembered, because
	 * whether the Pi's Arasan implements it is exactly the sort of
	 * thing that gets asserted from memory and is wrong.
	 */
	p = seprint(p, e, "emmc caps %#lux %#lux sdma %s\n",
		(ulong)r[Rcaps0], (ulong)r[Rcaps1],
		(r[Rcaps0] & Capsdma)? "yes": "no");
	return p;
}

static int
emmcwctl(SDunit *u, Cmdbuf *cb)
{
	Ctlr *c = u->dev->ctlr;
	uchar blk[Secsize];
	int i, k;
	long n;
	char buf[3*32+1], buf2[3*16+1], *q;

	/*
	 * The two switches and the number they are judged by.
	 *
	 *	echo emmc sleep 1 >/dev/sdM0/ctl	sleep for the interrupt
	 *	echo emmc trace 1 >/dev/sdM0/ctl	per-wait timing
	 *	echo emmc spin >/dev/sdM0/ctl		report and reset
	 *
	 * "spin" is the term stage two of the scheduling plan asks for:
	 * the longest the SD driver has held the processor in one go
	 * without yielding, which on this board is a whole block and is
	 * the largest such window in the kernel.  It prints the total and
	 * the mean beside it because a large worst case that happens once
	 * and a large mean are different problems.
	 */
	if(strcmp(cb->f[0], "sleep") == 0 && cb->nf == 2){
		emmcsleep = atoi(cb->f[1]);
		print("emmc: sleep %d\n", emmcsleep);
		return 0;
	}
	if(strcmp(cb->f[0], "dma") == 0 && cb->nf == 2){
		emmcdma = atoi(cb->f[1]);
		print("emmc: dma %d\n", emmcdma);
		return 0;
	}
	if(strcmp(cb->f[0], "trace") == 0 && cb->nf == 2){
		emmctrace = atoi(cb->f[1]);
		print("emmc: trace %d\n", emmctrace);
		return 0;
	}
	if(strcmp(cb->f[0], "spin") == 0){
		print("EMMC-SPIN max %lud us (want %#ux), mean %llud us over %lud waits; "
			"dma %d sleep %d: %lud slept, %lud woken by the interrupt, %lud timed out, "
			"%llud us interrupt to running\n",
			emmcspinmax, emmcspinwant,
			emmcspinn? emmcspinus/emmcspinn: 0ULL, emmcspinn,
			emmcdma, emmcsleep, emmcnwait, emmcwoke, emmctimeout,
			emmcwoke? emmcwakeus/emmcwoke: 0ULL);
		emmcspinn = 0;
		emmcspinus = 0;
		emmcspinmax = 0;
		emmcspinwant = 0;
		emmcnwait = emmcnslept = emmcwoke = emmctimeout = 0;
		emmcwakeus = 0;
		emmcus = 0;
		return 0;
	}
	if(strcmp(cb->f[0], "reinit") == 0){
		qlock(c);
		c->inited = 0;
		c->sectors = 0;
		c->errors = 0;
		i = emmccardinit(c);
		qunlock(c);
		print("emmc: reinit %s\n", i? "ok": "failed");
		return 0;
	}
	if(strcmp(cb->f[0], "readblk") == 0 && (cb->nf == 2 || cb->nf == 3)){
		uvlong bno = strtoull(cb->f[1], nil, 0);
		int off = cb->nf == 3? atoi(cb->f[2]): 0;

		if(off < 0 || off > Secsize-1)
			off = 0;
		memset(blk, 0, sizeof blk);
		n = emmcbio(u, 0, 0, blk, 1, bno);
		q = buf;
		for(k = off; k < off+32 && k < Secsize; k++)
			q += sprint(q, "%.2ux", blk[k]);
		*q = 0;
		print("emmc: readblk %llud+%d -> %ld %s (510,511 %.2ux%.2ux)\n",
			bno, off, n, buf, blk[510], blk[511]);
		return 0;
	}
	if(strcmp(cb->f[0], "readn") == 0 && (cb->nf == 3 || cb->nf == 4)){
		/*
		 * Read several blocks in one call and show the first bytes of
		 * the last one: that is a multi-block transfer, and the last
		 * block proves the whole run landed in order.  Binary through
		 * a pipe into grep is not a test - it wedges the shell.
		 */
		uvlong bno = strtoull(cb->f[1], nil, 0);
		long nblk = strtol(cb->f[2], nil, 0);
		int off = cb->nf == 4? atoi(cb->f[3]): 0;
		uchar *buf, *last;

		if(nblk < 1 || nblk > 128)
			nblk = 1;
		if(off < 0 || off > Secsize-16)
			off = 0;
		if((buf = malloc(nblk*Secsize)) == nil)
			error(Enomem);
		if(waserror()){
			free(buf);
			nexterror();
		}
		memset(buf, 0, nblk*Secsize);
		n = emmcbio(u, 0, 0, buf, nblk, bno);
		last = buf + (nblk-1)*Secsize;
		q = buf2;
		for(k = off; k < off+16; k++)
			q += sprint(q, "%.2ux", last[k]);
		*q = 0;
		print("emmc: readn %llud+%ld -> %ld last block %llud at %d: %s\n",
			bno, nblk, n, bno+nblk-1, off, buf2);
		free(buf);
		poperror();
		return 0;
	}
	if(strcmp(cb->f[0], "wtest") == 0 && (cb->nf == 2 || cb->nf == 3)){
		/*
		 * Write test that puts the sector back.  It refuses a sector
		 * that is not all zero unless told "force", so it can only be
		 * pointed at unused space by accident: on this board that is
		 * the gap between the master boot record and the first
		 * partition.  Writes a pattern, reads it back, restores the
		 * original bytes and reads again to check the restore.
		 */
		uvlong bno = strtoull(cb->f[1], nil, 0);
		static uchar orig[Secsize], want[Secsize], got[Secsize];
		int bad, badrestore, force;

		force = cb->nf == 3 && strcmp(cb->f[2], "force") == 0;
		if(emmcbio(u, 0, 0, orig, 1, bno) != Secsize){
			print("emmc: wtest %llud: cannot read it first\n", bno);
			return 0;
		}
		for(k = 0; k < Secsize; k++)
			if(orig[k] != 0)
				break;
		if(k != Secsize && !force){
			print("emmc: wtest %llud: sector is not empty (byte %d is %.2ux); "
				"add force to write it anyway\n", bno, k, orig[k]);
			return 0;
		}
		for(k = 0; k < Secsize; k++)
			want[k] = 0x5a ^ (k + (int)bno);
		if(emmcbio(u, 0, 1, want, 1, bno) != Secsize){
			print("emmc: wtest %llud: write failed\n", bno);
			return 0;
		}
		memset(got, 0, sizeof got);
		emmcbio(u, 0, 0, got, 1, bno);
		bad = 0;
		for(k = 0; k < Secsize; k++)
			if(got[k] != want[k])
				bad++;
		if(emmcbio(u, 0, 1, orig, 1, bno) != Secsize)
			print("emmc: wtest %llud: RESTORE FAILED, sector left written\n", bno);
		memset(got, 0, sizeof got);
		emmcbio(u, 0, 0, got, 1, bno);
		badrestore = 0;
		for(k = 0; k < Secsize; k++)
			if(got[k] != orig[k])
				badrestore++;
		print("emmc: wtest %llud: %d of %d bytes wrong after write, "
			"%d wrong after restore\n", bno, bad, Secsize, badrestore);
		return 0;
	}
	error(Ebadctl);
	return 0;
}

/*
 * Shutdown calls this for every controller, and complains on the
 * console about one that has none -- a reboot printed "#S/sdM: no
 * disable function" on its way out.  There is nothing this controller
 * needs told: the card keeps its state, and the firmware reinitialises
 * the Arasan on the next boot.  Stopping the clock is what "disable"
 * means here, and it leaves the block quiet rather than mid-transfer.
 */
static int
emmcdisable(SDev *sdev)
{
	Ctlr *c = sdev->ctlr;

	if(c != nil && c->r != nil)
		c->r[Rcontrol1] &= ~(C1clkintlen|C1clken);
	return 0;
}

SDifc sdemmcbcmifc = {
	"emmc",				/* name */

	emmcpnp,			/* pnp */
	nil,				/* enable */
	emmcdisable,			/* disable */

	emmcverify,			/* verify */
	emmconline,			/* online */
	nil,				/* rio */
	emmcrctl,			/* rctl */
	emmcwctl,			/* wctl */

	emmcbio,			/* bio */
	nil,				/* probe */
	nil,				/* clear */
	nil,				/* rtopctl */
	nil,				/* wtopctl */
};
