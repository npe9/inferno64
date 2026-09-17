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

	Idclock	= 400000,	/* card identification clock */
	Datclock = 25000000,	/* after identification */
	Cdivmax	= 0x7ff,

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
	r[SDHCFG] = Cfgslowcard;
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
	int i;

	for(i = 0; i < 1000000; i++){
		if((r[SDHSTS] & Hstsdata) != 0)
			return 1;
		edm = r[SDEDM];
		if((edm & Edmfsmmask) == Fsmreadwait)	/* stalled: let it run on */
			r[SDEDM] = edm | Edmforcedata;
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
	sdhostclock(r, fclk, Datclock);		/* identification done: speed up */
	print("sdhost: card rca %#ux %s %llud sectors, core clock %lud Hz\n",
		c->rca, c->byteaddr? "byte": "block", c->sectors, fclk);
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
static void
bioerror(Ctlr *c, int write, uvlong bno, u32 sts)
{
	if(c->errors++ > 5)
		return;
	print("sdhost: %s block %llud failed: sdhsts %#lux sdcmd %#lux sdedm %#lux\n",
		write? "write": "read", bno, (ulong)sts, (ulong)c->r[SDCMD],
		(ulong)c->r[SDEDM]);
}

static long
sdhostbio(SDunit *u, int lun, int write, void *a, long nb, uvlong bno)
{
	Ctlr *c = u->dev->ctlr;
	volatile u32 *r = c->r;
	uchar *p = a;
	long i;
	int j;
	u32 arg, w, err;

	USED(lun);
	qlock(c);
	for(i = 0; i < nb; i++){
		arg = c->byteaddr? (u32)((bno+i)*Secsize): (u32)(bno+i);
		r[SDHBCT] = Secsize;
		r[SDHBLC] = 1;
		/*
		 * WRITE_SINGLE_BLOCK / READ_SINGLE_BLOCK.  A data command is
		 * only started here, not waited for: on the Pi the controller
		 * keeps NEW_FLAG set through the data phase, and with the
		 * 16-word FIFO full it cannot finish until the words are moved
		 * (sdcmd 0x8051, FIFO full, FSM in READDATA).  Waiting first
		 * deadlocked every transfer after the first.
		 */
		err = 0;
		if(!cardready(c)){
			bioerror(c, write, bno+i, r[SDHSTS]);
			break;
		}
		if(sdcmdstart(r, write? 24: 17, arg, write? Writecmd: Readcmd) < 0){
			bioerror(c, write, bno+i, r[SDHSTS]);
			break;
		}
		if(write){
			for(j = 0; j < Secsize; j += 4){
				w = p[0] | p[1]<<8 | p[2]<<16 | p[3]<<24;
				if(!fifospace(r)){	/* wait for FIFO room */
					bioerror(c, write, bno+i, r[SDHSTS]);
					goto out;
				}
				r[SDDATA] = w;
				p += 4;
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
			for(j = 0; j < Secsize; j++){
				if(!fifodata(r)){	/* wait for data */
					bioerror(c, write, bno+i, r[SDHSTS]);
					goto out;
				}
				*p++ = r[SDDATA];
			}
		}else{
			for(j = 0; j < Secsize; j += 4){
				if(!fifodata(r)){	/* wait for a word */
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
		r[SDHSTS] = Hstsclear;
	}
out:
	qunlock(c);
	return i * Secsize;
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
	if(strcmp(cb->f[0], "clock") == 0 && cb->nf == 2){
		sdhostclock(r, c->fclk, strtoul(cb->f[1], nil, 0));
		print("sdhost: cdiv %lud\n", (ulong)r[SDCDIV]);
		return 0;
	}
	if(strcmp(cb->f[0], "cmd") == 0 && cb->nf >= 2){
		cmd = atoi(cb->f[1]);
		arg = cb->nf > 2? strtoul(cb->f[2], nil, 0): 0;
		flags = cb->nf > 3? strtoul(cb->f[3], nil, 0): 0;
		i = sdcmderr(r, cmd, arg, flags, &err);
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
