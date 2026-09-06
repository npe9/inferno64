/*
 * Arasan SDHCI (the BCM2837's "EMMC" controller, 0x3f300000) as an
 * Inferno storage device on the Raspberry Pi 3.  This is a standard SD
 * Host Controller, unlike the SDHOST block sdhostbcm.c drives, and it is
 * the controller the BCM43430 Wi-Fi hangs off over SDIO -- which is the
 * reason this driver exists.  Phase 6 wants its SDIO command path; the
 * SD-card path here is what can be exercised without a Wi-Fi chip.
 *
 * ONE CARD, TWO CONTROLLERS.  The SoC can wire the SD card slot to
 * either block, and the GPIO 48-53 alt function is what decides: alt0
 * gives the card to SDHOST (sdhostbcm.c), alt3 gives it to this one.
 * Both drivers route the pins in their own online(), so whichever unit
 * is opened first takes the card and the other then reports no media.
 * That is the hardware's arrangement, not an artifact: there is one
 * card and one set of pins.
 *
 * On a real Pi 3B you want SDHOST on the card (alt0, the default here)
 * and this controller left for the Wi-Fi, which sits on its own pins --
 * GPIO 34-39 in alt3 -- so the two coexist with no contention at all.
 * QEMU models no BCM43430, so the only way to exercise this
 * controller's data path under emulation is to hand it the SD card
 * instead; opening /dev/sdH0 before /dev/sdM0 does that.  Say plainly
 * which half that proves: the SDHCI register interface, the command
 * engine and the PIO data path are exercised for real; the SDIO
 * commands below (CMD52/CMD53) are not, because an SD memory card
 * rejects them and there is no SDIO device in the emulator to answer.
 *
 * Register interface (SD Host Controller Simplified Spec 3.00): write
 * Arg1, then Cmdtm (index<<24 with the response/data flags), and wait
 * for Cmdcomplete in Interrupt; the response lands in Resp0..3.  For a
 * data transfer set Blksizecnt first and move the block through the
 * Data port a 32-bit word at a time, gated on Readrdy/Writerdy.
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
	/* register offsets, in 32-bit words */
	Arg2		= 0x00/4,
	Blksizecnt	= 0x04/4,
	Arg1		= 0x08/4,
	Cmdtm		= 0x0c/4,
	Resp0		= 0x10/4,
	Resp1		= 0x14/4,
	Resp2		= 0x18/4,
	Resp3		= 0x1c/4,
	Data		= 0x20/4,
	Status		= 0x24/4,
	Control0	= 0x28/4,
	Control1	= 0x2c/4,
	Interrupt	= 0x30/4,
	Irptmask	= 0x34/4,
	Irpten		= 0x38/4,
	Capabilities	= 0x40/4,

	/* Cmdtm: transfer mode in the low half, command in the high half */
	Respnone	= 0<<16,
	Resp136		= 1<<16,
	Resp48		= 2<<16,
	Resp48busy	= 3<<16,
	Cmdcrcchk	= 1<<19,
	Cmdixchk	= 1<<20,
	Cmdisdata	= 1<<21,
	Tmblkcnt	= 1<<1,
	Tmautocmd12	= 1<<2,
	Tmdatdirread	= 1<<4,
	Tmmultiblock	= 1<<5,

	/* Status (present state) */
	Cmdinhibit	= 1<<0,
	Datinhibit	= 1<<1,
	Writerdy	= 1<<10,
	Readrdy		= 1<<11,
	Cardinserted	= 1<<16,

	/* Control0 */
	Buspower	= 1<<8,
	Busvoltage33	= 7<<9,
	Hcdatawidth4	= 1<<1,

	/* Control1 */
	Clkintlen	= 1<<0,
	Clkstable	= 1<<1,
	Clken		= 1<<2,
	Srsthost	= 1<<24,
	Srstcmd		= 1<<25,
	Srstdata	= 1<<26,

	/* Interrupt / Irptmask */
	Cmdcomplete	= 1<<0,
	Datadone	= 1<<1,
	Writeready	= 1<<4,
	Readready	= 1<<5,
	Interr		= 1<<15,

	Secsize		= 512,
	Alt0		= 4,	/* GPIO fsel: SDHOST owns the card pins */
	Alt3		= 7,	/* GPIO fsel: this controller owns them */

	Timeout		= 1000000,	/* bounded register polls */
};

typedef struct Ctlr Ctlr;
struct Ctlr {
	QLock;			/* serialise bio across concurrent procs */
	u32*	r;
	uvlong	sectors;
	int	byteaddr;
	int	inited;
	uint	rca;
};

static Ctlr sdhcictlr;
extern SDifc sdhcibcmifc;

/*
 * Wait for a bit in a register to go high (or, with want==0, low).
 * Bounded: a wedged controller must not spin the kernel forever.  On
 * real silicon these polls take real time; the emulator completes a
 * command inside the register write, so they fall straight through.
 */
static int
awaitbit(u32 *reg, u32 bit, int want)
{
	int i;

	for(i = 0; i < Timeout; i++)
		if((int)((*reg & bit) != 0) == want)
			return 0;
	return -1;
}

/*
 * Issue one command and wait for it to complete.  Returns 0, or -1 if
 * the controller reported an error or never answered; the response is
 * left in Resp0..3 for the caller.
 */
static int
sdhcicmd(Ctlr *c, int cmd, u32 arg, u32 flags)
{
	u32 *r = c->r;

	if(awaitbit(&r[Status], Cmdinhibit, 0) < 0)
		return -1;
	if(flags & Cmdisdata)
		if(awaitbit(&r[Status], Datinhibit, 0) < 0)
			return -1;
	r[Interrupt] = r[Interrupt];		/* clear stale status (w1c) */
	r[Arg1] = arg;
	r[Cmdtm] = (cmd << 24) | flags;
	if(awaitbit(&r[Interrupt], Cmdcomplete|Interr, 1) < 0)
		return -1;
	if(r[Interrupt] & Interr){
		r[Interrupt] = r[Interrupt];
		return -1;
	}
	r[Interrupt] = Cmdcomplete;
	return 0;
}

/*
 * Controller bring-up: reset, supply the bus, and run the internal
 * clock at the slowest divider the card can be identified at.
 */
static int
sdhcictlrinit(Ctlr *c)
{
	u32 *r = c->r;

	r[Control1] = Srsthost;
	if(awaitbit(&r[Control1], Srsthost, 0) < 0)
		return -1;

	r[Control0] = Busvoltage33;
	r[Control0] = Busvoltage33 | Buspower;

	/*
	 * Identification runs at 400kHz or less.  The divider field is
	 * the 8-bit "divided clock" form (Control1 bits 8-15), dividing
	 * the base clock by 2*N; 0x80 is the largest, which is slow
	 * enough from any plausible base clock on this part.
	 */
	r[Control1] = (0x80 << 8) | (0xe << 16) | Clkintlen;
	if(awaitbit(&r[Control1], Clkstable, 1) < 0)
		return -1;
	r[Control1] |= Clken;

	r[Irptmask] = ~0;		/* record status; we poll, not interrupt */
	r[Irpten] = 0;
	r[Interrupt] = r[Interrupt];
	return 0;
}

/*
 * Prove that the GPIO alt function really moves the card between the
 * two controllers, rather than the card merely happening to sit on
 * this one already.  Alt0 hands the card pins to SDHOST, which must
 * make it vanish from here; Alt3 takes them back, which must make it
 * reappear.  Identification runs afterwards and starts with GO_IDLE,
 * so the round trip leaves nothing to clean up.
 *
 * Not run by default: it is a diagnostic, and a controller that cannot
 * take the card back leaves the board with no SD card at all.  Build
 * with -DSDROUTETEST.
 */
#ifdef SDROUTETEST
static void
sdhciroutetest(Ctlr *c)
{
	u32 *r = c->r;
	int i, released, regained;

	for(i = 48; i <= 53; i++)
		gpiofsel(i, Alt0);		/* hand the card to SDHOST */
	released = (r[Status] & Cardinserted) == 0;
	for(i = 48; i <= 53; i++)
		gpiofsel(i, Alt3);		/* take it back */
	/*
	 * Card detect does not settle the instant the pins are switched.
	 * Losing the card raised a card-removal interrupt, and the
	 * controller will not report the new insertion until that status
	 * is acknowledged, so clear it (the status bits are write-one-to-
	 * clear) and then wait for the card to be seen.
	 */
	r[Interrupt] = r[Interrupt];
	for(i = 0; i < 300; i++){
		if(r[Status] & Cardinserted)
			break;
		delay(10);
	}
	regained = (r[Status] & Cardinserted) != 0;

	print("sdhci: alt0 %s the card, alt3 %s\n",
		released? "released": "DID NOT release",
		regained? "took it back": "DID NOT take it back");
	print("%s\n", released && regained? "SDROUTE-OK": "SDROUTE-FAIL");
}
#endif

/*
 * Card bring-up over the standard SD identification sequence.  Returns
 * 1 with the card selected and sized, 0 if nothing answers.
 */
static int
sdhcicardinit(Ctlr *c)
{
	u32 *r = c->r;
	u32 ocr, csd[4];
	int i, rbl, cmult;
	uvlong cap;
	uchar b[16];

	/* take the card pins for this controller (see the file comment) */
	for(i = 48; i <= 53; i++)
		gpiofsel(i, Alt3);

	if(sdhcictlrinit(c) < 0)
		return 0;
	if((r[Status] & Cardinserted) == 0)
		return 0;			/* nothing in the slot */

#ifdef SDROUTETEST
	/*
	 * Losing and regaining the card drops the controller's clock and
	 * power, so bring it up again before identifying the card.
	 */
	sdhciroutetest(c);
	if(sdhcictlrinit(c) < 0)
		return 0;
#endif

	if(sdhcicmd(c, 0, 0, Respnone) < 0)		/* GO_IDLE */
		return 0;
	if(sdhcicmd(c, 8, 0x1aa, Resp48|Cmdcrcchk|Cmdixchk) < 0)	/* SEND_IF_COND */
		return 0;
	if((r[Resp0] & 0xff) != 0xaa)
		return 0;			/* no v2 card answering */

	ocr = 0;
	for(i = 0; i < 1000; i++){		/* ACMD41 init loop */
		if(sdhcicmd(c, 55, 0, Resp48|Cmdcrcchk|Cmdixchk) < 0)
			return 0;
		if(sdhcicmd(c, 41, 0x40ff8000, Resp48) < 0)
			return 0;
		ocr = r[Resp0];
		if(ocr & 0x80000000)
			break;
	}
	if((ocr & 0x80000000) == 0)
		return 0;
	c->byteaddr = (ocr & 0x40000000)? 0: 1;	/* CCS: 1 = block-addressed */

	if(sdhcicmd(c, 2, 0, Resp136|Cmdcrcchk) < 0)	/* ALL_SEND_CID */
		return 0;
	if(sdhcicmd(c, 3, 0, Resp48|Cmdcrcchk|Cmdixchk) < 0)	/* SEND_RELATIVE_ADDR */
		return 0;
	c->rca = r[Resp0] >> 16;

	if(sdhcicmd(c, 9, c->rca<<16, Resp136|Cmdcrcchk) < 0)	/* SEND_CSD */
		return 0;
	/*
	 * A 136-bit response is stored without its CRC byte: the spec puts
	 * resp[127:8] in RESP[119:0], so Resp0 = resp[39:8], Resp1 =
	 * resp[71:40], Resp2 = resp[103:72], and only the low 24 bits of
	 * Resp3 are resp[127:104] -- its top byte is reserved.  Unpack to
	 * the conventional CSD byte numbering, b[0] = CSD[127:120], so the
	 * field arithmetic below is the same as everyone else's.  b[15] is
	 * the CRC byte, which the controller does not hand back.
	 */
	csd[0] = r[Resp3];
	csd[1] = r[Resp2];
	csd[2] = r[Resp1];
	csd[3] = r[Resp0];
	b[0]  = csd[0]>>16;
	b[1]  = csd[0]>>8;
	b[2]  = csd[0];
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

	if(sdhcicmd(c, 7, c->rca<<16, Resp48busy|Cmdcrcchk|Cmdixchk) < 0)	/* SELECT */
		return 0;
	if(sdhcicmd(c, 16, Secsize, Resp48|Cmdcrcchk|Cmdixchk) < 0)	/* SET_BLOCKLEN */
		return 0;
	return c->sectors != 0;
}

/*
 * SDIO bring-up.
 *
 * A Pi keeps the SD card on SDHOST, which owns GPIO 48-53 in alt0, and
 * gives this controller the Wi-Fi chip on its own pins, GPIO 34-39 in
 * alt3.  So this path must not go near the card pins: taking them
 * would steal the card from the other controller, which is the whole
 * reason it is a separate entry point from sdhcicardinit() rather than
 * a flag on it.  Both share sdhcictlrinit(), which brings up the
 * controller and knows nothing about what is on the far end of it.
 *
 * The sequence is the SDIO one, not the memory-card one: no CMD8, no
 * ACMD41, no CSD.  An I/O-only function answers none of those.
 */
int
sdioinit(void)
{
	Ctlr *c = &sdhcictlr;
	u32 *r;
	u32 ocr;
	int i;

	if(c->r == nil)
		c->r = (u32*)SDHCI;
	r = c->r;

	for(i = 34; i <= 39; i++)
		gpiofsel(i, Alt3);

	if(sdhcictlrinit(c) < 0)
		return -1;
	if(sdhcicmd(c, 0, 0, Respnone) < 0)		/* GO_IDLE */
		return -1;

	/*
	 * CMD5 with a zero argument asks what the card is; the R4 response
	 * carries the number of I/O functions in bits 30:28 and the
	 * voltage window it supports in bits 23:0.  Repeating CMD5 with
	 * that window set waits for bit 31, the ready bit.  R4 has neither
	 * a CRC nor a command index, so neither is checked.
	 */
	if(sdhcicmd(c, 5, 0, Resp48) < 0)
		return -1;
	ocr = r[Resp0];
	if(((ocr >> 28) & 7) == 0)
		return -1;				/* no I/O function here */
	for(i = 0; i < 1000; i++){
		if(sdhcicmd(c, 5, ocr & 0x00ffffff, Resp48) < 0)
			return -1;
		ocr = r[Resp0];
		if(ocr & 0x80000000)
			break;
	}
	if((ocr & 0x80000000) == 0)
		return -1;

	if(sdhcicmd(c, 3, 0, Resp48|Cmdcrcchk|Cmdixchk) < 0)	/* RELATIVE_ADDR */
		return -2;
	c->rca = r[Resp0] >> 16;
	if(sdhcicmd(c, 7, c->rca<<16, Resp48busy|Cmdcrcchk|Cmdixchk) < 0)
		return -3;				/* SELECT */
	return (ocr >> 28) & 7;
}

/*
 * CMD52 (IO_RW_DIRECT) moves one byte to
 * or from a function's register space; CMD53 (IO_RW_EXTENDED) moves a
 * run of bytes or blocks.  Both are the transport ether4330 needs.
 *
 * Written from the SDIO Simplified Specification.  An SD memory card
 * answers neither command, so a passing SD-card test says nothing
 * about them; they are exercised instead against the SDIO function
 * model in tools/qemu-patches, which is what sdiocheck() drives.
 */
int
sdiocmd52(int fn, int addr, int write, int val)
{
	Ctlr *c = &sdhcictlr;
	u32 arg;

	arg = (write & 1) << 31 | (fn & 7) << 28 | (write & 1) << 27 |
		(addr & 0x1ffff) << 9 | (val & 0xff);
	if(sdhcicmd(c, 52, arg, Resp48|Cmdcrcchk|Cmdixchk) < 0)
		return -1;
	return c->r[Resp0] & 0xff;
}

int
sdiocmd53(int fn, int addr, int write, int blockmode, int incr, void *a, int n)
{
	Ctlr *c = &sdhcictlr;
	uchar *p = a;
	u32 arg, flags;
	int i, j, nblk, blksize;

	/*
	 * n counts blocks in block mode and bytes in byte mode; the count
	 * field carries whichever it is, and 0 there means 512.
	 */
	if(blockmode){
		nblk = n;
		blksize = Secsize;
	}else{
		nblk = 1;
		blksize = n;
		if(blksize <= 0 || blksize > Secsize)
			return -1;
	}
	arg = (write & 1) << 31 | (fn & 7) << 28 | (blockmode & 1) << 27 |
		(incr & 1) << 26 | (addr & 0x1ffff) << 9 | (n & 0x1ff);

	c->r[Blksizecnt] = nblk << 16 | blksize;
	flags = Resp48|Cmdcrcchk|Cmdixchk|Cmdisdata|Tmblkcnt;
	if(!write)
		flags |= Tmdatdirread;
	if(nblk > 1)
		flags |= Tmmultiblock;
	if(sdhcicmd(c, 53, arg, flags) < 0)
		return -1;
	/*
	 * The data port is 32 bits wide, so a byte-mode length that is not
	 * a multiple of four has a tail to assemble by hand rather than
	 * running off the end of the caller's buffer.
	 */
	for(i = 0; i < nblk; i++){
		if(write){
			if(awaitbit(&c->r[Interrupt], Writeready, 1) < 0)
				return -1;
			c->r[Interrupt] = Writeready;
			for(j = 0; j < blksize; j += 4){
				u32 w = 0;
				int k;
				for(k = 0; k < 4 && j+k < blksize; k++)
					w |= (u32)p[k] << (8*k);
				c->r[Data] = w;
				p += (blksize - j < 4)? blksize - j: 4;
			}
		}else{
			if(awaitbit(&c->r[Interrupt], Readready, 1) < 0)
				return -1;
			c->r[Interrupt] = Readready;
			for(j = 0; j < blksize; j += 4){
				u32 w = c->r[Data];
				int k;
				for(k = 0; k < 4 && j+k < blksize; k++)
					p[k] = w >> (8*k);
				p += (blksize - j < 4)? blksize - j: 4;
			}
		}
	}
	if(awaitbit(&c->r[Interrupt], Datadone, 1) < 0)
		return -1;
	c->r[Interrupt] = Datadone;
	return n;
}

static SDev*
sdhcipnp(void)
{
	SDev *s;

	if((uintptr)SDHCI == 0)
		return nil;
	sdhcictlr.r = (u32*)SDHCI;
	if((s = malloc(sizeof(*s))) == nil)
		return nil;
	s->ctlr = &sdhcictlr;
	s->idno = 'H';
	s->ifc = &sdhcibcmifc;
	s->nunit = 1;
	return s;
}

static int
sdhciverify(SDunit *u)
{
	USED(u);
	return 1;
}

static int
sdhcionline(SDunit *u)
{
	Ctlr *c = u->dev->ctlr;
	int first;

	first = 0;
	if(!c->inited){
		c->inited = 1;
		sdhcicardinit(c);	/* leaves c->sectors 0 if no card */
		first = 1;
	}
	if(c->sectors == 0)
		return 0;		/* no media -- SDHOST may hold the pins */
	/*
	 * Repopulate from the cached geometry every call: sdinitpart()
	 * zeroes unit->sectors beforehand, and report media change only
	 * on the first init, exactly as sdhostbcm.c does and for the same
	 * reason (returning 2 every call churns the partition version).
	 */
	u->secsize = Secsize;
	u->sectors = c->sectors;
	return first? 2: 1;
}

static long
sdhcibio(SDunit *u, int lun, int write, void *a, long nb, uvlong bno)
{
	Ctlr *c = u->dev->ctlr;
	u32 *r = c->r;
	uchar *p = a;
	long i;
	int j;
	u32 arg, w, flags;

	USED(lun);
	qlock(c);
	for(i = 0; i < nb; i++){
		arg = c->byteaddr? (u32)((bno+i)*Secsize): (u32)(bno+i);
		r[Blksizecnt] = (1<<16) | Secsize;
		flags = Resp48|Cmdcrcchk|Cmdixchk|Cmdisdata|Tmblkcnt;
		if(write){
			if(sdhcicmd(c, 24, arg, flags) < 0)	/* WRITE_BLOCK */
				break;
			if(awaitbit(&r[Interrupt], Writeready, 1) < 0)
				break;
			r[Interrupt] = Writeready;
			for(j = 0; j < Secsize; j += 4){
				w = p[0] | p[1]<<8 | p[2]<<16 | p[3]<<24;
				r[Data] = w;
				p += 4;
			}
		}else{
			if(sdhcicmd(c, 17, arg, flags|Tmdatdirread) < 0)	/* READ_BLOCK */
				break;
			if(awaitbit(&r[Interrupt], Readready, 1) < 0)
				break;
			r[Interrupt] = Readready;
			for(j = 0; j < Secsize; j += 4){
				w = r[Data];
				p[0] = w;
				p[1] = w>>8;
				p[2] = w>>16;
				p[3] = w>>24;
				p += 4;
			}
		}
		if(awaitbit(&r[Interrupt], Datadone, 1) < 0)
			break;
		r[Interrupt] = Datadone;
	}
	qunlock(c);
	return i * Secsize;
}

SDifc sdhcibcmifc = {
	"sdhci",			/* name */

	sdhcipnp,			/* pnp */
	nil,				/* enable */
	nil,				/* disable */

	sdhciverify,			/* verify */
	sdhcionline,			/* online */
	nil,				/* rio */
	nil,				/* rctl */
	nil,				/* wctl */

	sdhcibio,			/* bio */
	nil,				/* probe */
	nil,				/* clear */
	nil,				/* rtopctl */
	nil,				/* wtopctl */
};

/*
 * Drive the SDIO transport end to end: bring a function up, read the
 * card common control registers with CMD52, write and read a register
 * back, then move a buffer both ways with CMD53 and check it survived.
 *
 * Not run by default.  Bringing SDIO up resets this controller and
 * issues CMD0/CMD5, which an SD memory card sitting on it would not
 * enjoy; on a Pi the card is on SDHOST and there is no conflict, but
 * that is a property of the board's wiring rather than of this file.
 * Build with -DSDIOTEST.
 */
#ifdef SDIOTEST
void
sdiocheck(void)
{
	static uchar blkbuf[Secsize], blkback[Secsize];
	uchar buf[64], back[64];
	int nfn, rev, i, v;

	v = 0;

	nfn = sdioinit();
	if(nfn < 0){
		print("SDIO-NONE bring-up stopped at %s\n",
			nfn == -2? "CMD3 (relative address)":
			nfn == -3? "CMD7 (select)":
			"CMD0/CMD5 (no I/O function answered)");
		return;
	}
	print("sdio: %d I/O function(s), rca %#ux\n", nfn, sdhcictlr.rca);

	rev = sdiocmd52(0, 0x00, 0, 0);		/* CCCR revision */
	if(rev < 0){
		print("SDIO-FAIL CMD52 read of CCCR revision\n");
		return;
	}
	print("sdio: CCCR revision %#2.2ux\n", rev);

	/* Enable function 1 and wait for it to report ready. */
	if(sdiocmd52(0, 0x02, 1, 1<<1) < 0){
		print("SDIO-FAIL CMD52 write of IOEx\n");
		return;
	}
	for(i = 0; i < 100; i++){
		v = sdiocmd52(0, 0x03, 0, 0);	/* IORx */
		if(v < 0){
			print("SDIO-FAIL CMD52 read of IORx\n");
			return;
		}
		if(v & (1<<1))
			break;
		delay(1);
	}
	if((v & (1<<1)) == 0){
		print("SDIO-FAIL function 1 never became ready\n");
		return;
	}

	for(i = 0; i < sizeof buf; i++)
		buf[i] = 0xa0 + i;
	memset(back, 0, sizeof back);
	if(sdiocmd53(1, 0x400, 1, 0, 1, buf, sizeof buf) != sizeof buf){
		print("SDIO-FAIL CMD53 write\n");
		return;
	}
	if(sdiocmd53(1, 0x400, 0, 0, 1, back, sizeof back) != sizeof back){
		print("SDIO-FAIL CMD53 read\n");
		return;
	}
	if(memcmp(buf, back, sizeof buf) != 0){
		print("SDIO-FAIL CMD53 byte mode read back %#2.2ux %#2.2ux, wrote %#2.2ux %#2.2ux\n",
			back[0], back[1], buf[0], buf[1]);
		return;
	}

	/*
	 * Block mode as well, which takes a different path through
	 * sdiocmd53: the block count goes in Blksizecnt, Tmblkcnt is set,
	 * and the transfer waits on Readready/Writeready per block rather
	 * than moving one run of bytes.  ether4330 uploads firmware this
	 * way, so it is worth exercising.
	 */
	for(i = 0; i < Secsize; i++)
		blkbuf[i] = 0x5a ^ i;
	memset(blkback, 0, Secsize);
	if(sdiocmd53(1, 0x800, 1, 1, 1, blkbuf, 1) != 1){
		print("SDIO-FAIL CMD53 block write\n");
		return;
	}
	if(sdiocmd53(1, 0x800, 0, 1, 1, blkback, 1) != 1){
		print("SDIO-FAIL CMD53 block read\n");
		return;
	}
	if(memcmp(blkbuf, blkback, Secsize) != 0){
		print("SDIO-FAIL CMD53 block mode read back %#2.2ux %#2.2ux, wrote %#2.2ux %#2.2ux\n",
			blkback[0], blkback[1], blkbuf[0], blkbuf[1]);
		return;
	}
	print("SDIO-OK CMD52 and CMD53 carried data through function 1, byte and block mode\n");
}
#endif
