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
	C1srstcmd	= 1<<25,
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

/*
 * Freeze on a DMA failure instead of recovering from it.  Off, because
 * a board in use should keep going; on, for a board being debugged,
 * where the reset that makes recovery possible is also what destroys
 * the evidence.
 */
static int emmcdmafreeze = 0;

/*
 * Localisation switches for the DMA write stall, each one a question
 * rather than a fix.  The stall is deterministic -- three blocks of
 * nine, every time, with the engine waiting for a DREQ and the
 * controller's Iwriterdy set -- and what is not known is which side
 * carries the state that makes the fourth block never come.
 *
 *	dmaclearirq  acknowledge every eMMC interrupt status bit before
 *	             arming a transfer.  If this cures it, the readiness
 *	             event is latched across transactions and the DREQ
 *	             machinery wants a transition it is not getting.
 *	dmareset     reset the DMA channel before every transfer.  If
 *	             this cures it, the engine carries the state.
 *	dmadatareset reset the eMMC data circuit before every transfer.
 *	             If this cures it and the other two do not, it is the
 *	             controller's own data/DMA state machine.
 *	dmadelay     microseconds to wait between transfers.  A failure
 *	             rate that moves sharply with this is a boundary
 *	             race rather than a programming error.
 */
static struct {
	ulong	cs;		/* the DMA channel's state before we armed it */
	ulong	emmcirq;	/* and the controller's, which is the half
				 * that has never been looked at before a
				 * transfer rather than after one */
	ulong	emmcstatus;
	ulong	emmcirpten;	/* whether the request was enabled at all */
} dmapre;

/*
 * Acknowledge the controller's interrupt status before arming a DMA
 * transfer.  ON, and this is the fix for the stall.
 *
 * The failure: a DMA write of nine blocks moved exactly three and
 * stopped, every time, with the engine still ACTIVE waiting for a DREQ
 * and the controller's Iwriterdy set -- it had room and was not asking.
 * Deterministic, and only through the filesystem; sixteen variations
 * of transfer size, repetition, sustained traffic, mixed direction,
 * interrupt sleeping and 500 back-to-back in-kernel transfers were all
 * clean.
 *
 * What the pre-transfer capture showed, which is the half nobody had
 * looked at: "BEFORE: emmc interrupt 0x10".  Iwriterdy was ALREADY set
 * when the transfer was armed.  cmd() clears the interrupt register,
 * the command runs, and the controller then raises Iwriterdy because
 * it really is ready -- so by the time the engine is started the bit
 * is standing, and the DREQ machinery is waiting for a transition that
 * has already happened.  Writing the status back (it is
 * write-one-to-clear) makes the controller assert it afresh, and the
 * edge arrives.
 *
 * IT IS NOT THE FIX, and the way that was established is the point.
 *
 * One run with it on was clean and the very next with it off failed at
 * the third block, which looked like a clean falsification and was
 * written up as one.  It was a single pair.  Repeating the SAME
 * workload three times with it on gives ok, FAIL, FAIL -- the failure
 * rate is about two in three, and at that rate one pass and one
 * failure carry no information at all.
 *
 * That is the same mistake this port keeps paying for, made by the
 * person who had spent the day writing the rule down: the emu
 * scheduler barrier was believed only after 60 runs against 60, and
 * this was believed after one against one.
 *
 * So it stays off and stays switchable, and what it is really worth
 * needs a rate: the same workload N times with it on and N with it
 * off, on one boot, before anything is claimed.
 *
 * SETTLED, 21 September 2026, and it is worth nothing.  Not by a rate
 * in the end -- the failure turned out to be deterministic, so a
 * frequency was the wrong instrument.  tools/jtag/dmaab.sh boots
 * clean, sets this one way, does one write, keeps the dump; reboots,
 * sets it the other way, does one write; diffs the two.  Both failed,
 * and the dumps differ in three lines: the start block, the source
 * address, and this:
 *
 *	off:  BEFORE: dma cs 0xa emmc interrupt 0x10 status 0x1ff0506
 *	on:   BEFORE: dma cs 0xa emmc interrupt 0x00 status 0x1ff0506
 *
 * The switch does exactly what it claims.  Iwriterdy is set when the
 * channel is armed with it off, and clear with it on.  The transfer
 * then stalls in precisely the same place either way -- three blocks
 * of nine, cs 0x21, ti 0xb0148, blksizecnt 0x70200 -- so the stale
 * interrupt is not what the stall is about.  That is as clean a
 * negative as this port has had: the mechanism was real, the
 * intervention worked, and the outcome did not move.
 *
 * What the same dumps show still uncleared, identically in both arms,
 * is the DMA channel's own CS: "dma cs 0xa" is END|DREQ left by the
 * previous transfer, and nothing clears it between transfers.  That
 * is the next thing to suspect, and it is now cheap to test the same
 * way.
 */
static int emmcdmaclearirq = 0;
/*
 * Does the controller gate its DMA request on the interrupt ENABLE
 * register rather than on the status?
 *
 * Noticed in the first register dump ever taken over JTAG, and written
 * down in tools/jtag/README at the time as untestable without a way to
 * write that register on a live machine: irpt_en is 0.  This driver
 * arms it only when it is about to sleep, so for a DMA transfer it
 * stays zero throughout.
 *
 * Two experiments since have made it the best remaining explanation by
 * eliminating the others.  The stale eMMC interrupt is not it
 * (dmaclearirq clears Iwriterdy before arming; the stall is
 * unchanged).  Stale DMA channel state is not it (dmareset clears END;
 * the stall is unchanged, and the DREQ bit that remains is the live
 * line, not a leftover).  What the failure dumps say is that at the
 * stall the engine is ACTIVE with DREQ_STOPS_DMA set and the DREQ bit
 * CLEAR -- the engine is waiting correctly and the controller has
 * stopped asking -- while that same controller's status still has
 * Iwriterdy set.  It has room, it says so in the status, and it is not
 * raising the request.
 *
 * So: set Ireadrdy|Iwriterdy in Rirpten for the transfer and take them
 * out again afterwards.  If the stall goes, the request was gated on
 * the enable.  If it does not, that is a third mechanism eliminated
 * and the answer is somewhere else entirely.
 *
 * A question, not a setting, and off by default until it has been
 * asked properly -- the same way both of the others were asked.
 *
 * ASKED, AND THE QUESTION DID NOT GET THROUGH.  First run, 21
 * September: the arm with this on failed, and its own dump says why
 * that means nothing --
 *
 *	BEFORE: dma cs 0xa emmc interrupt 0x10 status 0x1ff0506 irpten 0x0
 *
 * irpten reads 0 at the moment the channel is armed, three
 * instructions after "r[Rirpten] |= Ireadrdy|Iwriterdy".  The write is
 * being dropped.  Rstatus is 0x1ff0506 there, which has Sdatinhibit
 * set: the command is issued and the data circuit is live, and this
 * controller appears not to take that register then.  So the
 * hypothesis is untested, not disproved, and the enable has to be set
 * before the command rather than between the command and the
 * transfer.
 *
 * That the dump could say so at all is why the BEFORE line prints
 * irpten.  An intervention that is assumed to have happened is not an
 * experiment, and this one would have read as a clean negative.
 */
/*
 * Print every emmcbio call: direction, blocks, block number, buffer.
 *
 * Five things have now been eliminated by asking the kernel to do the
 * transfer itself -- page offset, direction alternation, the
 * one-block-read-then-nine-block-write shape dossrv uses, repetition,
 * and transfer size -- and in-kernel transfers simply do not fail:
 * 500 clean, 100 clean, 50 clean.  Through dossrv the same card fails
 * about two writes in three.
 *
 * So the trigger is not the shape of a transfer, and guessing at what
 * else differs has produced five wrong guesses.  This prints what
 * dossrv ACTUALLY asks for, so the two sequences can be compared
 * rather than imagined.
 */
static int emmcbiotrace = 0;
static int emmcdmaunstick = 0;
static int emmcdmairqen = 0;
static int emmcdmareset = 0;
static int emmcdmadatareset = 0;
static int emmcdmadelay = 0;
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
	 * Stop the card first, then the controller.
	 *
	 * A multi-block write that ends this way leaves the CARD still in
	 * the transaction: it was told to take nine blocks by CMD25, it
	 * has had some of them, and it is waiting for the rest.  The
	 * controller can be reset all day and the card will not care.
	 * The next command then times out against a card that is not
	 * listening -- which is exactly what the console showed, the
	 * retry after a failed DMA write coming back with interrupt
	 * 0x18000, Ierr|Ictoerr, a command timeout.
	 *
	 * CMD12 is STOP_TRANSMISSION and it is what ends an open
	 * multi-block transfer.  The controller sends it itself on a
	 * transfer that completes (Tautocmd12 above); on one that does
	 * not complete, nobody does, and it has to be sent by hand before
	 * anything else will work.  It is allowed to fail -- if the card
	 * was never in a transaction there is nothing to stop -- so its
	 * result is deliberately not checked.
	 */
	/*
	 * The order matters and the first attempt had it wrong.  Clear
	 * the status BEFORE the abort, so CMD12's own completion is the
	 * only thing in it; send the abort; reset both lines, not just
	 * the data one; then clear again.
	 *
	 * Getting that wrong showed up as the retry failing with
	 * "interrupt 0x2 status 0x1ff0000" -- Idatadone, no error bit,
	 * against an idle controller.  That is not a fault at all: it is
	 * the aborted transfer's completion still sitting in the status
	 * register and being consumed by the next command's wait.
	 */
	r[Rinterrupt] = r[Rinterrupt];
	if(write || (r[Rstatus] & Sdatinhibit))
		cmd(c, 12, 0, Cmdresp48busy|Cmdcrcchk|Cmdixchk, nil);
	r[Rcontrol1] |= C1srstcmd | C1srstdata;
	for(i = 0; i < 100000; i++)
		if((r[Rcontrol1] & (C1srstcmd|C1srstdata)) == 0)
			break;
	if(r[Rcontrol1] & (C1srstcmd|C1srstdata))
		print("emmc: cmd/data lines will not reset (control1 %#lux)\n",
			(ulong)r[Rcontrol1]);
	r[Rinterrupt] = r[Rinterrupt];

	/*
	 * And wait for the card to finish what it was doing.
	 *
	 * Stopping the transfer and resetting the host does not make the
	 * card ready: it has taken some of a multi-block write and has to
	 * program what it has before it will accept another command.
	 * Reissuing immediately gets a command that never completes, and
	 * the console said exactly that -- the retry failing with
	 * "interrupt 0x2 status 0x1ff0000", which is awaitirq's TIMEOUT
	 * path returning whatever was in the interrupt register, against
	 * a controller that is idle and a card that is not listening yet.
	 *
	 * CMD13 is SEND_STATUS and bit 8 of its response is
	 * READY_FOR_DATA.  Poll it rather than guessing at a delay: how
	 * long a card takes to program is a property of the card.
	 */
	for(i = 0; i < 1000; i++){
		if(cmd(c, 13, (u32)c->rca<<16, Cmdresp48|Cmdcrcchk|Cmdixchk, nil) < 0)
			break;
		if(r[Rresp0] & (1<<8))		/* READY_FOR_DATA */
			break;
		microdelay(1000);
	}
	if(i >= 1000)
		print("emmc: card did not become ready after an abort\n");
	r[Rinterrupt] = r[Rinterrupt];
}

static long
emmcbio(SDunit *u, int lun, int write, void *a, long nb, uvlong bno)
{
	Ctlr *c = u->dev->ctlr;
	volatile u32 *r = c->r;
	uchar *p = a;
	long i, nthis;
	int j, k, dma, dmarv;
	u32 arg, w, sts, flags;

	USED(lun);
	if(emmcbiotrace)
		print("bio %s nb %ld bno %llud buf %#p pid %d\n",
			write? "w": "r", nb, bno, a, up? up->pid: 0);
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
		/*
		 * The interrupt enable, if it is being asked about, goes
		 * HERE -- after the wait for Sdatinhibit to clear and
		 * before the command, which is the only window in which
		 * this controller takes it.
		 *
		 * The first attempt set it between the command and the
		 * transfer and the write was silently dropped: the dump
		 * read back "irpten 0x0" three instructions later, with
		 * Rstatus 0x1ff0506, Sdatinhibit set.  The arm failed and
		 * would have been filed as a third clean negative.
		 */
		if(dma && emmcdmairqen)
			r[Rirpten] |= Ireadrdy|Iwriterdy;
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
			if(emmcdmaclearirq)
				r[Rinterrupt] = r[Rinterrupt];
			if(emmcdmadatareset){
				/*
				 * The controller's data circuit put back to
				 * a known state before each transfer, which
				 * is the heaviest of the three and the one
				 * that would say the eMMC carries the
				 * state.  It costs a reset per transfer, so
				 * it is a question and not a setting.
				 */
				r[Rcontrol1] |= C1srstdata;
				for(j = 0; j < 100000; j++)
					if((r[Rcontrol1] & C1srstdata) == 0)
						break;
			}
			if(emmcdmareset)
				dmachanreset();
			if(emmcdmadelay)
				microdelay(emmcdmadelay);
			dmapre.cs = dmachanstate();
			dmapre.emmcirq = r[Rinterrupt];
			dmapre.emmcstatus = r[Rstatus];
			dmapre.emmcirpten = r[Rirpten];
			dmarv = dmaxfer(p, Emmcdatabus, nthis*Secsize,
			    Emmcdreq, !write);
			/*
			 * Put Rirpten back whatever happened.  These bits
			 * are the sleeping path's to manage, and leaving
			 * them set would hand it interrupts it did not ask
			 * for.
			 */
			if(emmcdmairqen)
				r[Rirpten] &= ~(Ireadrdy|Iwriterdy);
			if(dmarv < 0){
				ulong moved = dmafail.len - dmafail.left;

				/*
				 * The peripheral's registers FIRST, before
				 * anything is reset.  The engine's side
				 * alone says a transfer stopped; it cannot
				 * say why, and the why is in the
				 * controller that was supposed to keep
				 * raising DREQ.  bioerror() below resets
				 * the data circuit and takes that state
				 * with it, which is how the first of these
				 * was lost.
				 */
				print("emmc: DMA %s FAILURE\n"
					"    start block     %llud\n"
					"    requested       %ld blocks / %lud bytes\n"
					"    DMA transferred %lud blocks / %lud bytes\n"
					"    DMA remaining   %lud blocks / %lud bytes\n"
					"    dma cs %#lux debug %#lux ti %#lux\n"
					"    dma src %#lux dst %#lux %s\n"
					"    BEFORE: dma cs %#lux emmc interrupt %#lux status %#lux irpten %#lux\n"
					"    emmc status %#lux interrupt %#lux\n"
					"    emmc control0 %#lux control1 %#lux blksizecnt %#lux\n",
					write? "WRITE": "READ", bno+i,
					nthis, (ulong)(nthis*Secsize),
					moved/Secsize, moved,
					dmafail.left/Secsize, dmafail.left,
					dmafail.cs, dmafail.debug, dmafail.ti,
					dmafail.src, dmafail.dst,
					dmafail.err? "(engine reported an error)":
						"(engine still active)",
					dmapre.cs, dmapre.emmcirq, dmapre.emmcstatus,
					dmapre.emmcirpten,
					(ulong)r[Rstatus], (ulong)r[Rinterrupt],
					(ulong)r[Rcontrol0], (ulong)r[Rcontrol1],
					(ulong)r[Rblksizecnt]);
				/*
				 * And stop here if asked.  A half-finished
				 * multi-block write cannot be resumed by
				 * changing which side of the FIFO the CPU
				 * is on: the card still believes it is in
				 * the middle of the CMD25 it was given, and
				 * the engine may still own the FIFO.  The
				 * fallback below is right for a machine
				 * that must keep running and wrong for one
				 * being debugged, so it answers to a
				 * switch: "echo dmafreeze 1 >/dev/sdM0/ctl".
				 */
				/*
				 * The transfer-info word said out loud.
				 * Hex hides whether the request is on the
				 * side it should be on, and that is the
				 * one field this failure is about.
				 */
				print("    ti decode: permap %lud%s%s%s%s%s\n",
					(dmafail.ti>>16) & 0x1f,
					(dmafail.ti & (1<<6))? " destdreq": "",
					(dmafail.ti & (1<<10))? " srcdreq": "",
					(dmafail.ti & (1<<4))? " destinc": "",
					(dmafail.ti & (1<<8))? " srcinc": "",
					(dmafail.ti & (1<<3))? " waitresp": "");
				if(emmcdmafreeze){
					print("emmc: frozen (dmafreeze); "
						"no reset, no retry\n");
					qunlock(c);
					return i * Secsize;
				}
				/*
				 * Fall back rather than fail.  A DMA path
				 * being wrong is a reason to stop using
				 * it, not a reason to lose the transfer:
				 * the caller here is a file server, and
				 * an error returned to it panics it and
				 * takes the machine's shell with it --
				 * which is how every failed experiment
				 * with this switch has ended so far, in a
				 * wedged board and a card in a reader.
				 *
				 * bioerror() resets the data circuit,
				 * which is exactly what makes the retry
				 * legal: the command is reissued from the
				 * top of the loop with dma off.
				 */
				/*
				 * Before anything is reset: can the stall
				 * be UNSTUCK by acknowledging Iwriterdy?
				 *
				 * Iwriterdy is a latched status bit -- it
				 * stays set until written back -- and
				 * nothing clears it during a DMA transfer.
				 * The driver only ever acknowledges it in
				 * the PIO path, inside awaitirq.  If the
				 * controller re-asserts DREQ when its
				 * buffer goes from full to having room, and
				 * that re-assertion needs the latched bit
				 * acknowledged, then the first time the
				 * card goes busy long enough for the buffer
				 * to fill, DREQ drops and never returns --
				 * which is exactly this stall, with the
				 * status still reporting room.
				 *
				 * It also explains why dmaclearirq changed
				 * nothing: that clears the register ONCE
				 * BEFORE arming, and the re-assertion this
				 * is about happens three blocks in.
				 *
				 * So: acknowledge it, wait, and look at the
				 * engine again.  If the remaining count
				 * moves, the mechanism is proved and the
				 * fix is to acknowledge during the transfer
				 * rather than after it.  If it does not,
				 * the hypothesis is dead and this says so.
				 */
				if(emmcdmaunstick){
					ulong was = dmafail.left, now;

					r[Rinterrupt] = Iwriterdy;
					for(j = 0; j < 200; j++){
						microdelay(100);
						now = dmachanleft();
						if(now != was)
							break;
					}
					now = dmachanleft();
					print("emmc: UNSTICK ack Iwriterdy: "
						"remaining %lud -> %lud after "
						"%d us, cs %#lux%s\n",
						was, now, (j+1)*100,
						dmachanstate(),
						now != was? "  *** IT MOVED ***":
							" (no change)");
				}
				/*
				 * Stop the ENGINE before stopping the card.
				 *
				 * The dump this failure prints ends with
				 * "(engine still active)" and nothing acted
				 * on it: bioerror() resets the command and
				 * data circuits and sends CMD12, and never
				 * touches the DMA channel, so the channel is
				 * left ACTIVE and still armed against this
				 * peripheral's DREQ.
				 *
				 * That is why the fallback has never worked.
				 * The PIO retry of the very same block fails,
				 * and so does a plain PIO write to a
				 * completely different block afterwards --
				 * measured, two dd runs, the second with DMA
				 * already switched off by this line below:
				 *
				 *	emmc: write block 1200006 failed
				 *	emmc: write block 2053 failed
				 *
				 * One DMA failure poisoned every write that
				 * followed it, which is why a single stall
				 * panics dossrv and leaves the board looking
				 * hung.  Resetting the controller while the
				 * engine is still holding the other end of
				 * the handshake cannot work.
				 */
				dmachanreset();
				bioerror(c, write, bno+i, r[Rinterrupt]);
				emmcdma = 0;
				continue;	/* same i: do it again, in pio */
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
	/*
	 * "dmatest nblocks count": write the same shape over and over
	 * and say which one breaks.
	 *
	 * The sweeps done from the shell could only ask "does one
	 * transfer of this size work", one process invocation each, and
	 * the answer was always yes.  What that cannot test is state
	 * carried ACROSS transactions, which is the only thing left
	 * standing after size, repetition, sustained traffic, mixed
	 * direction and interrupt sleeping were each ruled out.  So this
	 * runs them back to back inside the kernel with nothing in
	 * between, and reports the sequence number, which none of the
	 * shell tests could.
	 *
	 * It writes into the kfstest gap -- sectors 2048 to 16383, the
	 * unallocated space below the firmware's partition -- because a
	 * test that can damage the filesystem it is run from cannot be
	 * run often.
	 */

	/*
	 * "sdverify nblocks count [pageoff]": write known patterns,
	 * read them back, and say which blocks actually landed.
	 *
	 * Every check in this investigation so far has been of the
	 * driver's own accounting -- did the engine say it moved
	 * everything, did the controller say it was done.  None of them
	 * asks the only question that matters, which is whether the
	 * bytes are on the card.  A DMA that reports 3 of 9 blocks moved
	 * may still have put 3, or 2, or 9 blocks of something onto the
	 * medium, and the PIO fallback then rewrites the lot, so the
	 * file can be correct while the transfer was not -- or the
	 * reverse, which is worse and is what nobody has looked for.
	 *
	 * Each 512-byte block is filled with a word per 4 bytes:
	 *
	 *	(iteration<<24) | (block<<16) | offset
	 *
	 * so a block that reads back wrong says which iteration and
	 * which block its contents came from, rather than merely that it
	 * differs.  Stale data from the previous pass is therefore
	 * distinguishable from garbage.
	 *
	 * Guards of 0xAA and 0x55 sit either side of the buffer and are
	 * checked after every transfer, which separates "the engine
	 * stopped early" from "the engine wrote outside its buffer".
	 */
	if(strcmp(cb->f[0], "sdverify") == 0 && (cb->nf == 3 || cb->nf == 4)){
		int nb = atoi(cb->f[1]), cnt = atoi(cb->f[2]);
		int off = cb->nf == 4? (int)strtol(cb->f[3], nil, 0): 0;
		int k, b, j, bad, guardbad, firstbad;
		uchar *raw, *w, *rd;
		u32 want, got32;
		uvlong bno;
		long n;

		if(nb < 1 || nb > Maxblocks)
			nb = 9;
		if(cnt < 1)
			cnt = 20;
		if(off < 0 || off > BY2PG-1)
			off = 0;
		if((raw = malloc(nb*Secsize + 4*BY2PG)) == nil)
			error(Enomem);
		if((rd = malloc(nb*Secsize + BY2PG)) == nil){
			free(raw);
			error(Enomem);
		}
		if(waserror()){
			free(raw);
			free(rd);
			nexterror();
		}
		w = (uchar*)(((uintptr)raw + BY2PG-1) & ~((uintptr)BY2PG-1));
		w += BY2PG;			/* room for the leading guard */
		w += off;
		print("emmc: sdverify %d blocks x %d, buf %#p page offset %#lux, "
			"dma %d\n", nb, cnt, w,
			(ulong)((uintptr)w & (BY2PG-1)), emmcdma);
		bad = guardbad = 0;
		for(k = 0; k < cnt; k++){
			bno = (uvlong)2048 + (uvlong)(k % 200)*nb;
			for(b = 0; b < nb; b++)
				for(j = 0; j < Secsize; j += 4){
					want = (u32)((k&0xff)<<24) |
						(u32)((b&0xff)<<16) | (u32)j;
					w[b*Secsize+j+0] = want;
					w[b*Secsize+j+1] = want>>8;
					w[b*Secsize+j+2] = want>>16;
					w[b*Secsize+j+3] = want>>24;
				}
			memset(w - 64, 0xAA, 64);
			memset(w + nb*Secsize, 0x55, 64);

			n = emmcbio(u, 0, 1, w, nb, bno);

			for(j = 0; j < 64; j++)
				if(w[-64+j] != 0xAA || w[nb*Secsize+j] != 0x55){
					print("emmc: sdverify GUARD broken at "
						"transfer %d (%s guard)\n", k,
						w[-64+j] != 0xAA? "leading":
							"trailing");
					guardbad++;
					break;
				}
			if(n != nb*Secsize){
				print("emmc: sdverify write %d returned %ld of %d\n",
					k, n, nb*Secsize);
				bad++;
				continue;
			}
			memset(rd, 0, nb*Secsize);
			n = emmcbio(u, 0, 0, rd, nb, bno);
			if(n != nb*Secsize){
				print("emmc: sdverify read %d returned %ld of %d\n",
					k, n, nb*Secsize);
				bad++;
				continue;
			}
			firstbad = -1;
			want = got32 = 0;	/* kencc cannot see the
						 * break-then-use below */
			for(b = 0; b < nb; b++){
				for(j = 0; j < Secsize; j += 4){
					want = (u32)((k&0xff)<<24) |
						(u32)((b&0xff)<<16) | (u32)j;
					got32 = rd[b*Secsize+j] |
						rd[b*Secsize+j+1]<<8 |
						rd[b*Secsize+j+2]<<16 |
						(u32)rd[b*Secsize+j+3]<<24;
					if(got32 != want)
						break;
				}
				if(j < Secsize){
					if(firstbad < 0)
						firstbad = b;
					print("emmc: sdverify MISMATCH transfer %d "
						"block %d (abs %llud) at byte %d: "
						"want %#ux got %#ux "
						"(that content is iteration %d "
						"block %d)\n",
						k, b, bno+b, j, want, got32,
						(got32>>24)&0xff, (got32>>16)&0xff);
					bad++;
				}
			}
		}
		print("emmc: sdverify done: %d transfers, %d block mismatches, "
			"%d guard failures\n", cnt, bad, guardbad);
		poperror();
		free(raw);
		free(rd);
		return 0;
	}
	if(strcmp(cb->f[0], "dmatest") == 0 && cb->nf >= 3 && cb->nf <= 5){
		int nb = atoi(cb->f[1]), cnt = atoi(cb->f[2]), k;
		int off = cb->nf >= 4? (int)strtol(cb->f[3], nil, 0): 0;
		/*
		 * "dmatest nb count pageoff 1" alternates a read and a
		 * write instead of writing throughout.
		 *
		 * The filesystem path fails about two writes in three and
		 * the raw path almost never does, and the clearest thing
		 * that separates them is that dossrv interleaves FAT
		 * reads with its writes while dd only writes.  The DMA
		 * channel is programmed one way for a read -- source the
		 * data register, DREQ on the source -- and the other way
		 * for a write; if anything of the first survives into the
		 * second, the first write after a read is where it would
		 * show.
		 *
		 * "Mixed direction" is written down as already ruled out.
		 * It was ruled out on the raw path at bs=32768, sixty-four
		 * blocks, which is a transfer size that has never failed
		 * at all, so it was not ruled out.
		 */
		int rw = cb->nf == 5? atoi(cb->f[4]): 0;
		int dirty = rw >= 10;	/* rw 10, 11, 12: also re-dirty */
		/*
		 * rw >= 20: allocate and free the buffer per transfer,
		 * exactly as devsd's sdbio does.
		 *
		 * sdmalloc is mallocalign(n, BY2PG, 0, 0) and sdbio calls
		 * it for every write from a Dis process, then sdfree after
		 * -- because it will only use the caller's own buffer when
		 * that is a page-aligned kernel address, which a Dis
		 * buffer is not.  dmatest has always held one buffer for
		 * the whole run.
		 *
		 * This is the last structural difference between a path
		 * that fails two or three runs in three and one that has
		 * not failed in a thousand transfers, and it is the one
		 * with a mechanism behind it: two processes taking and
		 * returning page-aligned transfer buffers around a DMA
		 * the engine is reading from.
		 */
		int perxfer = rw >= 20;
		uchar *q;
		uvlong bno;
		uchar *buf, *p;
		long got;

		if(nb < 1 || nb > Maxblocks)
			nb = 9;
		if(cnt < 1)
			cnt = 100;
		/*
		 * The buffer, placed at a chosen PAGE offset.
		 *
		 * This used to clamp the offset to 0..63 and call it
		 * "pushed off a cache line", which was the wrong
		 * parameter and is why this test has never reproduced
		 * anything.  Seven failures collected over three days
		 * all report the same thing:
		 *
		 *	dma src 0xc3bb6640  0xc3f2e640  0xc3f3b640
		 *	        0xc3f84640  0xc3f87640  0xc3f9b640
		 *	        0xc3fb2640
		 *
		 * Seven for seven at page offset 0x640, which looked like
		 * dossrv handing the engine a 64-byte-aligned buffer.
		 * It is not: biotrace shows that buffer is PAGE aligned,
		 * and 0x640 is arithmetic -- dma src is read after the
		 * stall and is the engine's current source pointer,
		 * 0x600 delivered plus one 64-byte burst read ahead into
		 * its FIFO.  The rule holds on the one dump that stalled
		 * elsewhere too: 4096 delivered, src at buf+0x1040.
		 *
		 * So: align up to a page, add the offset asked for, and
		 * say what the buffer's page offset actually is, because
		 * that is the number the failures have in common.
		 */
		if(off < 0 || off > BY2PG-1)
			off = 0;
		if((buf = malloc(nb*Secsize + 2*BY2PG)) == nil)
			error(Enomem);
		if(waserror()){
			free(buf);
			nexterror();
		}
		p = (uchar*)(((uintptr)buf + BY2PG-1) & ~((uintptr)BY2PG-1));
		p += off;
		memset(p, 0x5a, nb*Secsize);
		print("emmc: dmatest %d blocks x %d%s, buf %#p page offset %#lux, "
			"dma %d clearirq %d irqen %d reset %d datareset %d "
			"delay %dus\n",
			nb, cnt, perxfer? " buffer allocated and freed per transfer":
				((rw % 10)? " alternating read/write":
				 (dirty? " re-dirtied each time": "")),
			p, (ulong)((uintptr)p & (BY2PG-1)),
			emmcdma, emmcdmaclearirq, emmcdmairqen,
			emmcdmareset, emmcdmadatareset, emmcdmadelay);
		for(k = 0; k < cnt; k++){
			bno = 2048 + (uvlong)(k % 1000)*nb;
			/*
			 * Dirty the buffer again before every transfer,
			 * which is what the real path does and this test
			 * did not.
			 *
			 * devsd's sdbio takes the caller's buffer directly
			 * only when it is a page-aligned kernel address;
			 * a write from a Dis process is neither, so it
			 * allocates one with sdmalloc and memmoves into it
			 * for every call.  The engine therefore always
			 * reads a buffer the CPU has just written, with
			 * every line of it dirty in the D-cache.  dmatest
			 * memset its buffer once and then handed the same
			 * clean lines to the engine two hundred times.
			 *
			 * That is the last difference between a path that
			 * fails about two writes in three and one that has
			 * never failed in a thousand transfers, and the
			 * engine's 64-byte read-ahead -- exactly one cache
			 * line -- is why it is worth suspecting.
			 */
			q = nil;
			if(perxfer){
				while((q = mallocalign(nb*Secsize, BY2PG, 0, 0)) == nil)
					resrcwait("no memory for dmatest");
				p = q;
				memset(p, 0x5a + k, nb*Secsize);
			}else if(dirty)
				memset(p, 0x5a + k, nb*Secsize);
			if((rw % 10) == 2 && (k & 1)){
				/*
				 * A SINGLE-block read at a low block, then
				 * the multi-block write -- which is what
				 * dossrv actually does: it reads a FAT
				 * sector and writes nine blocks of data.
				 *
				 * rw=1 alternates same-size, same-block
				 * transfers and 500 of those are clean, so
				 * direction alone is not it.  What is left
				 * between that and dossrv is the SHAPE of
				 * the alternation: one block versus nine,
				 * and a single-block command carries
				 * neither Tmulti nor Tautocmd12.
				 */
				got = emmcbio(u, 0, 0, p, 1, (uvlong)2048 + (k % 64));
				if(q != nil)
					free(q);
				if(got != Secsize){
					print("emmc: dmatest FAILED on the "
						"1-block read at transfer %d of "
						"%d: got %ld\n", k, cnt, got);
					break;
				}
				continue;
			}
			if((rw % 10) == 1 && (k & 1)){
				got = emmcbio(u, 0, 0, p, nb, bno);
				if(q != nil)
					free(q);
				if(got != nb*Secsize){
					print("emmc: dmatest FAILED reading at "
						"transfer %d of %d, block %llud: "
						"got %ld of %d\n",
						k, cnt, bno, got, nb*Secsize);
					break;
				}
				continue;
			}
			got = emmcbio(u, 0, 1, p, nb, bno);
			if(q != nil)
				free(q);
			if(got != nb*Secsize){
				print("emmc: dmatest FAILED at transfer %d "
					"of %d, block %llud: wrote %ld of %d\n",
					k, cnt, bno, got, nb*Secsize);
				break;
			}
		}
		if(k == cnt)
			print("emmc: dmatest %d transfers of %d blocks, all clean"
				"%s\n", cnt, nb,
				perxfer? " (a fresh buffer each time)": "");
		poperror();
		free(buf);
		return 0;
	}
	if(strcmp(cb->f[0], "dmaclearirq") == 0 && cb->nf == 2){
		emmcdmaclearirq = atoi(cb->f[1]);
		print("emmc: dmaclearirq %d\n", emmcdmaclearirq);
		return 0;
	}
	if(strcmp(cb->f[0], "biotrace") == 0 && cb->nf == 2){
		emmcbiotrace = atoi(cb->f[1]);
		print("emmc: biotrace %d\n", emmcbiotrace);
		return 0;
	}
	if(strcmp(cb->f[0], "dmaunstick") == 0 && cb->nf == 2){
		emmcdmaunstick = atoi(cb->f[1]);
		print("emmc: dmaunstick %d\n", emmcdmaunstick);
		return 0;
	}
	if(strcmp(cb->f[0], "dmairqen") == 0 && cb->nf == 2){
		emmcdmairqen = atoi(cb->f[1]);
		print("emmc: dmairqen %d\n", emmcdmairqen);
		return 0;
	}
	if(strcmp(cb->f[0], "dmareset") == 0 && cb->nf == 2){
		emmcdmareset = atoi(cb->f[1]);
		print("emmc: dmareset %d\n", emmcdmareset);
		return 0;
	}
	if(strcmp(cb->f[0], "dmadatareset") == 0 && cb->nf == 2){
		emmcdmadatareset = atoi(cb->f[1]);
		print("emmc: dmadatareset %d\n", emmcdmadatareset);
		return 0;
	}
	if(strcmp(cb->f[0], "dmadelay") == 0 && cb->nf == 2){
		emmcdmadelay = atoi(cb->f[1]);
		print("emmc: dmadelay %dus\n", emmcdmadelay);
		return 0;
	}
	if(strcmp(cb->f[0], "dmafreeze") == 0 && cb->nf == 2){
		emmcdmafreeze = atoi(cb->f[1]);
		print("emmc: dmafreeze %d\n", emmcdmafreeze);
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
