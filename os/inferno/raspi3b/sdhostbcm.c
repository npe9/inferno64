/*
 * BCM2835 SDHOST native-SD controller (0x3f202000) as an Inferno storage
 * device on the Raspberry Pi 3.  On this SoC the card can be wired to the
 * SDHOST controller or to the separate Arasan SDHCI; the SDHOST pins are
 * GPIO 48-53 in alt0 (fsel 4), so online() switches them (via gpiobcm.c's
 * gpiofsel) and then talks native SD - real R1/R2/R3/R6 responses and RCA
 * addressing, not the SPI-mode protocol.  (Under -M raspi3b the emulator
 * defaults the -sd card to the SDHCI, so the same pin switch is what
 * routes it to SDHOST there.)
 *
 * The register interface: write SDARG then SDCMD (index | flags |
 * NEW_FLAG) to run a command; the response lands in SDRSP0..3.  For a
 * data transfer set SDHBCT (block size) and SDHBLC (block count, which
 * arms datacnt), issue the command with READ_CMD/WRITE_CMD, and move the
 * block through the SDDATA FIFO a 32-bit word at a time.  On real hardware
 * that FIFO drains to / fills from the card at SD-clock speed, so each
 * word is gated on the SDEDM fill level (see fifospace()/fifodata());
 * the emulator drains it synchronously and never blocks there.
 *
 * This plugs into devsd with a bio callback, so devsd exposes the card
 * as /dev/sdM0/data.  Verified (under emulation) against a marker image,
 * read and write.
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

enum {
	SDCMD	= 0x00/4,
	SDARG	= 0x04/4,
	SDRSP0	= 0x10/4,	/* the response registers start at 0x10 */
	SDRSP1	= 0x14/4,
	SDRSP2	= 0x18/4,
	SDRSP3	= 0x1c/4,
	SDTOUT	= 0x08/4,	/* data timeout, in card clocks */
	SDCDIV	= 0x0c/4,	/* card clock divisor: fclk/(div+2) */
	SDHSTS	= 0x20/4,
	SDVDD	= 0x30/4,
	SDEDM	= 0x34/4,	/* extended data mode: FIFO fill level + FSM */
	SDHCFG	= 0x38/4,
	SDHBCT	= 0x3c/4,
	SDDATA	= 0x40/4,
	SDHBLC	= 0x50/4,

	Newflag	= 0x8000,
	Failflag = 0x4000,
	Busywait = 0x800,
	Noresp	= 0x400,
	Longresp = 0x200,
	Writecmd = 0x80,
	Readcmd	= 0x40,

	/* SDHSTS status/error bits, all write-1-to-clear */
	Hstsbusy = 0x400,
	Hstsblock = 0x200,
	Hstssdio = 0x100,
	Hstsrewtout = 0x80,
	Hstscmdtout = 0x40,
	Hstscrc16 = 0x20,
	Hstscrc7 = 0x10,
	Hstsfifo = 0x08,
	Hstsdata = 0x01,	/* the FIFO has data: set by a transfer, sticky */
	Hstsclear = Hstsbusy|Hstsblock|Hstssdio|Hstsrewtout|Hstscmdtout|
		Hstscrc16|Hstscrc7|Hstsfifo|Hstsdata,
	Hstserror = Hstsrewtout|Hstscmdtout|Hstscrc16|Hstscrc7|Hstsfifo,

	/* SDHCFG */
	Cfgbusyint = 1<<10,	/* SDHCFG interrupt enables */
	Cfgblockint = 1<<8,
	Cfgsdioint = 1<<5,
	Cfgdataint = 1<<4,
	Cfgslowcard = 1<<3,
	Cfgwideext = 1<<2,
	Cfgwideint = 1<<1,

	/* SDEDM finite-state machine, bits 3:0 */
	Edmfsmmask = 0xf,
	Fsmident = 0x0,
	Fsmdata	= 0x1,
	Fsmreaddata = 0x2,
	Fsmreadwait = 0x4,
	Fsmwrstart1 = 0xa,
	Edmforcedata = 1<<19,	/* force the FSM back to data mode */

	Edmrdthreshsh = 14,	/* SDEDM FIFO read/write thresholds */
	Edmwrthreshsh = 9,
	Edmthreshmask = 0x1f,

	/*
	 * The external DMA engine, which is what this controller is
	 * meant to be driven with.
	 *
	 * Linux runs the Pi 3's OTHER SD controller, the Arasan at
	 * 0x3f300000, in PIO: sdhci-iproc.c gives it missing_caps and
	 * supplies capabilities with neither CAN_DO_SDMA nor
	 * CAN_DO_ADMA2.  The engine is what it uses HERE --
	 * bcm2835-sdhost.c takes a dmaengine channel -- and the device
	 * tree says which line:
	 *
	 *	&sdhost { dmas = <&dma (13|(1<<29))>; };
	 *
	 * so DREQ 13, against SDDATA as a bus master sees it.  The FIFO
	 * thresholds sdhostinit already programs, 4 and 4, are the same
	 * FIFO_READ_THRESHOLD and FIFO_WRITE_THRESHOLD that driver uses.
	 */
	Sdhostdreq = 13,		/* the DREQ this controller raises */
	Sddatabus = 0x7e202040,		/* SDDATA, as a bus master sees it */

	Idclock	= 400000,	/* card identification clock */
	Datclock = 25000000,	/* after identification */
	Cdivmax	= 0x7ff,

	Maxretry = 8,		/* re-issues of a command that never started */
	Piowaitus = 1000000,	/* how long a PIO write may wait for FIFO room */
	/*
	 * When to nudge a read that has not started.  The old code did
	 * this on iteration 2000 of a 20000-iteration spin -- a tenth of
	 * the way through whatever that spin happened to be worth.  Two
	 * milliseconds is the same intent stated in time.
	 */
	Readnudgeus = 2000,
	/*
	 * How long a PIO read may wait for the next data.
	 *
	 * Not the same number as Piowaitus, and for a reason.  A write
	 * waits on the CARD, which the SD specification allows 250ms to
	 * program a block, so a second there is generous-but-legal.  A
	 * read waits on data the card has already been told to send;
	 * its access time is tens of milliseconds at worst.  Waiting a
	 * second for it buys nothing and costs a great deal when the
	 * answer is never coming:
	 *
	 *	READSPEED 0 of 6 blocks in 9090 ms
	 *
	 * -- one second times eight retries, spent on sectors the card
	 * genuinely could not read.  Two hundred milliseconds is still
	 * several times any legal access time and turns that nine
	 * seconds into under two.
	 */
	Readwaitus = 200000,
	Pioburst = 8,		/* words written between SDEDM reads */
	Fifofillsh = 4,		/* SDEDM bits 8:4: words currently in the FIFO */
	Fifofillmask = 0x1f,
	Fifodepth = 16,		/* BCM2835 SDHOST data FIFO is 16 words deep */

	Secsize	= 512,
	Alt0	= 4,		/* GPIO fsel selecting the SDHOST SD pins */
};

typedef struct Ctlr Ctlr;
struct Ctlr {
	QLock;			/* serialise bio across concurrent procs */
	volatile u32* r;	/* every register access must reach the SoC */
	uvlong	sectors;
	int	byteaddr;
	int	inited;
	int	errors;
	int	bytemode;	/* the data register hands over a byte per read */
	int	bmset;		/* ... and bytemode has been decided */
	ulong	fclk;
	uint	rca;
};

static Ctlr sdctlr;
extern SDifc sdhostbcmifc;

/*
 * Issue a command and wait for the controller to finish it.  QEMU's model
 * completes a command inside the register write, so the original driver
 * read SDRSP0 straight back and worked there; a real SDHOST clears
 * NEW_FLAG when the command is done, sets FAIL_FLAG when it failed, and
 * says why in SDHSTS.  Without the wait the response read is whatever the
 * previous command left, which is why the Pi found no card at all.
 * Returns 0, or -1 with the SDHSTS error bits in *errp.
 */
static int
sdcmdstart(volatile u32 *r, int cmd, u32 arg, int flags)
{
	int i;

	for(i = 0; i < 100000; i++)		/* previous command still running? */
		if((r[SDCMD] & Newflag) == 0)
			break;
	if(r[SDCMD] & Newflag)
		return -1;
	r[SDHSTS] = Hstsclear;
	r[SDARG] = arg;
	r[SDCMD] = cmd | flags | Newflag;
	return 0;
}

static int
sdcmdwait(volatile u32 *r, u32 *errp)
{
	int i;
	u32 sts;

	for(i = 0; i < 100000; i++)
		if((r[SDCMD] & Newflag) == 0)
			break;
	if(r[SDCMD] & Newflag){
		if(errp != nil)
			*errp = r[SDHSTS] & Hstserror;
		return -1;
	}
	sts = r[SDHSTS] & Hstserror;
	if(errp != nil)
		*errp = sts;
	if(r[SDCMD] & Failflag)
		return -1;
	/*
	 * A CRC7 error on the R3 responses (ACMD41, CMD58) is expected: the
	 * card does not compute one for them.  Every other error is real.
	 */
	if(sts & ~(u32)Hstscrc7)
		return -1;
	return 0;
}

static int
sdcmderr(volatile u32 *r, int cmd, u32 arg, int flags, u32 *errp)
{
	if(errp != nil)
		*errp = 0;
	if(sdcmdstart(r, cmd, arg, flags) < 0)
		return -1;
	return sdcmdwait(r, errp);
}

/* The same, for the callers that only want the response word. */
static u32
sdcmd(volatile u32 *r, int cmd, u32 arg, int flags)
{
	sdcmderr(r, cmd, arg, flags, nil);
	return r[SDRSP0];
}

/*
 * Card clock: SDHOST divides the VPU core clock by (SDCDIV+2).  The
 * firmware knows the core rate (config.txt pins core_freq=250, but ask).
 */
static void
sdhostclock(volatile u32 *r, ulong fclk, ulong want)
{
	ulong div;

	if(fclk == 0)
		fclk = 250000000;
	div = fclk / want;
	if(div < 2)
		div = 2;
	if(fclk / div > want)
		div++;
	div -= 2;
	if(div > Cdivmax)
		div = Cdivmax;
	r[SDCDIV] = div;
}

/*
 * Power-cycle and reset the controller, as Linux's bcm2835-sdhost does
 * before identification: FIFO thresholds, power off, config and divisor
 * while it is down, then power on.  QEMU needs none of this.
 */
/*
 * Extra SDHCFG bits held across every write of that register: the
 * bus-width bits, set from ctl.  See sdhostreset().
 */
/*
 * How many blocks the retry below has had to re-issue, and how many
 * were abandoned after Maxretry attempts.  A failure report that does
 * not say this cannot tell "the retry never fired" from "it fired four
 * times and the block still would not come", and those want opposite
 * fixes.
 */
static ulong sdhostretried, sdhostgaveup;
static u32 sdhostcfg = 0;
/*
 * Four data lines, and the two SDHCFG bits that go with them.
 *
 * This is what makes the controller hand over whole words.  With one
 * line and the bits clear, every access to SDDATA moves a single byte
 * however wide the access is -- reads returned the same 32-bit window
 * smeared a byte at a time, writes delivered a quarter of a block and
 * stalled, and DMA, which can only do 32-bit accesses, moved 128 bytes
 * of every 512.  A whole bytemode was built around that.
 *
 * Setting WIDE_INT_BUS by itself does not fix it; it stops the data
 * phase entirely (SDHBCT untouched at 512, FIFO empty, no error bit),
 * which a host-side width bit could not do.  The three go together:
 * ACMD6 tells the CARD to use four lines, WIDE_EXT_BUS tells the
 * controller the same about DAT1-3, and WIDE_INT_BUS widens the path
 * to SDDATA.  With all three the bytemode probe comes back 0 -- block
 * 0 read 32 bits at a time ends 55 aa -- and DMA works.
 */
static int sdhostwide = 1;
/*
 * Blocks per command.
 *
 * This driver issued one CMD17 or CMD24 per 512-byte block, each with
 * a CMD13 status poll in front of it and a 1ms settling delay after
 * it.  That delay alone caps the path near 500KB/s, and measured it
 * ran at 170KB/s raw and 25KB/s through dosfs -- so copying a 1.9MB
 * kernel took minutes.  A card at this clock on four lines should do
 * megabytes a second; the transfer was never the cost, the per-block
 * ceremony was.
 *
 * CMD18 and CMD25 carry as many blocks as SDHBLC says in ONE data
 * phase, with one command, one poll and one delay, finished with a
 * CMD12.  Default 1, which is exactly the old behaviour, so this can
 * be turned up on the board and measured rather than assumed.
 */
/*
 * Sixty-four blocks per command, and multi-block writes on, both
 * VERIFIED rather than assumed.
 *
 * The first attempt at this defaulted to 128 on the strength of
 * readspeed, which timed the transfer and never looked at a byte of
 * it.  multiverify -- write N blocks in one request, read them back in
 * one, compare -- then said MISMATCH, so the 27x was 27x of the wrong
 * data.  Two real faults were underneath:
 *
 *   - a multi-block read overran the FIFO after eight blocks
 *     (first bad byte 4092, sdhsts 0x8), and every error path left
 *     the card mid-stream because it skipped the CMD12 that ends a
 *     CMD18 or CMD25, which poisoned every transfer after it;
 *   - the bounded retry re-issued the command immediately, which is
 *     not a retry but the same failure N times: "retried 4 blocks,
 *     gave up on 1".  It backs off by the settling delay now.
 *
 * With those fixed, measured on the board and byte-compared:
 *
 *	64 blocks,  1 per command:  write 270ms read 60ms
 *	64 blocks, 64 per command:  write 270ms read 10ms
 *	64 blocks, 64, multiwrite:  write  10ms read  0ms
 *	512 blocks (256KB), 64:     write  70ms read 30ms
 *
 * 27x on writes and better on reads, every byte checked.
 *
 * DMA is NOT part of this: "multi 64 dma 1" still fails, and PIO at
 * 64 blocks a command is fast enough that the engine has nothing left
 * to offer here.  It stays behind "echo dma 1" with its own note.
 */
static int sdhostmulti = 64;
/*
 * CMD25 for writes.  It was held off until "multiverify" proved a
 * multi-block write puts the right bytes down -- a read that goes
 * wrong is a wrong answer, a write that goes wrong is a damaged card
 * -- and it now does, on every boot, before kupdate runs.
 */
static int sdhostmultiwrite = 1;

static void
sdhostreset(volatile u32 *r, ulong fclk)
{
	u32 edm;

	edm = r[SDEDM];
	edm &= ~(u32)((Edmthreshmask<<Edmrdthreshsh)|(Edmthreshmask<<Edmwrthreshsh));
	edm |= (4<<Edmrdthreshsh) | (4<<Edmwrthreshsh);
	r[SDEDM] = edm;
	delay(20);
	r[SDVDD] = 0;				/* power off */
	delay(20);
	r[SDCMD] = 0;
	r[SDARG] = 0;
	r[SDTOUT] = 0xf00000;
	r[SDCDIV] = 0;
	r[SDHSTS] = Hstsclear;
	r[SDHCFG] = 0;
	r[SDHBCT] = 0;
	r[SDHBLC] = 0;
	delay(20);
	r[SDVDD] = 1;				/* power on */
	delay(20);
	/*
	 * SLOW_CARD, and the two interrupt enables Linux keeps set.
	 *
	 * This driver polls, so "interrupt enable" reads like something
	 * it does not need -- and that reasoning is what left SDHCFG at
	 * 0x8 while every transfer failed with the command completing
	 * and no data phase starting, fifodata() timing out on Hstsdata
	 * that never set.  bcm2835-sdhost keeps SDHCFG_DATA_IRPT_EN and
	 * SDHCFG_BUSY_IRPT_EN set for PIO and drops only DATA_IRPT_EN
	 * for DMA, which is not the shape of a bit that merely routes an
	 * interrupt to the CPU.
	 *
	 * The Arasan taught the same lesson one register along: its
	 * irpt_mask gates whether a condition reaches the status
	 * register at all, so polling a status bit whose mask is clear
	 * waits for ever.
	 */
	/*
	 * The bus-width bits, and what is known about them.
	 *
	 * bcm2835-sdhost sets WIDE_INT_BUS unconditionally in set_ios
	 * and WIDE_EXT_BUS only for a 4-bit card, so the obvious first
	 * experiment was WIDE_INT_BUS alone.  It was run, on the board,
	 * and it did not do what the name suggests:
	 *
	 *	sdhcfg 0x41a, read block 0 failed, sdhsts 0x0
	 *	sdcmd 0x51 sdedm 0x10801 (fsm 1 fill 0) sdhbct 512
	 *
	 * SDHBCT untouched at 512 with the FIFO empty and no error bit
	 * means nothing arrived from the CARD at all.  A bit that only
	 * set the width of a host-side SDDATA access could not do that:
	 * the data would still have come and merely been read wrong,
	 * and SDHBCT would have counted down.  So WIDE_INT_BUS alone
	 * stops the data phase, and the one-byte-per-access behaviour
	 * this driver works around is not simply its absence.
	 *
	 * Both bits are therefore runtime, off by default, so that the
	 * combination Linux actually reaches -- ACMD6 telling the card
	 * to use four lines, and then both bits together -- can be
	 * tried on a booted kernel without a rebuild, and so a failed
	 * experiment does not cost the boot.
	 */
	r[SDHCFG] = Cfgslowcard | Cfgdataint | Cfgbusyint | sdhostcfg;
	sdhostclock(r, fclk, Idclock);
	delay(20);
}

/*
 * FIFO flow control.  On the real BCM2835 SDHOST the data FIFO drains to
 * (or fills from) the card at SD-clock speed, asynchronously to the CPU:
 * a write must wait for space and a read must wait for a word, or the
 * transfer under/overruns.  The emulator drains the FIFO synchronously on
 * every SDDATA access, so the fill level is always 0 there and these
 * polls fall straight through - but they are what a physical Pi needs, so
 * they belong here (AGENTS.md: hardware correctness over emulator-pass).
 * Bounded so a wedged controller cannot spin the kernel forever.
 */
static int
fifofill(volatile u32 *r)
{
	return (r[SDEDM] >> Fifofillsh) & Fifofillmask;
}

/*
 * Whether to let the engine move the data.  Off until it is measured
 * on the board beside the loop it replaces, the same way every other
 * switch in this port starts: "echo dma 1 >/dev/sdH0/ctl".
 *
 * Reads are only offered when the controller is handing over whole
 * words.  On real silicon it does not -- c->bytemode, where successive
 * reads return the same 32-bit window shifted by one byte -- and a
 * 32-bit DMA read from a register behaving that way would collect the
 * shifted windows, not the sector.  So bytemode reads stay on the byte
 * loop that was written for them.
 */
/*
 * DMA on, measured.
 *
 * This was 0 because of the "Arasan DMA write stall", and that stall was
 * falsified: it was a 1e6-iteration spin count expiring inside a card's
 * legal 250ms program time, with the engine resuming at 81ms and the
 * transfer completing.  So the flag was resting on a fault that does not
 * exist.  Re-tested with the wrverify and multiverify ctls, four
 * interleaved pairs of 512KB so that drift cannot favour either arm:
 *
 *	read   dma 0: 90 90 90 90 ms     dma 1: 70 60 60 60 ms
 *	write  dma 0: 90 90 110 110 ms   dma 1: 90 80 80 90 ms
 *
 * Every DMA run beat every PIO run on reads -- 5.7MB/s to 8.5MB/s -- and
 * writes move about 1.15x.  It costs nothing: a DMA failure sets this
 * back to 0 further down and the transfer is retried in PIO, so the
 * worst case is the behaviour that was the default before.
 *
 * What this is NOT is the multiplier it was expected to be.  The block
 * path was already doing 5-6MB/s; a 400KB file written through dossrv
 * onto the FAT partition takes 3.4 seconds, which is 118KB/s, and with
 * DMA on it takes 3.1, which is 129KB/s.  Nine percent.  Whatever costs
 * a factor of forty-five lives above the block device, not in it.
 */
static int sdhostdma = 1;
static int sdhosttrace = 0;	/* print the state at command issue */
/*
 * Microseconds between issuing a data command and the FIRST read of
 * SDHSTS.  1000 because that is where the threshold is, measured:
 *
 *	delay 0us:    read block 0 failed (sdhsts 0x8, Failflag)
 *	delay 200us:  read block 0 failed
 *	delay 1000us: 10+0 records out
 *	delay 5000us: 10+0 records out
 *
 * It is the first read that matters, not the rate of reading: pacing
 * the poll loop at one microsecond a read still reads at t=0 and
 * still fails, while waiting 1ms and then polling flat out works.
 * Something about touching that register while the data phase is
 * starting aborts it, and this is a characterisation rather than an
 * explanation -- 1ms a block caps this path around 500KB/s, so it
 * wants replacing with a wait for whatever the real condition is.
 */
static int sdhostdelay = 1000;	/* us before the first poll of SDHSTS */

extern uvlong systmrread(void);		/* systmrbcm.c, the 1MHz free counter */

static int
fifospace(volatile u32 *r)			/* wait until the FIFO can take a word */
{
	int i;

	for(i = 0; i < 1000000; i++)
		if(fifofill(r) < Fifodepth)
			return 1;
	return 0;
}

/*
 * Wait until a whole word can be read.  SDHSTS's data flag (bit 0) is the
 * gate: on the Pi, gating on SDEDM's fill level instead returned the same
 * word again and again as its bytes arrived (fa000000, b8fa0000,
 * 00b8fa00, 1000b8fa for an MBR beginning fa b8 00 10), so that counter
 * does not mean a word is ready.  The fill level is still watched, as the
 * controller can present data without the flag.
 */
static int
fifodata(volatile u32 *r)
{
	u32 edm;
	uvlong t0, dt;
	int nudged;

	/*
	 * Do NOT force data mode from the fast path.
	 *
	 * This loop used to read SDEDM every iteration and, whenever it
	 * saw READWAIT, write FORCE_DATA_MODE back.  That is a write
	 * into the controller's state machine thousands of times a
	 * microsecond while a transfer is starting, and it broke every
	 * read: the command came back with Failflag set and SDHSTS
	 * reporting a FIFO error --
	 *
	 *	sdhost: read block 0 failed: sdhsts 0x8 sdcmd 0x4051
	 *
	 * 0x8 being Hstsfifo and 0x4000 Failflag.  It was found by
	 * accident: a trace print between issuing the command and
	 * entering this loop made every read succeed, and toggling only
	 * that print, in one boot, is the whole experiment --
	 *
	 *	trace 1:  10+0 records out
	 *	trace 0:  read block 0 failed, 0+0 records out
	 *
	 * The print was not fixing anything; it was delaying this loop
	 * until the FSM had left READWAIT, so the force never fired.
	 *
	 * Linux's bcm2835-sdhost uses FORCE_DATA_MODE only in specific
	 * recovery, never in a poll.  So: poll the status bit, and only
	 * if the FSM is still stuck in READWAIT after a long wait
	 * nudge it once, which is what the bit is for.
	 */
	/*
	 * PACE THE POLL.  Reading SDHSTS flat out is what broke reads.
	 *
	 * A delay before this loop made reads work and the threshold is
	 * sharp -- 0 and 200us fail, 1000us and 5000us pass -- but a
	 * delay cannot be the explanation on its own, because this loop
	 * already spends far longer than that spinning.  Waiting 1ms
	 * here and waiting 1ms before getting here differ in exactly one
	 * thing: whether the status register is being read a few million
	 * times while it happens.
	 *
	 * So the reads are the problem, not the time.  Hammering SDHSTS
	 * during the data phase produced Hstsfifo and Failflag --
	 *
	 *	sdhost: read block 0 failed: sdhsts 0x8 sdcmd 0x4051
	 *
	 * and pausing between reads is the fix that follows from that,
	 * rather than padding the front with a blind millisecond.
	 */
	/*
	 * A CLOCK, not a spin count.
	 *
	 * This was "for(i = 0; i < 20000; i++) microdelay(1)" -- twenty
	 * thousand iterations of a delay that is at least a microsecond
	 * and, with the register read beside it, rather more.  Call it
	 * twenty to forty milliseconds, and it is a property of this
	 * kernel's microdelay rather than of anything the card promises.
	 *
	 * The card is allowed to pause much longer than that in the
	 * middle of a read, and under load it does.  The failure is
	 * unmistakable once the number is read for what it is:
	 *
	 *	read block 61213 failed: sdhsts 0x0 ... sdhbct 6 sdhblc 6
	 *
	 * SDHBCT counts DOWN, so six is six bytes short of finishing a
	 * block -- the data phase had been running and stopped, not
	 * failed to start.  No error bit anywhere, the FSM back in
	 * DATAMODE, the card idle in TRAN: nobody did anything wrong,
	 * this end simply stopped waiting first, and then retried eight
	 * times with the same too-short bound and gave up.  dosfs took
	 * the short read as a fault and panicked, which is how one
	 * hesitating card block killed the board's filesystem.
	 *
	 * The DMA engine's Timeout and the write side's FIFO wait were
	 * both this same bug and were both converted to the 1MHz system
	 * timer; this was the one left counting iterations.
	 */
	t0 = systmrread();
	nudged = 0;
	for(;;){
		if((r[SDHSTS] & Hstsdata) != 0)
			return 1;
		microdelay(1);
		dt = systmrread() - t0;
		if(!nudged && dt > Readnudgeus){
			/* genuinely stuck, not starting */
			edm = r[SDEDM];
			if((edm & Edmfsmmask) == Fsmreadwait)
				r[SDEDM] = edm | Edmforcedata;
			nudged = 1;
		}
		if(dt > Readwaitus)
			break;
	}
	return 0;
}

/*
 * Wait for the data phase to end.  The controller's FSM stays in a data
 * state after the last word has moved, and a command issued while it is
 * there never starts: on the Pi the first read after boot worked and
 * every read after it returned nothing.  As in Linux's bcm2835-sdhost,
 * identification and data mode mean done, and the states still waiting
 * on the card are forced back to data mode.
 */
static int
waitxfer(volatile u32 *r)
{
	u32 edm, fsm;
	int i;

	for(i = 0; i < 1000000; i++){
		edm = r[SDEDM];
		fsm = edm & Edmfsmmask;
		if(fsm == Fsmident || fsm == Fsmdata)
			return 1;
		if(fsm == Fsmreadwait || fsm == Fsmwrstart1 || fsm == Fsmreaddata){
			r[SDEDM] = edm | Edmforcedata;
			return 1;
		}
	}
	return 0;
}

/*
 * Native SD bring-up.  Returns 1 with the card selected and sized, or 0
 * if no card responds.
 */
/*
 * On real silicon this controller hands the data register over one
 * byte at a time.  Read block 0 both ways and let the MBR signature
 * settle it, rather than defaulting to a guess.
 *
 * The word loop collects the same 32-bit window shifted a byte at a
 * time.  Block 0 of this card, taken both ways:
 *
 *   word: faaa5500b8faaa5500b8faaa1000b8fa8e1000b8d08e1000bcd08e1000bcd08e
 *   byte: fab800108ed0bc00b0b800008ed88ec0fbbe007cbf0006b90002f3a4ea210600
 *
 * The second is an x86 boot sector and ends 55 aa at 510; the first is
 * the same bytes smeared.  QEMU's model hands over whole words, so
 * both are needed and neither can be assumed.
 */
static long sdhostbio(SDunit*, int, int, void*, long, uvlong);

static void
pickbytemode(SDunit *u, Ctlr *c)
{
	uchar b[Secsize];
	int m, i, first;

	/*
	 * Try the mode the configuration implies first.  On four lines
	 * with the SDHCFG width bits set the data register hands over
	 * whole words, so probing bytemode first only prints a failed
	 * read that means nothing.
	 */
	c->bmset = 1;			/* before the probing reads, not after */
	first = sdhostcfg? 0: 1;
	for(i = 0; i < 2; i++){
		m = i? !first: first;
		c->bytemode = m;
		memset(b, 0, sizeof b);
		if(sdhostbio(u, 0, 0, b, 1, 0) == Secsize &&
		    b[Secsize-2] == 0x55 && b[Secsize-1] == 0xaa){
			c->bmset = 1;
			print("sdhost: bytemode %d (block 0 ends 55 aa)\n", m);
			return;
		}
	}
	c->bytemode = first;
	print("sdhost: bytemode %d by default; block 0 had no 55 aa either way\n",
		first);
}

static int
sdcardinit(Ctlr *c)
{
	volatile u32 *r = c->r;
	u32 ocr, csd[4], err;
	int i, rbl, cmult;
	uvlong cap;
	ulong fclk;
	u32 clk;
	uchar b[16];
	extern int mboxgetclock(int, u32*);

	/* route the SD card from the default SDHCI to SDHOST */
	for(i = 48; i <= 53; i++)
		gpiofsel(i, Alt0);

	if(mboxgetclock(4, &clk) < 0)		/* VPU core clock */
		clk = 0;
	fclk = clk;
	c->fclk = fclk;
	sdhostreset(r, fclk);

	if(sdcmderr(r, 0, 0, Noresp, &err) < 0){	/* CMD0 GO_IDLE */
		print("sdhost: CMD0 failed, sdhsts %#lux cmd %#lux\n",
			(ulong)err, (ulong)r[SDCMD]);
		return 0;
	}
	delay(2);
	if(sdcmderr(r, 8, 0x1aa, 0, &err) < 0 || (r[SDRSP0] & 0xff) != 0xaa){
		print("sdhost: no card answering CMD8 (rsp %#lux sdhsts %#lux)\n",
			(ulong)r[SDRSP0], (ulong)err);
		return 0;			/* no v2 card answering */
	}
	ocr = 0;
	for(i = 0; i < 100; i++){		/* ACMD41 init loop, up to ~1s */
		if(sdcmderr(r, 55, 0, 0, &err) < 0)
			continue;
		if(sdcmderr(r, 41, 0x40ff8000, 0, &err) < 0)
			continue;
		ocr = r[SDRSP0];
		if(ocr & 0x80000000)
			break;
		delay(10);
	}
	if(!(ocr & 0x80000000)){
		print("sdhost: card never left idle (ocr %#lux)\n", (ulong)ocr);
		return 0;
	}
	c->byteaddr = (ocr & 0x40000000)? 0: 1;	/* CCS: 1 = block-addressed */

	if(sdcmderr(r, 2, 0, Longresp, &err) < 0){	/* CMD2 ALL_SEND_CID */
		print("sdhost: CMD2 failed, sdhsts %#lux\n", (ulong)err);
		return 0;
	}
	if(sdcmderr(r, 3, 0, 0, &err) < 0){	/* CMD3 SEND_RELATIVE_ADDR */
		print("sdhost: CMD3 failed, sdhsts %#lux\n", (ulong)err);
		return 0;
	}
	c->rca = r[SDRSP0] >> 16;

	if(sdcmderr(r, 9, c->rca<<16, Longresp, &err) < 0){	/* CMD9 SEND_CSD */
		print("sdhost: CMD9 failed, sdhsts %#lux\n", (ulong)err);
		return 0;
	}
	csd[0] = r[SDRSP3];			/* csd[0..3]  (big-endian in the word) */
	csd[1] = r[SDRSP2];			/* csd[4..7]  */
	csd[2] = r[SDRSP1];			/* csd[8..11] */
	csd[3] = r[SDRSP0];			/* csd[12..15]*/
	for(i = 0; i < 4; i++){
		b[i*4+0] = csd[i]>>24;
		b[i*4+1] = csd[i]>>16;
		b[i*4+2] = csd[i]>>8;
		b[i*4+3] = csd[i];
	}
	if((b[0]>>6) == 0){			/* CSD v1 (SDSC) */
		rbl = b[5] & 0x0f;
		cap = ((b[6]&3)<<10) | (b[7]<<2) | (b[8]>>6);
		cmult = ((b[9]&3)<<1) | (b[10]>>7);
		c->sectors = (cap+1) << (cmult+2+rbl-9);
	}else{					/* CSD v2 (SDHC) */
		cap = ((uvlong)(b[7]&0x3f)<<16) | (b[8]<<8) | b[9];
		c->sectors = (cap+1) << 10;
	}

	if(sdcmderr(r, 7, c->rca<<16, Busywait, &err) < 0){	/* CMD7 SELECT */
		print("sdhost: CMD7 select failed, sdhsts %#lux\n", (ulong)err);
		return 0;
	}
	if(sdcmderr(r, 16, Secsize, 0, &err) < 0){	/* CMD16 SET_BLOCKLEN */
		print("sdhost: CMD16 failed, sdhsts %#lux\n", (ulong)err);
		return 0;
	}
	/*
	 * Four lines, once the card is selected.  ACMD6 first, then the
	 * controller, and never one without the other: a card on four
	 * lines talking to a controller expecting one is unreadable, and
	 * so is the reverse.  If the card refuses, stay on one line
	 * rather than leave the two disagreeing.
	 */
	sdhostcfg = 0;
	if(sdhostwide){
		if(sdcmderr(r, 55, c->rca<<16, 0, &err) < 0 ||
		    sdcmderr(r, 6, 2, 0, &err) < 0)
			print("sdhost: ACMD6 4-bit refused, sdhsts %#lux;"
				" staying on one line\n", (ulong)err);
		else
			sdhostcfg = Cfgwideext|Cfgwideint;
	}
	r[SDHCFG] = Cfgslowcard | Cfgdataint | Cfgbusyint | sdhostcfg;
	sdhostclock(r, fclk, Datclock);		/* identification done: speed up */
	print("sdhost: card rca %#ux %s %llud sectors, core clock %lud Hz,"
		" %d-bit, sdhcfg %#lux\n",
		c->rca, c->byteaddr? "byte": "block", c->sectors, fclk,
		sdhostcfg? 4: 1, (ulong)r[SDHCFG]);
	return 1;
}

static SDev*
sdhostpnp(void)
{
	SDev *s;

	if((uintptr)SDHOST == 0)
		return nil;
	sdctlr.r = (volatile u32*)SDHOST;
	if((s = malloc(sizeof(*s))) == nil)
		return nil;
	s->ctlr = &sdctlr;
	s->idno = 'M';
	s->ifc = &sdhostbcmifc;
	s->nunit = 1;
	return s;
}

static int
sdhostverify(SDunit *u)
{
	USED(u);
	return 1;
}

static int
sdhostonline(SDunit *u)
{
	Ctlr *c = u->dev->ctlr;
	int first;

	first = 0;
	if(!c->inited){
		c->inited = 1;
		sdcardinit(c);		/* leaves c->sectors 0 if no card */
		first = 1;
	}
	if(c->sectors == 0)
		return 0;		/* no media */
	/*
	 * Always repopulate from the cached geometry: sdinitpart() zeroes
	 * unit->sectors before each call, so a re-init must restore them or
	 * the data partition vanishes ("file does not exist").  Report media
	 * change only on the first init - returning 2 every call would churn
	 * the partition version under an open channel.
	 */
	u->secsize = Secsize;
	u->sectors = c->sectors;
	/*
	 * Decide how the data register hands words over, now that there
	 * is a unit to read through and before anything reads for real.
	 * Not from sdhostbio: that holds the qlock this would re-enter.
	 */
	if(!c->bmset)
		pickbytemode(u, c);
	return first? 2: 1;
}

/*
 * FIXED (was: heavy write stream under the periodic tick failed
 * intermittently with "file does not exist"): the root cause was not in
 * this driver at all.  vectrap built the Ureg frame at SP and then
 * called trap(&ureg); Plan 9's arm64 convention gives the callee a stack
 * home for arg0 at caller-SP+8, which is exactly UR_R1, so trap()'s
 * prologue spilling its Ureg* argument overwrote the saved R1 on every
 * interrupt.  Usually R1 was dead so it went unnoticed; but a timer IRQ
 * landing in irestore's fixed-size R = p->R copy clobbered the live loop
 * counter, turning it into an unbounded copy that walked memory upward
 * from the global R (with the MMU off, silent corruption -> the "file
 * does not exist" symptom).  The one-line arg-home reservation in l.s's
 * vectrap fixes it, and the periodic tick is now enabled in clockinit;
 * see l.s and clock.c.
 */
/*
 * Wait for the card to be ready for the next transfer.  CMD13 SEND_STATUS
 * returns the card's state in bits 12:9 (4 = transfer) and "ready for
 * data" in bit 8.  On the Pi a read issued straight after another read
 * timed out with no response, while the card itself answered CMD13 from
 * the transfer state and a read issued after that CMD13 worked: the card
 * is still finishing the previous block when the next command goes out.
 * QEMU completes a transfer inside the register access and is always
 * ready.  Returns 0 if the card never reports itself ready.
 */
static int
cardready(Ctlr *c)
{
	volatile u32 *r = c->r;
	u32 st;
	int i;

	for(i = 0; i < 1000; i++){
		if(sdcmderr(r, 13, c->rca<<16, 0, nil) == 0){
			st = r[SDRSP0];
			if((st & (1<<8)) != 0 && ((st >> 9) & 0xf) == 4)
				return 1;
		}
		delay(1);
	}
	return 0;
}

/*
 * A transfer that fails returns short, which devsd turns into a zero-byte
 * read; say what the controller reported, at most a few times, so the
 * console shows which command and block died and why.
 */
/*
 * Put the card back where a retry can start from.
 *
 * The three retry sites below used to clear SDHSTS, rewind the buffer
 * pointer and jump straight back to the command issue.  That cannot
 * work after a multi-block transfer has begun: CMD18 puts the card into
 * the DATA state and it stays there, streaming, until a CMD12 stops it.
 * Re-issuing a read to a card that is still sending the last one fails
 * exactly the same way, so the retry loop ran its whole budget without a
 * chance of succeeding:
 *
 *	read block 61213 failed: sdhsts 0x0 ... sdhblc 6
 *	  card rsp 0xb00 (state 5, ready for data)
 *	  retried 10 blocks, gave up on 1
 *	dosfs: panic: read
 *
 * State 5 is DATA -- the card was still transmitting while the driver
 * decided it had given up.  The `out:` path had already learned this
 * lesson ("one failed read poisoned the card for everything that
 * followed") and sends CMD12; the retry path was never given the same
 * treatment, which is why more retries only bought more identical
 * failures.
 *
 * Stop the stream, then wait for TRAN before going round again.
 */
static void
exrewind(Ctlr *c, int multi)
{
	volatile u32 *r = c->r;
	u32 err;

	r[SDHSTS] = Hstsclear;
	if(multi)
		sdcmderr(r, 12, 0, Busywait, &err);	/* STOP_TRANSMISSION */
	r[SDHSTS] = Hstsclear;
	cardready(c);
}

/*
 * Is a stalled transfer worth re-issuing?
 *
 * It used to demand NO error bit at all, which excluded the one error
 * that is always safe to retry: Hstsfifo.  A multi-block read streams
 * continuously once CMD18 starts, and a PIO loop that falls behind
 * overruns the FIFO -- nothing was delivered to the caller, the card
 * is still in TRAN, and re-reading the same blocks returns the same
 * data.  Refusing to retry it cost a filesystem:
 *
 *	read block 37309 failed: sdhsts 0x8 ... sdhblc 6
 *	retried 8 blocks, gave up on 1
 *	dosfs: panic: read
 *
 * sdhsts 0x8 IS Hstsfifo, so the guard was false, the driver gave up
 * on the first try, and dosfs died on the error -- taking /n/dos and
 * everything above it with it.
 *
 * A CRC or timeout error is a different matter and still is not
 * retried here: those say the card disagreed, not that this end fell
 * behind.
 */
static int
exretryable(volatile u32 *r)
{
	u32 sts = r[SDHSTS] & Hstserror;

	if((r[SDEDM] & Edmfsmmask) != Fsmdata)
		return 0;
	if(sts == 0)
		return 1;
	return (sts & ~(u32)Hstsfifo) == 0;	/* FIFO overrun only */
}

static void
bioerror(Ctlr *c, int write, uvlong bno, u32 sts)
{
	if(c->errors++ > 5)
		return;
	/*
	 * The block registers too, because the failure is that the
	 * command completes and no data phase starts, and "SDHBLC was
	 * armed" has so far been an assumption rather than a reading.
	 * SDEDM's FSM and fill are broken out for the same reason: 1 is
	 * DATAMODE, 2 READDATA, 3 WRITEDATA, and a read that never
	 * leaves DATAMODE never began.
	 */
	print("sdhost: %s block %llud failed: sdhsts %#lux sdcmd %#lux "
		"sdedm %#lux (fsm %lud fill %lud) sdhbct %lud sdhblc %lud "
		"sdhcfg %#lux\n",
		write? "write": "read", bno, (ulong)sts, (ulong)c->r[SDCMD],
		(ulong)c->r[SDEDM],
		(ulong)(c->r[SDEDM] & Edmfsmmask),
		(ulong)((c->r[SDEDM] >> Fifofillsh) & Fifofillmask),
		(ulong)c->r[SDHBCT], (ulong)c->r[SDHBLC],
		(ulong)c->r[SDHCFG]);
	/*
	 * And the card's side of it.  SDRSP0 holds the R1 response to
	 * the command that is running, whose bits 12:9 are the card's
	 * state (4 is TRAN, 6 is RCV -- receiving data for a write) and
	 * bit 8 is READY_FOR_DATA.  The host side of the FIFO has been
	 * rewritten twice with no effect on the write stall, so the
	 * question is whether the card ever agreed to receive.
	 */
	print("sdhost:   card rsp %#lux (state %lud%s)\n",
		(ulong)c->r[SDRSP0], (ulong)((c->r[SDRSP0] >> 9) & 0xf),
		(c->r[SDRSP0] & (1<<8))? ", ready for data": "");
	print("sdhost:   retried %lud blocks, gave up on %lud\n",
		sdhostretried, sdhostgaveup);
}

static long
sdhostbio(SDunit *u, int lun, int write, void *a, long nb, uvlong bno)
{
	Ctlr *c = u->dev->ctlr;
	volatile u32 *r = c->r;
	uchar *p = a, *pblk;
	long i, nthis = 1;
	int j, retries, multi, multiwrite, usedma;
	uvlong t0;
	extern uvlong systmrread(void);		/* systmrbcm.c, 1MHz */
	u32 arg, w, err;

	USED(lun);
	qlock(c);
	/*
	 * Sample the switches ONCE, here, under the lock.
	 *
	 * sdhostmulti, sdhostmultiwrite and sdhostdma are globals that
	 * "echo ... >ctl" writes at any moment, and this loop read them
	 * fresh on every block.  So a transfer could start single-block
	 * and finish multi-block, or start in PIO and finish in DMA,
	 * and the failure report printed whatever the globals held by
	 * the time it ran rather than what the transfer actually did --
	 * which is how a run came to be logged as "multi 1" when the
	 * write had gone out at 128.  A result that cannot say what
	 * configuration produced it is not a result.
	 *
	 * One read each, into locals, and the report prints the locals.
	 */
	multi = sdhostmulti;
	multiwrite = sdhostmultiwrite;
	usedma = sdhostdma;
	retries = Maxretry;
	for(i = 0; i < nb; i += nthis){
		/*
		 * Where this block's data starts, so a retry can put it
		 * back.
		 *
		 * The retry below rewinds the block index and re-issues
		 * the command, and for a long time it did not rewind p.
		 * A first attempt that moved some bytes and then stalled
		 * therefore left p advanced, and the second attempt wrote
		 * a whole further block from there.  With Maxretry = 4
		 * that is up to 2560 bytes into a caller's 512-byte
		 * buffer, and pickbytemode's buffer is on the stack eight
		 * bytes below its caller's saved arguments: the overrun
		 * landed on the SDunit* and the next call through it took
		 * a translation fault on an address made of instruction
		 * bytes.  That crash only appeared once a probing read
		 * started failing, which is why it sat here unseen.
		 */
		pblk = p;
		nthis = nb - i;
		if(nthis > multi)
			nthis = multi;
		if(write && !multiwrite)
			nthis = 1;
		if(nthis < 1)
			nthis = 1;
		arg = c->byteaddr? (u32)((bno+i)*Secsize): (u32)(bno+i);
		/*
		 * The card's status FIRST, and only then the block
		 * registers.
		 *
		 * SDHBCT and SDHBLC are how this controller is told that
		 * the next command carries a data phase.  Armed, it waits
		 * for that phase; CMD13 does not have one, so the status
		 * poll below never completed and NEW_FLAG stayed set --
		 *
		 *	sdhost: read block 0 failed:
		 *	    sdhsts 0x1 sdcmd 0x800d sdedm 0x10803
		 *
		 * 0x800d being NEW_FLAG still set on command 13, with the
		 * FSM sitting in WRITEDATA on a read.  Every transfer
		 * failed this way, in both directions, with DMA off, so
		 * it was never the data path at all.
		 *
		 * Linux's bcm2835-sdhost sets these from prepare_data(),
		 * which runs only for commands that carry data.
		 */
		if(!cardready(c)){
			bioerror(c, write, bno+i, r[SDHSTS]);
			break;
		}
		/*
		 * Which of the data interrupts are enabled depends on who
		 * is moving the data, exactly as bcm2835-sdhost's
		 * set_transfer_irqs does: DATA and BUSY for the polled
		 * path, BUSY alone when the engine has it.
		 */
		/*
		 * Reads take the DATA interrupt, writes the BLOCK one.
		 *
		 * bcm2835-sdhost makes exactly this distinction, with the
		 * comment "use the block interrupt for writes": it clears
		 * DATA_IRPT_EN and sets BLOCK_IRPT_EN before pushing a
		 * write, where a read runs with DATA_IRPT_EN.  This
		 * driver used DATA for both.
		 *
		 * These bits are named as interrupt enables and this
		 * driver polls, so they ought not to matter -- except the
		 * read side has already shown that touching the status
		 * registers changes what the controller does, so "ought
		 * not to matter" is not evidence.  Writes stall 128 bytes
		 * in with the FSM in WRITEDATA, the card idle in TRAN and
		 * ready, and no error bit anywhere; the host side of the
		 * FIFO has been rewritten twice with no effect.  This is
		 * the one register difference from a driver that works.
		 */
		r[SDHCFG] = (r[SDHCFG] & ~(u32)(Cfgdataint|Cfgblockint)) |
			Cfgbusyint | sdhostcfg |
			(usedma? 0: (write? Cfgblockint: Cfgdataint));
		r[SDHBCT] = Secsize;
		r[SDHBLC] = nthis;
		/*
		 * WRITE_SINGLE_BLOCK / READ_SINGLE_BLOCK.  A data command is
		 * only started here, not waited for: on the Pi the controller
		 * keeps NEW_FLAG set through the data phase, and with the
		 * 16-word FIFO full it cannot finish until the words are moved
		 * (sdcmd 0x8051, FIFO full, FSM in READDATA).  Waiting first
		 * deadlocked every transfer after the first.
		 */
		err = 0;
		if(sdcmdstart(r, nthis > 1? (write? 25: 18): (write? 24: 17),
		    arg, write? Writecmd: Readcmd) < 0){
			bioerror(c, write, bno+i, r[SDHSTS]);
			break;
		}
		/*
		 * The state the instant the command is away, before any
		 * wait, because the failure report is taken after a
		 * timeout and cannot tell "the data phase never started"
		 * from "it started and stopped".  SDHBCT is written 512
		 * here and reads 6 by the time of the failure -- and the
		 * register does hold writes, checked by writing it over
		 * JTAG and reading 0x200 back -- so something between
		 * these two points changes it.
		 */
		/*
		 * A pause between issuing the command and polling.
		 *
		 * Not a workaround dressed as a setting: it is the whole
		 * of what made reads work.  A trace print here -- a
		 * console write, milliseconds -- turned every failing
		 * read into a passing one, and toggling only that print
		 * in one boot is the experiment:
		 *
		 *	trace 1:  10+0 records out
		 *	trace 0:  read block 0 failed, 0+0 records out
		 *
		 * The print fixes nothing; it delays the poll.  Removing
		 * the FORCE_DATA_MODE write from that poll did NOT help,
		 * so it is the waiting and not what the loop does while
		 * it waits.  This makes the delay explicit and tunable so
		 * the claim can be tested rather than inherited.
		 */
		if(sdhostdelay)
			microdelay(sdhostdelay);
		if(c->errors <= 3 && sdhosttrace)
			print("sdhost: issued %d blk %llud: sdcmd %#lux "
				"sdhsts %#lux sdedm %#lux (fsm %lud fill %lud) "
				"sdhbct %lud sdhblc %lud\n",
				write? 24: 17, bno+i, (ulong)r[SDCMD],
				(ulong)r[SDHSTS], (ulong)r[SDEDM],
				(ulong)(r[SDEDM] & Edmfsmmask),
				(ulong)((r[SDEDM] >> Fifofillsh) & Fifofillmask),
				(ulong)r[SDHBCT], (ulong)r[SDHBLC]);
		/*
		 * nthis blocks, not one.
		 *
		 * SDHBLC and the command above were set for nthis blocks --
		 * CMD18/CMD25 when nthis > 1 -- and the controller then
		 * streams all of them through the data FIFO, pacing the DMA
		 * with DREQ.  These two calls moved Secsize, ONE sector, and
		 * advanced p by one, while the loop advanced i by nthis.  So
		 * with multi at 64, one block in every 64 reached the
		 * caller's buffer, the other 63 positions kept whatever was
		 * in them, and the controller was left holding 63 blocks
		 * nobody collected.
		 *
		 * That is the "DMA paired with multi-block returns wrong
		 * data" in doc/raspi3b-completion-plan.ms.  It reproduces
		 * identically on a good card and a bad one, which is what
		 * said it was the driver rather than the medium.
		 *
		 * The length is safe: dmachannel() picks a channel below
		 * Nlite, which is a full engine with a 30-bit TXFR_LEN, and
		 * the most this can ask for is multi*512.
		 */
		if(write && usedma){
			if(dmaxfer(p, Sddatabus, nthis*Secsize, Sdhostdreq, 0) < 0){
				print("sdhost: DMA WRITE FAILURE block %llud: "
					"sdhsts %#lux sdedm %#lux fifo %d\n",
					bno+i, (ulong)r[SDHSTS],
					(ulong)r[SDEDM], fifofill(r));
				dmachanreset();
				bioerror(c, write, bno+i, r[SDHSTS]);
				sdhostdma = 0;	/* fall back, do not lose it */
				goto out;
			}
			p += nthis*Secsize;
		}else if(!write && usedma && !c->bytemode){
			if(sdhosttrace)
				print("sdhost: DMA READ PATH nthis %ld len %ld\n",
					nthis, nthis*Secsize);
			if(dmaxfer(p, Sddatabus, nthis*Secsize, Sdhostdreq, 1) < 0){
				print("sdhost: DMA READ FAILURE block %llud: "
					"sdhsts %#lux sdedm %#lux fifo %d\n",
					bno+i, (ulong)r[SDHSTS],
					(ulong)r[SDEDM], fifofill(r));
				dmachanreset();
				bioerror(c, write, bno+i, r[SDHSTS]);
				sdhostdma = 0;
				goto out;
			}
			p += nthis*Secsize;
		}else if(write){
			/*
			 * Write in bursts, reading SDEDM once per burst.
			 *
			 * This used to call fifospace() -- which spins on
			 * SDEDM -- before every single word, and writes
			 * stalled 128 bytes in with the FSM left in
			 * WRITEDATA and the next command unable to start:
			 *
			 *	sdhost: write block 2049 failed: sdhsts 0x1
			 *	    sdedm 0x10803 (fsm 3 fill 0) sdhbct 384
			 *
			 * The read side taught the same lesson: touching
			 * the status registers during the data phase
			 * disturbs the transfer, and reads only worked
			 * once the first poll was held off.
			 *
			 * bcm2835-sdhost reads SDEDM once per burst of
			 * eight words and, when there is not room, waits a
			 * time proportional to the shortfall rather than
			 * spinning.  That is what this does.
			 */
			{
			int words, burst, k;

			/*
			 * In bytemode the data register takes ONE BYTE per
			 * write, exactly as it gives one byte per read.
			 *
			 * The arithmetic is what says so.  The word loop
			 * wrote Secsize/4 = 128 words and the controller
			 * counted 128 BYTES: sdhbct went 512 -> 384, and
			 * 384 is what remains when 128 of 512 have
			 * arrived.  So every 32-bit write delivered a
			 * single byte, the loop ran out of data with three
			 * quarters of the block still wanted, and the
			 * transfer stalled with the FSM in WRITEDATA and
			 * the card sitting in TRAN wondering where the
			 * rest was.
			 *
			 * That also explains why nothing on the host side
			 * helped: bursting, pacing and delaying all change
			 * WHEN the words go, and the problem was that each
			 * one carried a quarter of what it looked like.
			 */
			/*
			 * Wait for FIFO space by the CLOCK, not by a
			 * spin count.
			 *
			 * This gave up after 20000 rounds of an ~8us
			 * delay -- about 160ms -- and under contention
			 * that is not enough.  With another process
			 * reading the same card, a multi-block write
			 * stalled with the FIFO full and the FSM in
			 * WRITEWAIT1:
			 *
			 *	sdhsts 0x0 sdedm 0x10907 (fsm 7 fill 16)
			 *
			 * No error bit anywhere: the card was simply
			 * busy programming and had not drained yet, and
			 * the SD specification allows it 250ms to do
			 * that.  The whole 128KB request was refused,
			 * "write 0 of 131072", on both concurrent runs.
			 *
			 * This is the same fault as the DMA engine's
			 * Timeout, found and fixed in the same week: a
			 * bounded spin standing in for a timeout, whose
			 * length is a property of the machine rather
			 * than of the hardware it waits for, and shorter
			 * than a card's legal program time.  A second,
			 * by the 1MHz counter.
			 */
			j = (c->bytemode? Secsize: Secsize/4) * nthis;
			t0 = systmrread();
			while(j > 0){
				words = Fifodepth -
					(int)((r[SDEDM] >> Fifofillsh) &
					      Fifofillmask);
				burst = Pioburst;
				if(burst > j)
					burst = j;
				if(words < burst){
					if(systmrread() - t0 > Piowaitus){
						if(exretryable(r) && retries-- > 0){
							sdhostretried++;
							microdelay(sdhostdelay *
								(Maxretry - retries));
							exrewind(c, nthis > 1);
							p = pblk;
							i -= nthis;
							goto again;
						}
						sdhostgaveup++;
						bioerror(c, write, bno+i,
							r[SDHSTS]);
						goto out;
					}
					microdelay(burst - words);
					continue;
				}
				t0 = systmrread();	/* progress: restart the clock */
				if(words > j)
					words = j;
				if(c->bytemode)
					for(k = 0; k < words; k++)
						r[SDDATA] = *p++;
				else
					for(k = 0; k < words; k++){
						r[SDDATA] = p[0] | p[1]<<8 |
							p[2]<<16 | p[3]<<24;
						p += 4;
					}
				j -= words;
			}
			}
		}else if(c->bytemode){
			/*
			 * One byte per read.  The Pi hands the data register
			 * over a byte at a time: successive reads returned the
			 * same 32-bit window shifted by one byte (000000fa,
			 * 0000fab8, 00fab800, fab80010 for a sector beginning
			 * fa b8 00 10), and with a pause between reads the
			 * value froze, the controller stalling until drained.
			 * Taking the newest byte, the low one, from each read
			 * is what the silicon actually offers; SDEDM's fill
			 * level stays 0 throughout and cannot pace it.
			 */
			for(j = 0; j < Secsize*nthis; j++){
				if(!fifodata(r)){	/* wait for data */
					/*
					 * If the data phase never began --
					 * FSM still in DATAMODE, no error
					 * bit, nothing in the FIFO -- then
					 * nothing was transferred and the
					 * card, asked, is idle in TRAN.
					 * Re-issuing the command is safe,
					 * and it is what turns an
					 * intermittent abort into a pause.
					 *
					 * This happens under sustained load
					 * despite the 1ms first-poll delay
					 * (block 36864 of the 1.5MB test),
					 * so that delay is necessary and not
					 * sufficient, and the race it papers
					 * over is still unexplained.  A
					 * bounded retry is honest recovery
					 * from a command that demonstrably
					 * did not take effect; it is not a
					 * substitute for knowing why.
					 */
					if(exretryable(r)){
						if(retries-- > 0){
							/*
							 * Wait before re-issuing.
							 *
							 * The first version retried
							 * immediately and it did not
							 * help: "retried 4 blocks,
							 * gave up on 1".  Hammering
							 * a card that is not ready
							 * with the same command is
							 * not a retry, it is the
							 * same failure four times.
							 * Back off by the settling
							 * delay each round.
							 */
							sdhostretried++;
							microdelay(sdhostdelay *
								(Maxretry - retries));
							exrewind(c, nthis > 1);
							p = pblk;
							i -= nthis;
							goto again;
						}
						sdhostgaveup++;
					}
					bioerror(c, write, bno+i, r[SDHSTS]);
					goto out;
				}
				*p++ = r[SDDATA];
			}
		}else{
			for(j = 0; j < Secsize*nthis; j += 4){
				if(!fifodata(r)){	/* wait for a word */
					/*
					 * The same bounded retry the byte
					 * loop has had all along, and it
					 * was missing here.
					 *
					 * That went unnoticed because
					 * until the card was put on four
					 * lines this loop was never the
					 * one taken -- every transfer on
					 * real silicon went down the byte
					 * path.  The first sustained test
					 * in word mode found it at once:
					 * a 1.5MB write stalled on a read
					 * of block 39811 with sdhbct 6,
					 * six bytes short of the block,
					 * the FSM back in DATAMODE and
					 * the card idle in TRAN -- a
					 * stall the byte loop would have
					 * re-issued and this one gave up
					 * on.
					 */
					if(exretryable(r)){
						if(retries-- > 0){
							/*
							 * Wait before re-issuing.
							 *
							 * The first version retried
							 * immediately and it did not
							 * help: "retried 4 blocks,
							 * gave up on 1".  Hammering
							 * a card that is not ready
							 * with the same command is
							 * not a retry, it is the
							 * same failure four times.
							 * Back off by the settling
							 * delay each round.
							 */
							sdhostretried++;
							microdelay(sdhostdelay *
								(Maxretry - retries));
							exrewind(c, nthis > 1);
							p = pblk;
							i -= nthis;
							goto again;
						}
						sdhostgaveup++;
					}
					bioerror(c, write, bno+i, r[SDHSTS]);
					goto out;
				}
				w = r[SDDATA];
				p[0] = w;
				p[1] = w>>8;
				p[2] = w>>16;
				p[3] = w>>24;
				p += 4;
			}
		}
		waitxfer(r);			/* let the data phase end */
		if(sdcmdwait(r, &err) < 0){
			bioerror(c, write, bno+i, err);
			r[SDHSTS] = Hstsclear;
			break;
		}
		if(nthis > 1)
			sdcmderr(r, 12, 0, Busywait, &err);	/* STOP_TRANSMISSION */
		r[SDHSTS] = Hstsclear;
		retries = Maxretry;		/* this run is done; reset */
	again:	;
	}
out:
	/*
	 * Stop the card before leaving, if a multi-block transfer was
	 * running.
	 *
	 * Every error path here is a "goto out", and they all skipped
	 * the CMD12 that ends a CMD18 or CMD25.  The card was left in
	 * the middle of a stream, so the next cardready() -- a CMD13 --
	 * never saw it return to TRAN, and every transfer after the
	 * first failure failed too:
	 *
	 *	write block 2900100 failed: sdcmd 0xd ... sdhblc 56
	 *
	 * sdcmd 0xd is CMD13, and sdhblc 56 is the abandoned read's
	 * block count still sitting there.  One failed read poisoned
	 * the card for everything that followed, which is a much worse
	 * fault than the one that started it.
	 */
	if(nthis > 1)
		sdcmderr(r, 12, 0, Busywait, &err);	/* STOP_TRANSMISSION */
	qunlock(c);
	/*
	 * What was MOVED, not what the loop intended to move.
	 *
	 * This returned i * Secsize -- the block-group index times the
	 * block size -- so the answer was computed from how far the loop
	 * got and never from what any data phase actually delivered.
	 * Nothing below reports a length either: dmaperiph waits for the
	 * engine to go inactive and returns 0 or -1, success or failure.
	 * So a transfer that finished without an error but moved fewer
	 * bytes than the command programmed was undetectable from devsd,
	 * from dd, and from any filesystem above them.
	 *
	 * That is not hypothetical.  The DMA path was moving one sector
	 * for an nthis-block command (see the branch above), and no
	 * caller could tell, because this line reported the full length
	 * either way.
	 *
	 * p starts at the caller's buffer, advances by exactly what each
	 * data phase transferred, and is rewound to pblk by every retry,
	 * so p - a IS the bytes delivered.  With correct code it equals
	 * i * Secsize; when it does not, the caller now finds out.
	 */
	return p - (uchar*)a;
}

/*
 * Controller state through /dev/sdM0/ctl, and a few commands to drive it
 * from a shell on the board.  Every question about this controller costs
 * a card swap otherwise: the card cannot be in the reader and in the Pi
 * at once, and only the Pi has the silicon that misbehaves.
 */
static char*
sdhostrctl(SDunit *u, char *p, char *e)
{
	Ctlr *c = u->dev->ctlr;
	volatile u32 *r = c->r;

	p = seprint(p, e, "geometry %llud %lud\n", u->sectors, u->secsize);
	p = seprint(p, e, "sdhost rca %#ux %s sectors %llud coreclock %lud cdiv %lud\n",
		c->rca, c->byteaddr? "byteaddr": "blockaddr", c->sectors,
		c->fclk, (ulong)r[SDCDIV]);
	p = seprint(p, e, "sdhost dma %d dreq %d multi %d multiwrite %d retried %lud gaveup %lud\n",
		sdhostdma, Sdhostdreq, sdhostmulti, sdhostmultiwrite,
		sdhostretried, sdhostgaveup);
	p = seprint(p, e, "sdhost sdcmd %#lux sdhsts %#lux sdedm %#lux sdhcfg %#lux errors %d\n",
		(ulong)r[SDCMD], (ulong)r[SDHSTS], (ulong)r[SDEDM],
		(ulong)r[SDHCFG], c->errors);
	return p;
}

static int
sdhostwctl(SDunit *u, Cmdbuf *cb)
{
	Ctlr *c = u->dev->ctlr;
	volatile u32 *r = c->r;
	u32 err, arg;
	int cmd, flags, i;
	uchar blk[Secsize];

	if(strcmp(cb->f[0], "reinit") == 0){
		qlock(c);
		c->inited = 0;
		c->sectors = 0;
		c->errors = 0;
		i = sdcardinit(c);
		qunlock(c);
		print("sdhost: reinit %s\n", i? "ok": "failed");
		return 0;
	}
	if(strcmp(cb->f[0], "delay") == 0 && cb->nf == 2){
		sdhostdelay = atoi(cb->f[1]);
		print("sdhost: delay %dus\n", sdhostdelay);
		return 0;
	}
	if(strcmp(cb->f[0], "trace") == 0 && cb->nf == 2){
		sdhosttrace = atoi(cb->f[1]);
		print("sdhost: trace %d\n", sdhosttrace);
		return 0;
	}
	/*
	 * Throughput of ONE multi-block request.
	 *
	 *	readspeed <blk> <nblocks>
	 *
	 * wrverify cannot measure this: it calls sdhostbio once per
	 * block, so "multi" never engages and the numbers come out the
	 * same however it is set -- which they duly did, 3850ms against
	 * 3200ms against 3970ms for 1, 16 and 64 blocks per command,
	 * and meant nothing.  A test that cannot see the thing it is
	 * varying will report that the thing does not matter.
	 */
	/*
	 * Write nblocks in ONE request, read them back in one, compare.
	 *
	 *	multiverify <blk> <nblocks>
	 *
	 * readspeed only reads, and a multi-block WRITE is the half that
	 * can corrupt a card rather than merely be slow.  It is not
	 * enough to know CMD25 is faster; it has to be known to put the
	 * right bytes down.  Writes past every partition; see wrverify.
	 */
	if(strcmp(cb->f[0], "multiverify") == 0 && cb->nf == 3){
		uvlong bno = strtoull(cb->f[1], nil, 0);
		long nb = strtol(cb->f[2], nil, 0), n;
		uchar *buf;
		ulong t0, wms, rms;
		int k, bad;

		if(nb < 1 || nb > 4096){
			print("sdhost: multiverify wants 1..4096 blocks\n");
			return 0;
		}
		/*
		 * A card too small for the range asked for is a SKIP, not a
		 * failure.  raspi3binit.b drives this at sector 2900000,
		 * which is 1.4GB in and past the end of a 16MB card -- so
		 * under QEMU's small card every arm printed
		 *
		 *   MULTIVERIFY-FAIL 64 blocks at 2900000: ... MISMATCH
		 *
		 * six times over, from a test that could not have passed.  A
		 * check that fails for want of somewhere to run reports
		 * nothing about the driver, and it takes a real failure's
		 * name while doing it.
		 */
		if(u->sectors && bno + nb > u->sectors){
			print("sdhost: MULTIVERIFY-SKIPPED %ld blocks at %llud"
				" is past the end of a %llud-sector card\n",
				nb, bno, u->sectors);
			return 0;
		}
		if((buf = malloc(nb*Secsize)) == nil){
			print("sdhost: multiverify no memory\n");
			return 0;
		}
		for(k = 0; k < nb*Secsize; k++)
			buf[k] = (k*7 + (int)bno*13 + (k>>11)) & 0xff;
		t0 = TK2MS(m->ticks);
		n = sdhostbio(u, 0, 1, buf, nb, bno);
		wms = TK2MS(m->ticks) - t0;
		if(n != nb*Secsize){
			print("sdhost: MULTIVERIFY-FAIL write %ld of %ld\n",
				n, nb*Secsize);
			free(buf);
			return 0;
		}
		memset(buf, 0, nb*Secsize);
		t0 = TK2MS(m->ticks);
		n = sdhostbio(u, 0, 0, buf, nb, bno);
		rms = TK2MS(m->ticks) - t0;
		bad = -1;
		for(k = 0; k < nb*Secsize; k++)
			if(buf[k] != ((k*7 + (int)bno*13 + (k>>11)) & 0xff)){
				bad = k;
				break;
			}
		print("sdhost: MULTIVERIFY-%s %ld blocks at %llud:"
			" write %lud ms read %lud ms (multi %d dma %d)%s\n",
			bad < 0 && n == nb*Secsize? "OK": "FAIL", nb, bno,
			wms, rms, sdhostmulti, sdhostdma,
			bad < 0? "": " MISMATCH");
		if(bad >= 0)
			print("sdhost:   first bad byte %d\n", bad);
		free(buf);
		return 0;
	}
	if(strcmp(cb->f[0], "readspeed") == 0 && cb->nf == 3){
		uvlong bno = strtoull(cb->f[1], nil, 0);
		long nb = strtol(cb->f[2], nil, 0), n;
		uchar *buf;
		ulong t0, ms;

		if(nb < 1 || nb > 4096){
			print("sdhost: readspeed wants 1..4096 blocks\n");
			return 0;
		}
		if((buf = malloc(nb*Secsize)) == nil){
			print("sdhost: readspeed no memory for %ld blocks\n", nb);
			return 0;
		}
		t0 = TK2MS(m->ticks);
		n = sdhostbio(u, 0, 0, buf, nb, bno);
		ms = TK2MS(m->ticks) - t0;
		print("sdhost: READSPEED %ld of %ld blocks in %lud ms"
			" = %lud KB/s (multi %d, dma %d)\n",
			n/Secsize, nb, ms,
			ms? (ulong)(n/1024*1000/ms): 0, sdhostmulti, sdhostdma);
		free(buf);
		return 0;
	}
	/* blocks per command: 1 is the old one-CMD17-per-block behaviour */
	if(strcmp(cb->f[0], "multiwrite") == 0 && cb->nf == 2){
		sdhostmultiwrite = atoi(cb->f[1]);
		print("sdhost: multiwrite %d\n", sdhostmultiwrite);
		return 0;
	}
	if(strcmp(cb->f[0], "multi") == 0 && cb->nf == 2){
		sdhostmulti = atoi(cb->f[1]);
		if(sdhostmulti < 1)
			sdhostmulti = 1;
		print("sdhost: multi %d blocks per command\n", sdhostmulti);
		return 0;
	}
	if(strcmp(cb->f[0], "dma") == 0 && cb->nf == 2){
		sdhostdma = atoi(cb->f[1]);
		print("sdhost: dma %d\n", sdhostdma);
		return 0;
	}
	if(strcmp(cb->f[0], "clock") == 0 && cb->nf == 2){
		sdhostclock(r, c->fclk, strtoul(cb->f[1], nil, 0));
		print("sdhost: cdiv %lud\n", (ulong)r[SDCDIV]);
		return 0;
	}
	if(strcmp(cb->f[0], "cmd") == 0 && cb->nf >= 2){
		cmd = atoi(cb->f[1]);
		arg = cb->nf > 2? strtoul(cb->f[2], nil, 0): 0;
		flags = cb->nf > 3? strtoul(cb->f[3], nil, 0): 0;
		qlock(c);
		i = sdcmderr(r, cmd, arg, flags, &err);
		qunlock(c);
		print("sdhost: cmd %d arg %#lux -> %d rsp %#lux sdhsts %#lux sdcmd %#lux sdedm %#lux\n",
			cmd, (ulong)arg, i, (ulong)r[SDRSP0], (ulong)err,
			(ulong)r[SDCMD], (ulong)r[SDEDM]);
		return 0;
	}
	if(strcmp(cb->f[0], "thresh") == 0 && cb->nf == 3){
		/* SDEDM's FIFO read and write thresholds, live */
		u32 edm = r[SDEDM];
		edm &= ~(u32)((Edmthreshmask<<Edmrdthreshsh)|(Edmthreshmask<<Edmwrthreshsh));
		edm |= (strtoul(cb->f[1], nil, 0) & Edmthreshmask) << Edmrdthreshsh;
		edm |= (strtoul(cb->f[2], nil, 0) & Edmthreshmask) << Edmwrthreshsh;
		r[SDEDM] = edm;
		print("sdhost: sdedm %#lux\n", (ulong)r[SDEDM]);
		return 0;
	}
	/*
	 * The card's bus width and the controller's, together.
	 *
	 * "wide 1" is ACMD6 SET_BUS_WIDTH(4) to the card followed by
	 * WIDE_EXT_BUS|WIDE_INT_BUS in SDHCFG; "wide 0" puts both back
	 * to one line.  They go together on purpose: the controller and
	 * the card have to agree about how many DAT lines carry the
	 * data, and setting either alone is what made the first attempt
	 * at this unreadable.
	 */
	if(strcmp(cb->f[0], "wide") == 0 && cb->nf == 2){
		i = atoi(cb->f[1]);
		/*
		 * Under the qlock, because the card is in use.
		 *
		 * The first version of this took no lock and CMD55 came
		 * back with a command timeout every time, while the same
		 * command from the driver's own cardready() -- which
		 * retries -- worked.  A filesystem was reading the card
		 * throughout; two senders on one command register is a
		 * collision, not a card that needs coaxing.  Every ctl
		 * command that touches the controller wants this.
		 */
		qlock(c);
		if(!cardready(c)){
			qunlock(c);
			print("sdhost: card not ready\n");
			return 0;
		}
		if(sdcmderr(r, 55, c->rca<<16, 0, &err) < 0){
			qunlock(c);
			print("sdhost: CMD55 failed, sdhsts %#lux\n", (ulong)err);
			return 0;
		}
		if(sdcmderr(r, 6, i? 2: 0, 0, &err) < 0){
			qunlock(c);
			print("sdhost: ACMD6 failed, sdhsts %#lux\n", (ulong)err);
			return 0;
		}
		sdhostcfg = i? Cfgwideext|Cfgwideint: 0;
		r[SDHCFG] = (r[SDHCFG] & ~(u32)(Cfgwideext|Cfgwideint)) | sdhostcfg;
		c->bmset = 0;		/* the probe has to run again */
		print("sdhost: wide %d, card rsp %#lux, sdhcfg %#lux\n",
			i, (ulong)r[SDRSP0], (ulong)r[SDHCFG]);
		qunlock(c);
		return 0;
	}
	/*
	 * SDHCFG's extra bits by hand, for trying one at a time.  They
	 * are held and reapplied before every transfer, so a value set
	 * here survives the driver's own writes to that register.
	 */
	if(strcmp(cb->f[0], "hcfg") == 0 && cb->nf == 2){
		sdhostcfg = strtoul(cb->f[1], nil, 0);
		qlock(c);
		r[SDHCFG] = Cfgslowcard | Cfgdataint | Cfgbusyint | sdhostcfg;
		qunlock(c);
		c->bmset = 0;
		print("sdhost: sdhcfg %#lux\n", (ulong)r[SDHCFG]);
		return 0;
	}
	/* re-run the bytemode probe with whatever is set now */
	if(strcmp(cb->f[0], "probe") == 0 && cb->nf == 1){
		c->bmset = 0;
		pickbytemode(u, c);
		return 0;
	}
	/*
	 * Write blocks and read them back, with no filesystem anywhere
	 * near it.
	 *
	 *	wrverify <blk> <n> [wdma rdma]
	 *
	 * The first attempt to test DMA writes went through /tmp, which
	 * on this board is kfs on the kfstest partition -- so the raw
	 * write under test destroyed the filesystem the verification
	 * was going to read through, and the check could not run at
	 * all.  This writes a pattern built from the block number,
	 * reads it back with the DMA switch set independently for the
	 * two directions, and compares in the kernel, so a DMA write
	 * can be checked against a PIO read and the other way round.
	 *
	 * IT WRITES TO THE CARD, and it range-checks nothing.  Give it
	 * blocks past every partition -- 2000000 and up on this card,
	 * which ends at 30228480.  NOT kfstest (2048..16383): that is
	 * where kfs lives, and /tmp with it, which is precisely the
	 * mistake above.  NOT the DOS partition (16384..1064960), which
	 * holds the kernel the board boots.
	 */
	if(strcmp(cb->f[0], "wrverify") == 0 && (cb->nf == 3 || cb->nf == 5)){
		uvlong bno = strtoull(cb->f[1], nil, 0), b;
		long nb = strtol(cb->f[2], nil, 0), n;
		int wdma = cb->nf == 5? atoi(cb->f[3]): 1;
		int rdma = cb->nf == 5? atoi(cb->f[4]): 0;
		int k, pat, bad = 0, save = sdhostdma;
		ulong t0;

		/*
		 * The pattern is masked, not cast.
		 *
		 * It was written (uchar)(k*7 + (bno+b)*13 + (k>>8)), and
		 * bno is a uvlong, so the sum is 64 bits -- and this
		 * compiler emits no truncation for a narrowing cast of a
		 * 64-bit value.  The comparison therefore held a byte
		 * from the card against a full 64-bit number and failed
		 * on the first byte of every block, while the print,
		 * which shows two hex digits of each, said "is bc want
		 * bc".  An explicit mask is the fix, tree-wide.
		 */
		t0 = TK2MS(m->ticks);
		for(b = 0; b < (uvlong)nb; b++){
			for(k = 0; k < Secsize; k++)
				blk[k] = (k*7 + (int)(bno+b)*13 + (k>>8)) & 0xff;
			sdhostdma = wdma;
			n = sdhostbio(u, 0, 1, blk, 1, bno+b);
			if(n != Secsize){
				print("sdhost: wrverify write %llud -> %ld\n",
					bno+b, n);
				bad++;
				break;
			}
			memset(blk, 0, sizeof blk);
			sdhostdma = rdma;
			n = sdhostbio(u, 0, 0, blk, 1, bno+b);
			if(n != Secsize){
				print("sdhost: wrverify read %llud -> %ld\n",
					bno+b, n);
				bad++;
				break;
			}
			for(k = 0; k < Secsize; k++){
				pat = (k*7 + (int)(bno+b)*13 + (k>>8)) & 0xff;
				if(blk[k] != pat){
					print("sdhost: wrverify %llud byte %d"
						" is %.2ux want %.2ux\n",
						bno+b, k, blk[k], pat);
					bad++;
					break;
				}
			}
			if(bad)
				break;
		}
		sdhostdma = save;
		print("sdhost: WRVERIFY-%s %ld blocks at %llud,"
			" write dma %d read dma %d, %lud ms\n",
			bad? "FAIL": "OK", nb, bno, wdma, rdma, TK2MS(m->ticks)-t0);
		return 0;
	}
	if(strcmp(cb->f[0], "wide") == 0 && cb->nf == 3){
		/* force both halves apart, for testing: wide <card> <ctlr> */
		sdhostcfg = atoi(cb->f[2])? Cfgwideext|Cfgwideint: 0;
		qlock(c);
		if(cardready(c) && sdcmderr(r, 55, c->rca<<16, 0, &err) == 0)
			sdcmderr(r, 6, atoi(cb->f[1])? 2: 0, 0, &err);
		r[SDHCFG] = (r[SDHCFG] & ~(u32)(Cfgwideext|Cfgwideint)) | sdhostcfg;
		c->bmset = 0;
		qunlock(c);
		print("sdhost: card %s-bit, sdhcfg %#lux\n",
			atoi(cb->f[1])? "4": "1", (ulong)r[SDHCFG]);
		return 0;
	}
	if(strcmp(cb->f[0], "bytemode") == 0 && cb->nf == 2){
		c->bytemode = atoi(cb->f[1]);
		print("sdhost: bytemode %d\n", c->bytemode);
		return 0;
	}
	if(strcmp(cb->f[0], "probe3") == 0 && cb->nf == 2){
		/* read a block a byte at a time and show what came out */
		uvlong bno = strtoull(cb->f[1], nil, 0);
		long n;
		int k;
		char buf[3*16+1], *q;

		memset(blk, 0, sizeof blk);
		n = sdhostbio(u, 0, 0, blk, 1, bno);
		q = buf;
		for(k = 0; k < 16; k++)
			q += sprint(q, "%.2ux", blk[k]);
		*q = 0;
		print("sdhost: probe3 %llud -> %ld %s (510,511 %.2ux%.2ux)\n",
			bno, n, buf, blk[510], blk[511]);
		return 0;
	}
	if(strcmp(cb->f[0], "probe2") == 0 && cb->nf == 3){
		/*
		 * Read one block under a chosen pacing rule and show the first
		 * eight words, to find which one hands over whole words:
		 *   0  the data flag and a non-zero fill (what the driver does)
		 *   1  a fill of four or more
		 *   2  a fixed delay between words
		 *   3  the fill level changing since the last word
		 */
		uvlong bno = strtoull(cb->f[1], nil, 0);
		int mode = atoi(cb->f[2]);
		u32 word[8];
		int k, last;

		qlock(c);
		cardready(c);
		r[SDHBCT] = Secsize;
		r[SDHBLC] = 1;
		arg = c->byteaddr? (u32)(bno*Secsize): (u32)bno;
		sdcmdstart(r, 17, arg, Readcmd);
		last = -1;
		for(k = 0; k < 8; k++){
			for(i = 0; i < 1000000; i++){
				int fill = fifofill(r);
				if(mode == 0 && (r[SDHSTS] & Hstsdata) != 0 && fill > 0)
					break;
				if(mode == 1 && fill >= 4)
					break;
				if(mode == 2){
					microdelay(20);
					break;
				}
				if(mode == 3 && fill != last && fill > 0){
					last = fill;
					break;
				}
			}
			word[k] = r[SDDATA];
		}
		for(i = 0; i < 1000000; i++){	/* drain the rest */
			if((r[SDHSTS] & Hstsdata) == 0 && fifofill(r) == 0)
				break;
			(void)r[SDDATA];
		}
		waitxfer(r);
		sdcmdwait(r, &err);
		r[SDHSTS] = Hstsclear;
		qunlock(c);
		print("sdhost: probe2 mode %d words %.8lux %.8lux %.8lux %.8lux %.8lux %.8lux %.8lux %.8lux\n",
			mode, (ulong)word[0], (ulong)word[1], (ulong)word[2],
			(ulong)word[3], (ulong)word[4], (ulong)word[5],
			(ulong)word[6], (ulong)word[7]);
		return 0;
	}
	if(strcmp(cb->f[0], "probe") == 0 && cb->nf == 2){
		/*
		 * Start a single-block read and report what the controller
		 * says as the data arrives: eight samples of SDHSTS and
		 * SDEDM taken without reading anything, then the first four
		 * words as the data flag hands them over.
		 */
		uvlong bno = strtoull(cb->f[1], nil, 0);
		u32 sts[8], edm[8], word[4];

		qlock(c);
		cardready(c);
		r[SDHBCT] = Secsize;
		r[SDHBLC] = 1;
		arg = c->byteaddr? (u32)(bno*Secsize): (u32)bno;
		sdcmdstart(r, 17, arg, Readcmd);
		for(i = 0; i < 8; i++){
			sts[i] = r[SDHSTS];
			edm[i] = r[SDEDM];
		}
		for(i = 0; i < 4; i++){
			fifodata(r);
			word[i] = r[SDDATA];
		}
		for(i = 0; i < 1000000; i++){	/* drain the rest */
			if((r[SDHSTS] & Hstsdata) == 0 && fifofill(r) == 0)
				break;
			(void)r[SDDATA];
		}
		waitxfer(r);
		sdcmdwait(r, &err);
		r[SDHSTS] = Hstsclear;
		qunlock(c);
		for(i = 0; i < 8; i++)
			print("sdhost: probe sample %d sdhsts %#lux sdedm %#lux fill %d\n",
				i, (ulong)sts[i], (ulong)edm[i],
				(int)((edm[i] >> Fifofillsh) & Fifofillmask));
		print("sdhost: probe words %.8lux %.8lux %.8lux %.8lux drained %d err %#lux\n",
			(ulong)word[0], (ulong)word[1], (ulong)word[2], (ulong)word[3],
			i, (ulong)err);
		return 0;
	}
	if(strcmp(cb->f[0], "readblk") == 0 && (cb->nf == 2 || cb->nf == 3)){
		uvlong bno = strtoull(cb->f[1], nil, 0);
		long n;
		int off, k;
		char buf[3*32+1], *q;

		/* readblk <block> [offset]: dump 32 bytes from offset in it */
		off = cb->nf == 3? atoi(cb->f[2]): 0;
		if(off < 0 || off > Secsize-1)
			off = 0;
		memset(blk, 0, sizeof blk);
		n = sdhostbio(u, 0, 0, blk, 1, bno);
		q = buf;
		for(k = off; k < off+32 && k < Secsize; k++)
			q += sprint(q, "%.2ux", blk[k]);
		*q = 0;
		print("sdhost: readblk %llud+%d -> %ld %s\n", bno, off, n, buf);
		return 0;
	}
	error(Ebadctl);
	return 0;
}

SDifc sdhostbcmifc = {
	"sdhost",			/* name */

	sdhostpnp,			/* pnp */
	nil,				/* enable */
	nil,				/* disable */

	sdhostverify,			/* verify */
	sdhostonline,			/* online */
	nil,				/* rio */
	sdhostrctl,			/* rctl */
	sdhostwctl,			/* wctl */

	sdhostbio,			/* bio */
	nil,				/* probe */
	nil,				/* clear */
	nil,				/* rtopctl */
	nil,				/* wtopctl */
};
