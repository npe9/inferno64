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
extern void gpiopull(int, int);		/* gpiobcm.c: 0 none, 1 down, 2 up */
extern int mboxgetgpio(int, int*);	/* mailbox.c */
int sdiocmd52(int, int, int, int);	/* defined below; sdioinit configures the card with it */
static void put4le(uchar*, u32);	/* defined below, used by the clm loader */
int sdiosetvar(char*, void*, int);
static void wlrxstart(void);	/* the frame reader, defined below */
extern int mboxsetgpio(int, int);	/* mailbox.c */

extern int mboxgetclock(int, u32*);	/* mailbox.c: firmware clock rate */

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

	Maxspeedmhz	= 25,	/* SD default speed */
	Emmcclkid	= 1,	/* firmware clock id for the EMMC/SD controller */
	Hispeedmhz	= 50,	/* what CMD6's high-speed function allows */
	Fnhispeed	= 1,	/* group 1 function number for high speed */
	Timeout		= 1000000,	/* bounded register polls */
	Idhz		= 400000,	/* identification runs at 400kHz or less */
	Sb32bit		= 0x8000,	/* backplane: ask for 32-bit access */
	Hctlhsen	= 1<<2,		/* Control0: high speed */
	Ccccbusifc	= 0x07,		/* CCCR: bus interface control */
	Ccchighspeed	= 0x13,		/* CCCR: high speed */
	Cccioenable	= 0x02,
	Cccioready	= 0x03,
	Cccintenable	= 0x04,
	Cccioabort	= 0x06,
	Fbr1		= 0x100,	/* function 1 base register block */
	Fbr2		= 0x200,
	Fbrblksize	= 0x10,		/* offset of block size within an FBR */
	Clkcsr		= 0x1000e,	/* fn1: backplane clock control */
	ForceALP	= 0x01,
	ReqALP		= 0x08,
	Nohwreq		= 0x20,
	ALPavail	= 0x40,
	HTavail		= 0x80,
	Ioctrl		= 0x408,	/* core control registers */
	Resetctrl	= 0x800,
	Coreinfo	= 0x00,		/* socram registers */
	Bankidx		= 0x10,
	Bankinfo	= 0x40,
	Bankpda		= 0x44,
	ARMcm3		= 0x82a,	/* core ids */
	ARM7tdmi	= 0x825,
	ARMcr4		= 0x83e,
	Socram		= 0x80e,
	Chipcommon	= 0x800,
	D11		= 0x812,
	Sdiocore	= 0x829,
	Cr4Cpuhalt	= 0x20,
	Pullups		= 0x1000f,	/* fn1: chip pull-ups */
	Gpiopullup	= 0x58,		/* chipcommon */
	Gpiopulldown	= 0x5c,
	ForceHT		= 0x02,
	ReqHT		= 0x10,
	Intmask		= 0x24,		/* sdio core registers */
	Sbmboxdata	= 0x48,
	Fcchange	= 1<<5,
	FrameInt	= 1<<6,
	MailboxInt	= 1<<7,
	Intstatus	= 0x20,		/* sdio core */
	Sbmbox		= 0x40,
	Hostmboxdata	= 0x4c,
	Cccintpend	= 0x05,		/* CCCR: interrupt pending */
	Framectl	= 0x1000d,	/* fn1 */
	Rfhalt		= 0x01,
	Rfrmcnt		= 0x1001b,
	Sdpcmsz		= 12,		/* the SDPCM header */
	Cmdsz		= 16,		/* the CDC control header */
	GetVar		= 262,
	SetVar		= 263,
	Sbwsize		= 0x8000,	/* backplane window size */
	Sbaddr		= 0x1000a,	/* fn1: backplane window address, 3 bytes */
	Enumbase	= 0x18000000,	/* SI enumeration space */
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
/*
 * Why the last command failed, recorded before the error bits are
 * cleared.
 *
 * "CMD5 got no response" is two different findings wearing one code.
 * The controller timing out with Interrupt still empty means nothing on
 * the bus answered at all; the controller raising Interr means it saw a
 * response and rejected it -- a CRC or a timeout it detected itself --
 * and those point at different halves of the problem.  sdhcicmd clears
 * Interrupt on its way out (write-1-to-clear), so the evidence has to
 * be taken before that or it is gone.
 */
static u32 sdhcilastint, sdhcilaststat;
/*
 * And the same for the data phase of CMD53.  The command completing and
 * the data arriving are separate events with separate ways to fail, and
 * "CMD53 read" named neither.
 */
static char *sdio53why = "";
static u32 sdio53int, sdio53stat, sdio53resp;

/*
 * The block size the SDIO functions are programmed for.  512 until
 * something sets the functions up; sdiocheck lowers it to 64, which is
 * what this part wants and what ether4330 uses.
 */
static int sdioblksize = Secsize;

/*
 * Widen the bus to four bits and raise the clock to 25MHz.
 *
 * This was off while the "intermittent" CMD53 failures were chased, and
 * those turned out to be unmapped register holes in chipcommon, not the
 * bus -- so the narrow slow bus was never implicated and there is no
 * reason to keep it.  At 400kHz with one block per command the firmware
 * upload took the better part of twenty minutes, which is slow enough to
 * distort every experiment that follows it.
 */
static int sdiofast = 1;
static char *sdhcilastwhy = "";

/*
 * Clear the command line after a failed command.
 *
 * A command that errors or times out leaves Cmdinhibit set, and the
 * Simplified Spec is explicit that software must reset the CMD line to
 * clear it.  This driver never did, so the FIRST failure wedged the
 * controller: every command after it stopped at "the command line never
 * went idle", for the life of the boot.
 *
 * That is not a cosmetic bug.  It meant one CMD5 timeout was the whole
 * basis for "no I/O function answered" -- the three retries after it
 * could not have reached the bus whatever was on the far end -- and on
 * the card path a single transient error would take the disk away and
 * never give it back.
 */
int sdhcinrecover;

static void
sdhcirecover1(Ctlr *c, u32 flags)
{
	u32 *r = c->r;
	u32 rst;

	rst = Srstcmd;
	if(flags & Cmdisdata)
		rst |= Srstdata;
	r[Control1] |= rst;
	awaitbit(&r[Control1], rst, 0);
	r[Interrupt] = r[Interrupt];
}

/*
 * Every CMD/DAT-line reset, counted.
 *
 * The frame reader now issues a read whether or not a frame is waiting,
 * so a read against an empty queue happens about 140 times a second.  If
 * an empty queue answered with a bus error rather than a zero length,
 * that idle loop would be quietly driving a controller reset at the same
 * rate, on the bus every command travels over -- indistinguishable from
 * the outside from a stalled control channel.  Collapsing "nothing to
 * read" and "the read failed" into one branch made that unaskable, so
 * they are counted apart.
 */
static void
sdhcirecover(Ctlr *c, u32 flags)
{
	sdhcinrecover++;
	sdhcirecover1(c, flags);
}

static int
sdhcicmd(Ctlr *c, int cmd, u32 arg, u32 flags)
{
	u32 *r = c->r;

	if(awaitbit(&r[Status], Cmdinhibit, 0) < 0){
		sdhcilastwhy = "the command line never went idle";
		sdhcilastint = r[Interrupt];
		sdhcilaststat = r[Status];
		return -1;
	}
	if(flags & Cmdisdata)
		if(awaitbit(&r[Status], Datinhibit, 0) < 0){
			sdhcilastwhy = "the data line never went idle";
			sdhcilastint = r[Interrupt];
			sdhcilaststat = r[Status];
			return -1;
		}
	r[Interrupt] = r[Interrupt];		/* clear stale status (w1c) */
	r[Arg1] = arg;
	r[Cmdtm] = (cmd << 24) | flags;
	if(awaitbit(&r[Interrupt], Cmdcomplete|Interr, 1) < 0){
		sdhcilastwhy = "nothing answered: no completion and no error";
		sdhcilastint = r[Interrupt];
		sdhcilaststat = r[Status];
		sdhcirecover(c, flags);
		return -1;
	}
	if(r[Interrupt] & Interr){
		sdhcilastwhy = "the controller rejected the response";
		sdhcilastint = r[Interrupt];
		sdhcilaststat = r[Status];
		r[Interrupt] = r[Interrupt];
		sdhcirecover(c, flags);
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
	u32 basehz, fwhz;
	int n;

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
	 *
	 * Bits 16-19 are the data-timeout exponent, and 0xe is the
	 * largest the field can express -- 0xf is reserved -- so the
	 * timeout is 2**27 clocks.  It is set to the maximum on purpose.
	 * Linux carries SDHCI_QUIRK_DATA_TIMEOUT_USES_SDCLK for this
	 * part, meaning the counter runs off SDCLK rather than the
	 * separate timeout clock, so the wall-clock timeout shortens by
	 * whatever factor the divider is later raised by: 335s at the
	 * 400kHz identification rate becomes about 5s once sdhcispeed()
	 * has moved to 26MHz.  Five seconds is still far longer than any
	 * block transfer, and there is nothing to recompute because the
	 * field is already at its maximum -- but it is the reason
	 * sdhcispeed() masks only bits 8-15 and leaves this alone.
	 */
	/*
	 * The identification divider, computed from the base clock rather
	 * than assumed.
	 *
	 * This was 0x80 with a comment saying it was "slow enough from any
	 * plausible base clock on this part".  It is not.  0x80 is the
	 * 8-bit divided-clock form, dividing by 2*N = 256, and the BCM2837
	 * runs this controller from a 250MHz core clock: 977kHz, well over
	 * the 400kHz ceiling identification has to observe.  A memory card
	 * tolerated it, which is why it survived -- and CMD0 carries no
	 * response, so nothing before CMD5 can fail and nothing before
	 * CMD5 could have shown it.
	 *
	 * Eight bits cannot express the divider this needs: 250MHz down to
	 * 400kHz is a divide of 625, so N is 313, past the 255 the field
	 * holds.  SDHCI 3.0 keeps the top two bits of a 10-bit divider in
	 * Control1 bits 6-7, and this controller is 3.0.
	 *
	 * If the base clock cannot be established, keep the old 0x80: a
	 * wrong-but-working card path is better than refusing to start.
	 */
	basehz = 0;
	if(((r[Capabilities] >> 8) & 0xff) != 0)
		basehz = ((r[Capabilities] >> 8) & 0xff) * 1000000;
	else if(mboxgetclock(Emmcclkid, &fwhz) == 0)
		basehz = fwhz;
	if(basehz == 0){
		n = 0x80;
		print("sdhci: no base clock; identification divider left at 0x80\n");
	}else{
		for(n = 1; n < 0x400; n++)
			if(basehz <= 2*n*Idhz)
				break;
		print("sdhci: base clock %ud Hz, identification divider %d "
			"(%ud Hz)\n", basehz, n, basehz/(2*n));
	}
	r[Control1] = ((n & 0xff) << 8) | (((n >> 8) & 3) << 6) |
		(0xe << 16) | Clkintlen;
	if(awaitbit(&r[Control1], Clkstable, 1) < 0)
		return -1;
	r[Control1] |= Clken;
	/*
	 * A card must see clock before it is spoken to: the SD spec asks
	 * for at least 74 cycles, which at the identification rate is
	 * under a millisecond.  There was no wait here at all.
	 */
	delay(2);

	/*
	 * Status is recorded but no interrupt is enabled: Irptmask lets
	 * the bits set in Interrupt so the polls below can read them,
	 * Irpten is what would actually assert IRQ 62, and it stays 0.
	 * Nothing calls intrenable(62) either, so the two agree -- an
	 * interrupt armed at the controller with no handler to dispatch
	 * it is the quiet fault that cost this port the console.
	 */
	r[Irptmask] = ~0;
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
/*
 * Leave the identification divider behind.
 *
 * Identification runs at 400kHz or less; default speed is 25MHz, and
 * the card has been in transfer state since SELECT, so there is no
 * reason to stay slow.  The divider field is the 8-bit "divided clock"
 * form in Control1 bits 8-15: SDCLK is the base clock over 2*N, with
 * N of 0 meaning the base clock undivided.
 *
 * Where the base clock comes from is the interesting part, and it is
 * not one place.  The capabilities register carries it in bits 8-15,
 * in MHz, and a real BCM2835's Arasan does not report a usable one
 * there at all: Linux marks brcm,bcm2835-sdhci with missing_caps in
 * drivers/mmc/host/sdhci-iproc.c and substitutes a table of its own,
 * and that table sets no base-clock field either.  On the board the
 * number has to come from the firmware, the same way UARTCLK does.
 *
 * QEMU used to answer 52 there (capareg 0x52134b4), so this driver
 * took a path the board never will and passed.  Patch 0026 clears the
 * field for the Arasan and leaves the Pi 4's emmc2 alone, because
 * sdhci-iproc does not mark that one missing_caps -- so the firmware
 * path below is what runs here now, and the capabilities path above it
 * is what runs on raspi4.  Both are exercised, each on the controller
 * that takes it.
 *
 * So ask capabilities first and the firmware second.  The marker names
 * which answered, because the answers differ and a log that did not
 * say would be unreadable later: the firmware reports the EMMC clock
 * at 50MHz and capabilities said 52, and those pick different
 * dividers -- against a 50MHz ceiling 50 runs undivided, and 52 falls
 * to 52/4 and runs at 13.
 *
 * The sequence is mandatory and is the reason this is not one write.
 * SDCLK must be stopped before the divider changes and restarted after
 * it is stable; changing the divider under a running clock is what the
 * SDHCI specification forbids and what silicon punishes.  QEMU
 * enforces the important half of it -- sdhci_can_issue_command()
 * refuses every command while SDHC_CLOCK_IS_ON is false -- so failing
 * to restart the clock here stops the board dead rather than passing
 * quietly, which is the one part of this an emulator can check.
 *
 * What it cannot check is the rate.  Nothing in the model times a
 * transfer against SDCLK, so the divider value itself has no
 * observable effect; a card that would need 40 clocks and gets 4 reads
 * identically here.  The marker says ACCEPTED for that reason.
 */
static void
sdhcispeed(Ctlr *c, int maxmhz)
{
	u32 *r = c->r;
	u32 ctl, hz;
	int basemhz, n;
	char *src;

	src = "capabilities";
	basemhz = (r[Capabilities] >> 8) & 0xff;
	if(basemhz == 0){
		/*
		 * What a real BCM2835 does.  Ask the firmware for the
		 * EMMC clock instead; staying at the identification
		 * divider would leave the card running at 400kHz for
		 * the life of the boot.
		 */
		src = "firmware clock 1";
		if(mboxgetclock(Emmcclkid, &hz) < 0){
			print("SDHCI-SPEED-NONE no base clock from capabilities "
				"and none from the firmware; staying at the "
				"identification divider\n");
			return;
		}
		basemhz = hz / 1000000;
		if(basemhz == 0){
			print("SDHCI-SPEED-NONE firmware reports an EMMC clock "
				"below 1MHz (%ud Hz)\n", hz);
			return;
		}
	}
	/*
	 * Smallest N with base/(2N) <= maxmhz, and N of 0 (undivided)
	 * only if the base is already slow enough.
	 */
	for(n = 0; n < 0x80; n++)
		if(n == 0){
			if(basemhz <= maxmhz)
				break;
		}else if(basemhz <= 2*n*maxmhz)
			break;

	ctl = r[Control1];
	r[Control1] = ctl & ~Clken;			/* stop SDCLK first */
	ctl = (ctl & ~(0xff << 8)) | (n << 8);
	r[Control1] = ctl & ~Clken;			/* then the divider */
	if(awaitbit(&r[Control1], Clkstable, 1) < 0){
		print("SDHCI-SPEED-FAIL clock did not restabilise at divider %d\n", n);
		return;
	}
	r[Control1] |= Clken;				/* and start it again */

	if(n == 0)
		print("SDHCI-SPEED-ACCEPTED base %dMHz from %s undivided, "
			"ceiling %dMHz\n", basemhz, src, maxmhz);
	else
		print("SDHCI-SPEED-ACCEPTED base %dMHz from %s / %d = about "
			"%dMHz, ceiling %dMHz (was the identification divider "
			"0x80)\n", basemhz, src, 2*n, basemhz/(2*n), maxmhz);
}

/*
 * Ask the card for high speed, which is what lifts the ceiling from
 * 25MHz to 50.
 *
 * CMD6 is two commands wearing one number.  Bit 31 of the argument
 * picks the mode: clear is "check", which reports what the card can do
 * and changes nothing, and set is "switch", which selects.  The other
 * 24 bits are six four-bit function groups, 0xf meaning "leave this
 * one alone"; group 1 is the bus speed, and function 1 there is high
 * speed.  So 0x00fffff1 asks and 0x80fffff1 sets.
 *
 * Both forms answer with the same 64-byte status block over the data
 * lines, and it is worth reading rather than trusting the R1: a card
 * that cannot do high speed answers the switch without an error and
 * simply reports function 0 back.  Nothing fails; you just quietly do
 * not get what you asked for, and then raise the host clock past what
 * the card agreed to.  So the check reads the support bitmap first --
 * group 1 support is bytes 12 and 13, big-endian, bit 1 being high
 * speed -- and reads the selection back afterwards, from the low
 * nibble of byte 16.
 *
 * Returns 1 only if the card said it supports high speed and then
 * reported it selected.  Anything else leaves the caller at 25MHz,
 * which is always safe.
 *
 * NOTE, because it is the obvious next line and it is wrong here: do
 * not set the host's High Speed Enable, Control0 bit 2.  The standard
 * sequence pairs CMD6 with that bit, but this part is one of the ones
 * where it does not work -- Linux carries SDHCI_QUIRK_NO_HISPD_BIT for
 * brcm,bcm2835-sdhci (drivers/mmc/host/sdhci-iproc.c).  The card is
 * told through CMD6 and the host follows through the divider alone,
 * which is why nothing below touches Control0.
 */

/*
 * One command whose answer comes back over the data lines rather than
 * in a response register, read into b.  CMD6 and ACMD13 both work this
 * way and both return 64 bytes.
 *
 * Every failure exit resets the data circuit before returning, and
 * that is not tidiness.  A command that was accepted and then did not
 * finish leaves the card still driving the data lines; the caller here
 * prints a marker and card init carries on, and the next command that
 * sets Cmdisdata will sit on Datinhibit until its bounded poll expires.
 * One abandoned status block would cost every later transfer a
 * timeout.  Srstdata is the specification's answer -- write it, and the
 * controller clears it when the data circuit is back -- and clearing
 * the status afterwards leaves nothing stale for the next command to
 * read as its own.
 *
 * None of this is reachable under QEMU, where a command completes
 * inside the register write and no poll ever expires.  It is written
 * from the specification rather than from a test for exactly that
 * reason.
 */
static int
sdhcistatusblock(Ctlr *c, int cmd, u32 arg, uchar *b, int n)
{
	u32 *r = c->r;
	u32 w;
	int i;

	r[Blksizecnt] = (1<<16) | n;
	if(sdhcicmd(c, cmd, arg,
	    Resp48|Cmdcrcchk|Cmdixchk|Cmdisdata|Tmblkcnt|Tmdatdirread) < 0)
		goto reset;
	if(awaitbit(&r[Interrupt], Readready, 1) < 0)
		goto reset;
	r[Interrupt] = Readready;
	for(i = 0; i < n; i += 4){
		w = r[Data];
		b[i] = w;
		b[i+1] = w>>8;
		b[i+2] = w>>16;
		b[i+3] = w>>24;
	}
	if(awaitbit(&r[Interrupt], Datadone, 1) < 0)
		goto reset;
	r[Interrupt] = Datadone;
	return 0;

reset:
	r[Control1] |= Srstdata;
	awaitbit(&r[Control1], Srstdata, 0);
	r[Interrupt] = r[Interrupt];
	return -1;
}

static int
sdhcihispeed(Ctlr *c)
{
	uchar b[64];
	int support, selected;

	if(sdhcistatusblock(c, 6, 0x00fffff1, b, sizeof b) < 0){
		print("SDHCI-HISPEED-NONE card did not answer the CMD6 check\n");
		return 0;
	}
	support = (b[12] << 8) | b[13];
	if((support & (1<<Fnhispeed)) == 0){
		print("SDHCI-HISPEED-NONE card supports group 1 %#ux, no high speed\n",
			support);
		return 0;
	}
	if(sdhcistatusblock(c, 6, 0x80fffff1, b, sizeof b) < 0){
		print("SDHCI-HISPEED-FAIL card did not answer the CMD6 switch\n");
		return 0;
	}
	selected = b[16] & 0xf;
	if(selected != Fnhispeed){
		print("SDHCI-HISPEED-FAIL asked for function %d, card selected %d\n",
			Fnhispeed, selected);
		return 0;
	}
	print("SDHCI-HISPEED-ACCEPTED card supports group 1 %#ux and selected "
		"high speed; ceiling now %dMHz\n", support, Hispeedmhz);
	return 1;
}

/*
 * Move the card and the host to the four-bit data bus.
 *
 * ACMD6 needs the card in transfer state, so this runs after SELECT.
 * Only one order is safe: the card accepts the width first, the host's
 * Control0 bit is set second.  A host reading four lines from a card
 * still driving one does not fail -- it reads whatever the three idle
 * lines happen to be sitting at, which is corruption rather than an
 * error, and the reason this is written as a sequence rather than two
 * independent writes.
 *
 * Checked by reading it back rather than by assuming the command took.
 * ACMD13 (SD_STATUS) returns 64 bytes, transmitted most significant
 * first, whose first byte carries DAT_BUS_WIDTH in bits 7:6 -- 0 is
 * one bit, 2 is four.  The card reporting 4 is what says it accepted;
 * the block reads that follow are what say the host half agrees.
 *
 * QEMU used to record the width in sd_status[0] and read it nowhere,
 * so any sequence passed and this check could only report ACCEPTED.
 * tools/qemu-patches/0017 closes that: the host's width is pushed to
 * the card through the SD bus, and a data transfer whose two ends
 * disagree is refused with a guest error rather than served.  Omitting
 * the ACMD6 above while still setting Control0 now fails here and
 * fails every later block read, which is what makes this OK rather
 * than ACCEPTED.
 *
 * Still not shown, and not showable: that four lines are electrically
 * driven.  The model has no wire to narrow.  What is verified is the
 * sequence and the agreement, which is what a driver can get wrong.
 */
static int
sdhciwiden(Ctlr *c)
{
	u32 *r = c->r;
	uchar b[64];
	int width;

	if(sdhcicmd(c, 55, c->rca<<16, Resp48|Cmdcrcchk|Cmdixchk) < 0){	/* APP_CMD */
		print("SDHCI-4BIT-FAIL APP_CMD refused\n");
		return -1;
	}
	if(sdhcicmd(c, 6, 2, Resp48|Cmdcrcchk|Cmdixchk) < 0){		/* ACMD6 */
		print("SDHCI-4BIT-FAIL SET_BUS_WIDTH refused\n");
		return -1;
	}
	r[Control0] |= Hcdatawidth4;

	if(sdhcicmd(c, 55, c->rca<<16, Resp48|Cmdcrcchk|Cmdixchk) < 0){
		print("SDHCI-4BIT-FAIL APP_CMD before SD_STATUS refused\n");
		return -1;
	}
	if(sdhcistatusblock(c, 13, 0, b, sizeof b) < 0){		/* ACMD13 */
		print("SDHCI-4BIT-FAIL SD_STATUS did not arrive\n");
		return -1;
	}

	width = (b[0] >> 6) & 3;
	if(width != 2){
		print("SDHCI-4BIT-FAIL card reports DAT_BUS_WIDTH %d, wanted 2 (four bit)\n",
			width);
		return -1;
	}
	print("SDHCI-4BIT-OK card reports DAT_BUS_WIDTH four bit and the host "
		"agrees; a transfer with the two disagreeing is refused\n");
	return 0;
}

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
	/*
	 * Which branch ran, and what it produced.  There are two decodes
	 * here and a boot exercises exactly one of them; a log that does
	 * not say which cannot be read as evidence for either.
	 */
	print("sdhci: csd v%d, %llud sectors\n", ((b[0]>>6)&3)+1, c->sectors);

	if(sdhcicmd(c, 7, c->rca<<16, Resp48busy|Cmdcrcchk|Cmdixchk) < 0)	/* SELECT */
		return 0;
	if(sdhcicmd(c, 16, Secsize, Resp48|Cmdcrcchk|Cmdixchk) < 0)	/* SET_BLOCKLEN */
		return 0;
	sdhciwiden(c);
	/*
	 * Order: the card must agree to high speed before the host
	 * clock goes past what default speed allows.  Raising the
	 * clock first would run the card outside its agreed timing,
	 * which on real silicon is data corruption rather than an
	 * error.
	 */
	sdhcispeed(c, sdhcihispeed(c)? Hispeedmhz: Maxspeedmhz);
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

	/*
	 * DISCONNECT THIS CONTROLLER FROM THE CARD PINS FIRST.
	 *
	 * The VideoCore firmware boots off the SD card through this very
	 * controller, so it hands the kernel a machine with GPIO 48-53
	 * still in alt3 -- the card wired to the Arasan.  Bringing SDIO up
	 * on 34-39 without undoing that leaves the controller attached to
	 * two sets of pads at once, and it answers on neither: CMD5 times
	 * out with the bus idle, every time.
	 *
	 * This was found the hard way, as an unexplained "flip 48-53 to
	 * alt3 and straight back" that made the radio enumerate and which
	 * nothing here could account for.  The flip was irrelevant; the
	 * final write of alt0 was the whole of it.  9front does the same
	 * thing in one line and says why -- "disconnect emmc from SD card
	 * (connect sdhost instead)" -- which is also the answer to why
	 * SDHOST is unaffected: alt0 is where the card belongs anyway.
	 */
	for(i = 48; i <= 53; i++)
		gpiofsel(i, Alt0);

	for(i = 34; i <= 39; i++)
		gpiofsel(i, Alt3);
	/*
	 * And the pulls, which nothing here has ever set.
	 *
	 * gpiofsel changes a pin's function and says nothing about its
	 * pull, so these pads have been left however the firmware
	 * happened to leave them.  SDIO needs pull-ups on CMD and the
	 * data lines; the clock is driven by the host and wants none.  On
	 * SD1 that is 34 CLK, 35 CMD, 36-39 DAT0-3, which is the same
	 * arrangement Linux programs for this block.
	 *
	 * This is the first suspect for the data CRC error CMD53 now
	 * reports: a floating DAT0 gives exactly that -- the card drives
	 * the line, the bits do not survive the trip, and the command
	 * path over the same pads is unaffected because CMD52 carries no
	 * data phase.
	 */
	gpiopull(34, 0);			/* CLK: host-driven, no pull */
	for(i = 35; i <= 39; i++)
		gpiopull(i, 2);			/* CMD and DAT0-3: pull up */

	/*
	 * Say which step failed.
	 *
	 * Five different failures below all returned -1 and the caller
	 * reported every one of them as "CMD0/CMD5 (no I/O function
	 * answered)".  A controller that never initialised, a CMD0 that
	 * was not accepted, a CMD5 with no response, a card reporting
	 * zero I/O functions and a card that never set its ready bit are
	 * five different pieces of work, and the one code named the
	 * wrong one: it named the card, when the controller is just as
	 * likely.
	 */
	if(sdhcictlrinit(c) < 0){
		print("sdio: controller init failed\n");
		return -1;
	}
	/*
	 * Give the chip a long run of CLOCK before speaking to it.
	 *
	 * The accident that first made this work was an extra
	 * sdhcictlrinit() that failed: it had already enabled the bus
	 * clock and then spun in two bounded register polls, so the
	 * BCM43438 got a sustained stretch of clocked bus time before
	 * anything was asked of it.  Reproducing that as a reset and a
	 * 150ms wait did NOT work, and the difference says why -- that
	 * wait had the clock switched OFF.  What the chip wants is
	 * clock, not time.
	 *
	 * The SD spec asks for 74 cycles before the first command, which
	 * at 400kHz is under a millisecond, and sdhcictlrinit's delay(2)
	 * satisfies that comfortably.  This part plainly wants far more,
	 * so it gets 150ms of running clock -- about sixty thousand
	 * cycles.
	 */
	delay(150);
	/*
	 * Reset the card's I/O side before anything else.
	 *
	 * A warm reboot does not reset the radio: WL_ON stays high, the
	 * chip keeps running whatever firmware was uploaded, and it is
	 * still SELECTED from the previous bring-up.  CMD5 is only legal
	 * in the idle state, so on the second boot it comes back with a
	 * command timeout and the whole bring-up fails -- which is
	 * exactly what happened, and it would happen on every reboot
	 * after a successful load.
	 *
	 * CMD0 does not reliably reset an SDIO-only card; the spec's way
	 * is a CMD52 write of the RES bit to the I/O Abort register, CCCR
	 * 0x06.  CMD52 carries no relative address, so it reaches a card
	 * that is still selected from before.  On a cold boot the card is
	 * not selected and this write simply fails, which is why its
	 * result is ignored.
	 */
	sdiocmd52(0, Cccioabort, 1, 1<<3);
	delay(2);

	if(sdhcicmd(c, 0, 0, Respnone) < 0){		/* GO_IDLE */
		print("sdio: CMD0 (GO_IDLE) not accepted\n");
		return -1;
	}

	/*
	 * CMD5 with a zero argument asks what the card is; the R4 response
	 * carries the number of I/O functions in bits 30:28 and the
	 * voltage window it supports in bits 23:0.  Repeating CMD5 with
	 * that window set waits for bit 31, the ready bit.  R4 has neither
	 * a CRC nor a command index, so neither is checked.
	 */
	/*
	 * Ask more than once before concluding nothing is there.
	 *
	 * A chip that is awake but slow to settle and a chip that is
	 * absent give the same answer to a single CMD5, and one attempt
	 * has been the whole basis of "no I/O function" so far.  Four
	 * tries with a wait between them costs milliseconds and
	 * distinguishes them.
	 */
	for(i = 0; i < 4; i++){
		if(sdhcicmd(c, 5, 0, Resp48) == 0)
			break;
		print("sdio: CMD5 attempt %d failed -- %s "
			"(interrupt %#lux status %#lux)\n",
			i, sdhcilastwhy, (ulong)sdhcilastint,
			(ulong)sdhcilaststat);
		delay(100);
	}
	if(i == 4)
		return -1;
	ocr = r[Resp0];
	if(((ocr >> 28) & 7) == 0){
		print("sdio: CMD5 answered r4 %#lux: zero I/O functions\n",
			(ulong)ocr);
		return -1;			/* no I/O function here */
	}
	print("sdio: CMD5 r4 %#lux: %ld function(s), window %#lux\n",
		(ulong)ocr, (long)((ocr >> 28) & 7), (ulong)(ocr & 0x00ffffff));
	for(i = 0; i < 1000; i++){
		if(sdhcicmd(c, 5, ocr & 0x00ffffff, Resp48) < 0){
			print("sdio: CMD5 with the voltage window failed\n");
			return -1;
		}
		ocr = r[Resp0];
		if(ocr & 0x80000000)
			break;
	}
	if((ocr & 0x80000000) == 0){
		print("sdio: card never set its ready bit (r4 %#lux)\n",
			(ulong)ocr);
		return -1;
	}

	if(sdhcicmd(c, 3, 0, Resp48|Cmdcrcchk|Cmdixchk) < 0)	/* RELATIVE_ADDR */
		return -2;
	c->rca = r[Resp0] >> 16;
	if(sdhcicmd(c, 7, c->rca<<16, Resp48busy|Cmdcrcchk|Cmdixchk) < 0)
		return -3;				/* SELECT */

	/*
	 * Now configure the card the way a driver for this part does.
	 *
	 * High speed and a four-bit bus, then the same on the host side,
	 * then each function's block size in its FBR -- 64 for function
	 * 1, 512 for function 2 -- and function 1 enabled.  Identification
	 * ran at 400kHz because that is what identification is for; this
	 * chip is not a memory card and runs at 25MHz once selected.
	 *
	 * The block size goes in the FUNCTION's FBR, not just CCCR
	 * 0x10/0x11: 0x10 is function 0's own size and says nothing about
	 * what function 1 will send.
	 */
	/*
	 * Four-bit and 25MHz, or one bit at the identification rate.
	 *
	 * The reads are INTERMITTENT, not address-determined: 0x4c and
	 * 0x84 succeed while 0x40, 0x44, 0x48 and 0xc0 fail, and 0x20
	 * worked in one boot and failed in another.  That is a signalling
	 * problem, and the only thing here that could cause one is this:
	 * the bus was widened to four bits and the clock raised to 25MHz
	 * in the same change, with nothing checking that the CARD agreed
	 * to either.  If the host is four-bit and the card is not, every
	 * transfer is garbage in a way that looks exactly like this.
	 *
	 * sdiofast=0 keeps the slow, narrow bus that every earlier
	 * measurement was taken on, so the two can be compared.
	 */
	if(sdiofast){
		sdiocmd52(0, Ccchighspeed, 1, sdiocmd52(0, Ccchighspeed, 0, 0) | 2);
		sdiocmd52(0, Ccccbusifc, 1, 2);		/* four-bit bus */
		r[Control0] |= Hcdatawidth4 | Hctlhsen;
		sdhcispeed(c, Maxspeedmhz);
	}
	print("sdio: bus %s, CCCR 0x07 reads %#ux\n",
		sdiofast? "4-bit 25MHz" : "1-bit 400kHz",
		sdiocmd52(0, Ccccbusifc, 0, 0));

	sdiocmd52(0, Fbr1 + Fbrblksize, 1, 64);
	sdiocmd52(0, Fbr1 + Fbrblksize + 1, 1, 0);
	sdiocmd52(0, Fbr2 + Fbrblksize, 1, 512 & 0xff);
	sdiocmd52(0, Fbr2 + Fbrblksize + 1, 1, 512 >> 8);
	sdioblksize = 64;

	sdiocmd52(0, Cccioenable, 1, sdiocmd52(0, Cccioenable, 0, 0) | 1<<1);
	sdiocmd52(0, Cccintenable, 1, 0);
	for(i = 0; i < 100; i++){
		if(sdiocmd52(0, Cccioready, 0, 0) & 1<<1)
			break;
		delay(10);
	}
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
		/*
		 * The block size the FUNCTION is configured for, not 512.
		 *
		 * This said Secsize unconditionally, which is right only
		 * when the function's block size happens to be 512.  An
		 * SDIO function's block size is whatever CCCR 0x10/0x11
		 * and the FBR were programmed with -- 64 for this part,
		 * which is what ether4330 uses -- so the card sends
		 * 64-byte blocks while the controller was told to expect
		 * 512.  The symptom is a data CRC error together with a
		 * data end-bit error (interrupt 0x608000), because the
		 * controller is still waiting for the rest of a block the
		 * card already finished.
		 *
		 * Byte mode never saw this, which is why it survived: the
		 * only CMD53 that had ever worked was a four-byte read.
		 * The firmware upload is several hundred kilobytes of
		 * BLOCK writes and would have hit it immediately.
		 */
		blksize = fn == 2? Secsize : sdioblksize;
	}else{
		nblk = 1;
		blksize = n;
		if(blksize <= 0 || blksize > Secsize){
			sdio53why = "byte-mode length out of range";
			return -1;
		}
	}
	/*
	 * ONE BLOCK PER COMMAND.
	 *
	 * Multi-block with an incrementing address does not work on this
	 * controller and the reason is not known.  Measured, with the
	 * error recovery working so the numbers mean something: one block
	 * reads correctly; two, four and eight all fail with a data CRC;
	 * and eight blocks with the address held STILL succeed.  The host
	 * code is byte-identical in the failing and succeeding cases --
	 * only the incr bit in the command argument differs -- so it is
	 * not the transfer loop, and matching 9front's card setup (high
	 * speed, four-bit bus, the FBR block sizes) did not change it
	 * either.
	 *
	 * 9front reads 512 bytes as 8x64 with incr set, in corescan, and
	 * it works there, so this is a difference between that driver's
	 * data path and this one rather than something the chip forbids.
	 * The likely remaining difference is DMA: emmc.c streams the whole
	 * transfer, this drives PIO a block at a time.
	 *
	 * Rather than leave the transport broken for anything larger than
	 * 64 bytes, issue each block as its own CMD53.  Single block is
	 * measured good, the firmware upload is then correct if slow --
	 * 399344 bytes in 6240 commands -- and the fast path can come back
	 * once the cause is understood.  Correct and slow beats fast and
	 * wrong, and this is on the boot path once per boot.
	 */
	if(blockmode && nblk > 1){
		int done, k;

		for(done = 0; done < nblk; done++){
			k = sdiocmd53(fn, addr, write, 1, incr, p, 1);
			if(k != 1)
				return -1;
			p += blksize;
			if(incr)
				addr += blksize;
		}
		return nblk;
	}

	arg = (write & 1) << 31 | (fn & 7) << 28 | (blockmode & 1) << 27 |
		(incr & 1) << 26 | (addr & 0x1ffff) << 9 | (n & 0x1ff);

	c->r[Blksizecnt] = nblk << 16 | blksize;
	flags = Resp48|Cmdcrcchk|Cmdixchk|Cmdisdata|Tmblkcnt;
	if(!write)
		flags |= Tmdatdirread;
	if(nblk > 1)
		flags |= Tmmultiblock;
	if(sdhcicmd(c, 53, arg, flags) < 0){
		sdio53why = sdhcilastwhy;
		sdio53resp = 0;
		return -1;
	}
	/*
	 * CMD53 answers R5, whose bits 15:8 are the card's own verdict on
	 * the request: 15 CRC, 14 illegal command, 11 general error, 9
	 * invalid function, 8 OUT OF RANGE.  Nothing here has ever looked
	 * at it, so a card politely refusing a request looked exactly like
	 * a card that said nothing -- the data phase simply timed out and
	 * the reason was thrown away.
	 */
	sdio53resp = c->r[Resp0];
	/*
	 * The data port is 32 bits wide, so a byte-mode length that is not
	 * a multiple of four has a tail to assemble by hand rather than
	 * running off the end of the caller's buffer.
	 */
	for(i = 0; i < nblk; i++){
		if(write){
			if(awaitbit(&c->r[Interrupt], Writeready, 1) < 0){
				sdio53why = "the card never asked for data";
				sdio53int = c->r[Interrupt];
				sdio53stat = c->r[Status];
				sdhcirecover(c, flags);
				return -1;
			}
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
			if(awaitbit(&c->r[Interrupt], Readready, 1) < 0){
				sdio53why = "the card never offered data";
				sdio53int = c->r[Interrupt];
				sdio53stat = c->r[Status];
				/*
				 * Reset the DATA line too.
				 *
				 * Only sdhcicmd recovered, so a failure in
				 * THIS loop left Datinhibit set and every
				 * transfer afterwards reported "the data
				 * line never went idle" -- one bad read
				 * poisoning the whole run, exactly as the
				 * command line did before sdhcirecover
				 * existed.  It is why 4 and 8 blocks looked
				 * like a different fault from 2.
				 */
				sdhcirecover(c, flags);
				return -1;
			}
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

/*
 * Drive the card path on this controller?  Off: see sdhcionline().
 */
int sdhcicard = 0;

static int
sdhcionline(SDunit *u)
{
	Ctlr *c = u->dev->ctlr;
	int first;

	first = 0;
	if(!c->inited){
		c->inited = 1;
		/*
		 * NOT on a Pi 3B, where this controller has the Wi-Fi and
		 * SDHOST has the card.
		 *
		 * sdhcicardinit()'s first act is to route GPIO 48-53 to
		 * Alt3 unconditionally, which takes the card away from
		 * SDHOST.  On this board that card is /dev/sdN0, SDDEV in
		 * raspi3binit.b names it, /n/dos rides on it and
		 * tools/jtag/kinstall.sh installs kernels through it -- so
		 * stealing those pins costs the update path, and the
		 * recovery is a card reader or JTAG.
		 *
		 * sdhcicard is 0 by default for that reason.  Set it with
		 * "echo card 1 >/dev/sdH0/ctl" on a board that really does
		 * keep its card on this controller; the SDIO path does not
		 * need it and deliberately goes nowhere near those pins.
		 */
		if(sdhcicard){
			sdhcicardinit(c);	/* leaves c->sectors 0 if no card */
			first = 1;
		}
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

	/*
	 * More than one block goes as one command.
	 *
	 * CMD18/CMD25 stream consecutive blocks off a single address
	 * rather than paying a command, a response and a turnaround per
	 * block, which is most of the cost of a small read on real
	 * silicon.  The count goes in the top half of Blksizecnt,
	 * Tmmultiblock and Tmblkcnt say to use it, and Tmautocmd12 has
	 * the controller send the STOP_TRANSMISSION itself at the end:
	 * an open-ended multiple read that nothing stops leaves the card
	 * still sending, and the next command collides with it.
	 *
	 * The single-block path below is kept rather than folded into
	 * this one.  A one-block CMD18 is legal but pointless, and
	 * CMD17 is what the identification path and every existing
	 * check already exercise.
	 */
	if(nb > 1){
		arg = c->byteaddr? (u32)(bno*Secsize): (u32)bno;
		r[Blksizecnt] = ((u32)nb << 16) | Secsize;
		flags = Resp48|Cmdcrcchk|Cmdixchk|Cmdisdata|Tmblkcnt|
			Tmmultiblock|Tmautocmd12;
		if(!write)
			flags |= Tmdatdirread;
		if(sdhcicmd(c, write? 25: 18, arg, flags) < 0){
			qunlock(c);
			return 0;
		}
		for(i = 0; i < nb; i++){
			if(write){
				if(awaitbit(&r[Interrupt], Writeready, 1) < 0)
					break;
				r[Interrupt] = Writeready;
				for(j = 0; j < Secsize; j += 4){
					w = p[0] | p[1]<<8 | p[2]<<16 | p[3]<<24;
					r[Data] = w;
					p += 4;
				}
			}else{
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
		}
		/*
		 * A multi-block transfer that stopped part way through
		 * is a failure, not a short read.  The command moved one
		 * run of blocks off one address: the caller's buffer past
		 * the point it stopped holds whatever it held before, and
		 * reporting those bytes as having been read is worse than
		 * reporting nothing.  Any break above therefore counts the
		 * same as the completion timeout below.
		 */
		if(i < nb || awaitbit(&r[Interrupt], Datadone, 1) < 0)
			i = 0;
		r[Interrupt] = Datadone;
		qunlock(c);
		return i * Secsize;
	}

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
/*
 * Silicon Backplane access, ported from 9front's ether4330.c.
 *
 * The chip's cores hang off an internal bus the ARM cannot see; the only
 * way to them is a 32KB window that function 1 slides over the
 * backplane address space.  sbwindow() positions it and cfgreadl() and
 * cfgwritel() read and write one 32-bit register through it, with the
 * offset taken from the low fifteen bits of the address and Sb32bit set
 * to ask for a 32-bit access.
 */
static void
sbwindow(u32 addr)
{
	addr &= ~(Sbwsize-1);
	sdiocmd52(1, Sbaddr, 1, addr >> 8);
	sdiocmd52(1, Sbaddr + 1, 1, addr >> 16);
	sdiocmd52(1, Sbaddr + 2, 1, addr >> 24);
}

static u32
cfgreadl(u32 off)
{
	uchar p[4];

	memset(p, 0, sizeof p);
	if(sdiocmd53(1, (off & (Sbwsize-1)) | Sb32bit, 0, 0, 1, p, 4) != 4)
		return ~0;
	return p[0] | p[1]<<8 | p[2]<<16 | p[3]<<24;
}

static void
cfgwritel(u32 off, u32 v)
{
	uchar p[4];

	p[0] = v;
	p[1] = v >> 8;
	p[2] = v >> 16;
	p[3] = v >> 24;
	sdiocmd53(1, (off & (Sbwsize-1)) | Sb32bit, 1, 0, 1, p, 4);
}

/*
 * Put a core into reset, and take one out of it.  Both polls are bounded
 * here: 9front spins for ever on a chip that never answers, which on
 * this board would be a silent hang at boot with no console to see it.
 */
static void
sbdisable(u32 regs, int pre, int ioctl)
{
	int i;

	sbwindow(regs);
	if((cfgreadl(regs + Resetctrl) & 1) != 0){
		cfgwritel(regs + Ioctrl, 3|ioctl);
		cfgreadl(regs + Ioctrl);
		return;
	}
	cfgwritel(regs + Ioctrl, 3|pre);
	cfgreadl(regs + Ioctrl);
	cfgwritel(regs + Resetctrl, 1);
	microdelay(10);
	for(i = 0; i < 1000; i++){
		if(cfgreadl(regs + Resetctrl) & 1)
			break;
		microdelay(10);
	}
	if(i == 1000)
		print("sdio: core %#lux would not enter reset\n", (ulong)regs);
	cfgwritel(regs + Ioctrl, 3|ioctl);
	cfgreadl(regs + Ioctrl);
}

static void
sbreset(u32 regs, int pre, int ioctl)
{
	int i;

	sbdisable(regs, pre, ioctl);
	sbwindow(regs);
	for(i = 0; i < 1000; i++){
		if((cfgreadl(regs + Resetctrl) & 1) == 0)
			break;
		cfgwritel(regs + Resetctrl, 0);
		microdelay(40);
	}
	if(i == 1000)
		print("sdio: core %#lux would not leave reset\n", (ulong)regs);
	cfgwritel(regs + Ioctrl, 1|ioctl);
	cfgreadl(regs + Ioctrl);
}

/*
 * What corescan found, and what ramscan worked out from it.
 */
static struct {
	u32	chipcommon;
	u32	armctl;
	u32	armregs;
	u32	socramctl;
	u32	socramregs;
	u32	d11ctl;
	u32	sdregs;
	int	armcore;
	int	socramrev;
	int	chipid;
	int	chiprev;
	u32	socramsize;
	u32	rambase;
} sb;

/*
 * Walk the enumeration ROM and record where each core lives.
 *
 * Entries are 32-bit words tagged in their low nibble: 0x1 introduces a
 * core and carries its id, 0x5 is an address, 0xf ends the list.  Bit
 * 0xC0 of an address entry marks it a control register block rather
 * than the core's memory.  Read from the EROM pointer at
 * chipcommon+0xfc, not from the enumeration base -- chipcommon itself
 * is registers with unmapped holes and reading across it stalls the
 * backplane.
 */
static int
corescan(u32 erom)
{
	static uchar buf[512];
	int i, coreid, corerev;
	u32 addr;

	sbwindow(erom);
	memset(buf, 0, sizeof buf);
	if(sdiocmd53(1, (erom & (Sbwsize-1)) | Sb32bit, 0, 1, 1, buf,
	    sizeof buf / 64) != sizeof buf / 64){
		print("sdio: cannot read the EROM at %#lux\n", (ulong)erom);
		return -1;
	}
	coreid = corerev = 0;
	for(i = 0; i < sizeof buf; i += 4){
		if((buf[i] & 0xf) == 0xf)
			break;
		if((buf[i] & 0xf) == 0x1){
			if((buf[i+4] & 0xf) != 0x1)
				continue;
			coreid = (buf[i+1] | buf[i+2]<<8) & 0xfff;
			i += 4;
			corerev = buf[i+3];
			continue;
		}
		if((buf[i] & 0xf) != 0x5)
			continue;
		addr = (buf[i+1]<<8 | buf[i+2]<<16 | buf[i+3]<<24) & ~0xfff;
		switch(coreid){
		case Chipcommon:
			if((buf[i] & 0xc0) == 0)
				sb.chipcommon = addr;
			break;
		case ARMcm3:
		case ARM7tdmi:
		case ARMcr4:
			sb.armcore = coreid;
			if(buf[i] & 0xc0){
				if(sb.armctl == 0)
					sb.armctl = addr;
			}else if(sb.armregs == 0)
				sb.armregs = addr;
			break;
		case Socram:
			if(buf[i] & 0xc0)
				sb.socramctl = addr;
			else if(sb.socramregs == 0)
				sb.socramregs = addr;
			sb.socramrev = corerev;
			break;
		case Sdiocore:
			if((buf[i] & 0xc0) == 0)
				sb.sdregs = addr;
			break;
		case D11:
			if(buf[i] & 0xc0)
				sb.d11ctl = addr;
			break;
		}
	}
	return 0;
}

/*
 * How much RAM the chip has, and where, so the firmware has somewhere to
 * go.  Only the SOCRAM path is implemented: this part is an ARMcm3 with
 * SOCRAM revision 22, and the ARMcr4 variant belongs to other chips.
 */
static int
ramscan(void)
{
	u32 n, r, size;
	int banks, i;

	if(sb.socramrev <= 7 || sb.socramrev == 12){
		print("sdio: SOCRAM rev %d not supported\n", sb.socramrev);
		return -1;
	}
	sbreset(sb.socramctl, 0, 0);
	r = sb.socramregs;
	sbwindow(r);
	n = cfgreadl(r + Coreinfo);
	banks = (n >> 4) & 0xf;
	size = 0;
	for(i = 0; i < banks; i++){
		cfgwritel(r + Bankidx, i);
		n = cfgreadl(r + Bankinfo);
		size += 8192 * ((n & 0x3f) + 1);
	}
	sb.socramsize = size;
	sb.rambase = 0;
	if(sb.chipid == 43430){
		cfgwritel(r + Bankidx, 3);
		cfgwritel(r + Bankpda, 0);
	}
	print("sdio: SOCRAM rev %d, %d bank(s), %lud bytes at %#lux\n",
		sb.socramrev, banks, (ulong)sb.socramsize, (ulong)sb.rambase);
	return 0;
}

/*
 * Move a run of bytes to or from the chip's memory, sliding the window
 * as it goes.  This is what the firmware upload rides on.
 *
 * A transfer must not cross the end of the 32KB window, so each chunk
 * is clipped to what is left of the current one.
 */
static int
sbmem(int write, uchar *buf, int len, u32 off)
{
	u32 n;
	int nb;

	n = Sbwsize - (off & (Sbwsize-1));
	while(len > 0){
		if(n > len)
			n = len;
		sbwindow(off);
		/*
		 * Whole blocks through the block path, the remainder a
		 * byte-mode transfer.  Both are measured good against the
		 * EROM; the block size is the function's, 64.
		 */
		nb = n / sdioblksize;
		if(nb > 0){
			if(sdiocmd53(1, (off & (Sbwsize-1)) | Sb32bit, write, 1, 1,
			    buf, nb) != nb)
				return -1;
			buf += nb * sdioblksize;
			off += nb * sdioblksize;
			len -= nb * sdioblksize;
			n -= nb * sdioblksize;
		}
		if(n > 0){
			if(sdiocmd53(1, (off & (Sbwsize-1)) | Sb32bit, write, 0, 1,
			    buf, n) != n)
				return -1;
			buf += n;
			off += n;
			len -= n;
		}
		n = Sbwsize;
	}
	return 0;
}

/*
 * Bring the chip's backplane up: identify it, enumerate its cores, halt
 * the ARM that will run the firmware, reset the WLAN core, and find the
 * RAM.  This is 9front's sbinit, less the 4330/43362-specific drive
 * strength tweak, which does not apply to a 43430.
 */
static int
sbinit(void)
{
	u32 r, erom;

	memset(&sb, 0, sizeof sb);
	sbwindow(Enumbase);
	r = cfgreadl(Enumbase);
	sb.chipid = r & 0xffff;
	sb.chiprev = (r >> 16) & 0xf;
	if(sb.chipid != 43430){
		print("sdio: chip %#ux (%d) is not one this knows\n",
			sb.chipid, sb.chipid);
		return -1;
	}
	erom = cfgreadl(Enumbase + 63*4);
	if(corescan(erom) < 0)
		return -1;
	print("sdio: chip %d rev %d: chipcommon %#lux arm %#ux ctl %#lux "
		"regs %#lux d11 %#lux socram %#lux/%#lux sd %#lux\n",
		sb.chipid, sb.chiprev, (ulong)sb.chipcommon, sb.armcore,
		(ulong)sb.armctl, (ulong)sb.armregs, (ulong)sb.d11ctl,
		(ulong)sb.socramctl, (ulong)sb.socramregs, (ulong)sb.sdregs);
	if(sb.armctl == 0 || sb.d11ctl == 0 ||
	   (sb.armcore == ARMcm3 && (sb.socramctl == 0 || sb.socramregs == 0))){
		print("sdio: corescan did not find the essential cores\n");
		return -1;
	}
	if(sb.armcore == ARMcr4)
		sbreset(sb.armctl, Cr4Cpuhalt, Cr4Cpuhalt);
	else
		sbdisable(sb.armctl, 0, 0);
	sbreset(sb.d11ctl, 8|4, 4);
	if(ramscan() < 0)
		return -1;

	/*
	 * Settle the clock the way the reference does once the cores are
	 * in hand, and turn the chip's own pull-ups off.
	 */
	sdiocmd52(1, Clkcsr, 1, 0);
	microdelay(10);
	sdiocmd52(1, Clkcsr, 1, Nohwreq | ReqALP);
	for(r = 0; r < 500; r++){
		if(sdiocmd52(1, Clkcsr, 0, 0) & (HTavail|ALPavail))
			break;
		microdelay(10);
	}
	sdiocmd52(1, Clkcsr, 1, Nohwreq | ForceALP);
	microdelay(65);
	sdiocmd52(1, Pullups, 1, 0);
	sbwindow(sb.chipcommon);
	cfgwritel(sb.chipcommon + Gpiopullup, 0);
	cfgwritel(sb.chipcommon + Gpiopulldown, 0);

	/*
	 * The RAM write/read self-tests that lived here are gone.
	 *
	 * They did their job: 512 bytes proved writes worked at all, and
	 * 399344 bytes -- the firmware's exact size, with a
	 * position-dependent pattern -- proved sbmem's window clipping.
	 * But they ran on every bring-up, which meant 800KB of SDIO
	 * traffic at 400kHz before the real upload could start, and that
	 * looked exactly like a hang.  The evidence is in the commit
	 * history where it belongs, not in the boot path.
	 */
	return 0;
}

/*
 * The firmware load, driven from outside the kernel.
 *
 * The blob is 399344 bytes and lives on the card's FAT partition, and
 * the kernel has no way to read it: this runs before any filesystem
 * exists, the root filesystem is compiled into the image by a tool
 * (/os/port/mkroot) that is not in this tree, and embedding 400KB in
 * every kernel to reach it would be the wrong trade anyway.
 *
 * So the bytes come in from Limbo through #H's wifidata file, which is
 * a shell redirection at a point in the boot where /n/dos is already
 * mounted.  The kernel keeps only the cursor and the nvram, which is
 * small.
 *
 * Sequence, from 9front's fwload: ask for the ALP clock; zero the last
 * word of RAM; write the firmware from rambase upward; write the
 * condensed nvram at the TOP of RAM; put a length token in that last
 * word; then take the ARM out of reset, which starts it.
 */
static struct {
	int	up;		/* backplane is up */
	int	mode;		/* 0 idle, 1 firmware, 2 nvram */
	u32	off;		/* next firmware byte */
	uchar	nv[3072];
	int	nvlen;
	uchar	clm[8192];
	int	clmlen;
	int	err;
	int	enabled;
	int	said;		/* the firmware-ready mailbox seen */
	int	rxdebug;
	int	inited;
	int	joined;
	int	nev;
	uchar	bssid[6];
} fw;

int
sdiobringup(void)
{
	int nfn;

	fw.up = 0;
	nfn = sdioinit();
	if(nfn < 0){
		print("sdio: bring-up failed at %s\n",
			nfn == -2? "CMD3": nfn == -3? "CMD7": "CMD0/CMD5");
		return -1;
	}
	if(sbinit() < 0)
		return -1;
	fw.up = 1;
	fw.mode = 0;
	fw.off = 0;
	fw.nvlen = 0;
	fw.err = 0;
	return 0;
}

int
sdiofwbegin(int isnv)
{
	if(!fw.up)
		return -1;
	fw.mode = isnv;			/* 1 firmware, 2 nvram, 3 clm */
	fw.err = 0;
	if(isnv == 3)
		fw.clmlen = 0;
	else if(isnv == 2)
		fw.nvlen = 0;
	else{
		uchar z[4];

		/* the ALP clock, then zero the length word at the top of RAM */
		sdiocmd52(1, Clkcsr, 1, ReqALP);
		for(isnv = 0; isnv < 500; isnv++){
			if(sdiocmd52(1, Clkcsr, 0, 0) & ALPavail)
				break;
			microdelay(10);
		}
		memset(z, 0, sizeof z);
		sbmem(1, z, 4, sb.rambase + sb.socramsize - 4);
		fw.off = 0;
	}
	return 0;
}

int
sdiofwdata(uchar *p, int n)
{
	if(!fw.up || fw.mode == 0 || fw.err)
		return -1;
	if(fw.mode == 3){
		if(fw.clmlen + n > sizeof fw.clm){
			fw.err = 1;
			return -1;
		}
		memmove(fw.clm + fw.clmlen, p, n);
		fw.clmlen += n;
		return n;
	}
	if(fw.mode == 2){
		if(fw.nvlen + n > sizeof fw.nv){
			fw.err = 1;
			return -1;
		}
		memmove(fw.nv + fw.nvlen, p, n);
		fw.nvlen += n;
		return n;
	}
	/*
	 * Pad the tail to a word.  Every chunk but the last is a multiple
	 * of four in practice, and sbmem wants whole words for a 32-bit
	 * window access.
	 */
	while(n & 3)
		p[n++] = 0;
	if(sbmem(1, p, n, sb.rambase + fw.off) < 0){
		print("sdio: firmware write failed at %lud\n", (ulong)fw.off);
		fw.err = 1;
		return -1;
	}
	fw.off += n;
	return n;
}

/*
 * Strip comments and blank lines from the nvram file, turning each line
 * into a NUL-terminated string, which is the form the firmware wants.
 * 9front calls this condense().
 */
static int
condense(uchar *buf, int n)
{
	uchar *p, *ep, *lp, *op;
	int c, skipping;

	skipping = 0;
	ep = buf + n;
	op = buf;
	lp = buf;
	for(p = buf; p < ep; p++){
		switch(c = *p){
		case '#':
			skipping = 1;
			break;
		case '\0':
		case '\n':
			skipping = 0;
			if(op != lp){
				*op++ = '\0';
				lp = op;
			}
			break;
		case '\r':
			break;
		default:
			if(!skipping)
				*op++ = c;
			break;
		}
	}
	if(op != lp)
		*op++ = '\0';
	return op - buf;
}

int
sdiofwend(void)
{
	uchar buf[4];
	u32 n, off;

	if(!fw.up || fw.err)
		return -1;
	if(fw.mode == 3){
		/*
		 * Hand the regulatory blob to the firmware.
		 *
		 * WLC_GET_VALID_CHANNELS answered with a count of ZERO --
		 * the ioctl succeeding and the firmware saying it has no
		 * channels it may use.  That is why every scan was refused
		 * while everything else worked: nothing else needs a
		 * channel.  This 2021 Cypress build carries its regulatory
		 * tables in a separate CLM blob rather than in the firmware
		 * image, and the reference's table predates that -- it has
		 * no regufile for a 43430, because the build it was written
		 * against did not need one.
		 *
		 * The blob goes in through the "clmload" iovar in chunks,
		 * each with a 12-byte header: flag, type, length, crc.  The
		 * flag carries the handler version in its top nibble and
		 * DL_BEGIN on the first chunk, DL_END on the last.
		 */
		static uchar buf[12 + 1400];
		int off, k;
		u32 flag;

		if(fw.clmlen == 0)
			return -1;
		for(off = 0; off < fw.clmlen; off += k){
			k = fw.clmlen - off;
			if(k > 1400)
				k = 1400;
			flag = 1 << 12;			/* handler version 1 */
			if(off == 0)
				flag |= 2;		/* DL_BEGIN */
			if(off + k >= fw.clmlen)
				flag |= 4;		/* DL_END */
			memset(buf, 0, 12);
			buf[0] = flag;
			buf[1] = flag >> 8;
			buf[2] = 2;			/* DL_TYPE_CLM */
			put4le(buf + 4, k);
			memmove(buf + 12, fw.clm + off, k);
			if(sdiosetvar("clmload", buf, 12 + k) < 0){
				print("sdio: clmload failed at %d of %d\n",
					off, fw.clmlen);
				return -1;
			}
		}
		print("sdio: CLM blob loaded, %d bytes\n", fw.clmlen);
		fw.mode = 0;
		return 0;
	}
	if(fw.mode == 2){
		n = condense(fw.nv, fw.nvlen);
		while(n & 3)
			fw.nv[n++] = 0;
		off = sb.socramsize - n - 4;
		if(sbmem(1, fw.nv, n, sb.rambase + off) < 0)
			return -1;
		n /= 4;
		n = (n & 0xffff) | (~n << 16);
		buf[0] = n;
		buf[1] = n >> 8;
		buf[2] = n >> 16;
		buf[3] = n >> 24;
		if(sbmem(1, buf, 4, sb.rambase + sb.socramsize - 4) < 0)
			return -1;
		print("sdio: nvram %d bytes at %#lux, token %#lux\n",
			fw.nvlen, (ulong)off, (ulong)n);
	}
	fw.mode = 0;
	return 0;
}

/*
 * Start the ARM.  For an ARMcm3 that is simply taking armctl out of
 * reset; the ARMcr4 path needs the reset vector written to address 0
 * first and does not apply to this part.
 */
int
sdiofwgo(void)
{
	if(!fw.up)
		return -1;
	if(sb.armcore == ARMcr4){
		print("sdio: ARMcr4 start is not implemented\n");
		return -1;
	}
	sbreset(sb.armctl, 0, 0);
	print("sdio: ARM started (%lud bytes of firmware at %#lux)\n",
		(ulong)fw.off, (ulong)sb.rambase);
	return 0;
}

/*
 * Bring the running firmware's side of the link up: the high-throughput
 * clock, the mailbox protocol version, the interrupts the firmware will
 * raise, and SDIO function 2, which is the data path for packets.
 *
 * THIS IS THE TEST THAT THE FIRMWARE IS ALIVE.  The HT clock is not
 * something the host can switch on by itself -- the chip's own ARM has
 * to answer the request -- and function 2 does not exist until the
 * firmware creates it.  Up to here everything could have been done to a
 * chip with 400KB of rubbish in its RAM; if HTavail comes back and
 * function 2 reports ready, the code that was uploaded is running.
 */
int
sdioenable(void)
{
	int i, cc;

	if(!fw.up)
		return -1;
	sdiocmd52(1, Clkcsr, 1, 0);
	delay(1);
	sdiocmd52(1, Clkcsr, 1, ReqHT);
	for(i = 0; i < 50; i++){
		cc = sdiocmd52(1, Clkcsr, 0, 0);
		if(cc >= 0 && (cc & HTavail))
			break;
		delay(100);
	}
	if(i == 50){
		print("sdio: no HT clock: Clkcsr %#ux -- the firmware is not "
			"running\n", sdiocmd52(1, Clkcsr, 0, 0));
		return -1;
	}
	sdiocmd52(1, Clkcsr, 1, sdiocmd52(1, Clkcsr, 0, 0) | ForceHT);
	delay(10);
	print("sdio: HT clock up after %d ms, Clkcsr %#ux\n", i * 100,
		sdiocmd52(1, Clkcsr, 0, 0));

	sbwindow(sb.sdregs);
	cfgwritel(sb.sdregs + Sbmboxdata, 4 << 16);	/* protocol version 4 */
	cfgwritel(sb.sdregs + Intmask, FrameInt | MailboxInt | Fcchange);

	sdiocmd52(0, Cccioenable, 1, sdiocmd52(0, Cccioenable, 0, 0) | 1<<2);
	for(i = 0; i < 10; i++){
		if(sdiocmd52(0, Cccioready, 0, 0) & 1<<2)
			break;
		delay(100);
	}
	if(i == 10){
		print("sdio: function 2 never became ready (ioready %#ux)\n",
			sdiocmd52(0, Cccioready, 0, 0));
		return -1;
	}
	sdiocmd52(0, Cccintenable, 1, (1<<1) | (1<<2) | 1);
	print("sdio: ENABLED -- function 2 ready, the firmware is running\n");
	fw.enabled = 1;
	wlrxstart();
	return 0;
}

/*
 * SDPCM: packets to and from the running firmware, over function 2.
 *
 * Every transfer on function 2 goes to the same address with the address
 * held still -- the function is a pipe, not memory -- and its blocks are
 * 512 bytes rather than function 1's 64.
 */
static int txseq, reqid;

/*
 * The reader.
 *
 * Until now every command polled for its own reply and skipped anything
 * else, which threw events away and made each command's timeout the
 * whole latency budget: 400 waits of 50ms meant one GET_BSSID could take
 * twenty seconds, and waiting through a four-way handshake that way took
 * twenty minutes.  It also cannot collect a reply spread over more than
 * one frame.
 *
 * So: one process reads frames and sorts them by channel.  Control
 * replies are handed to whoever is waiting for that request id, events
 * are decoded where they arrive, and data frames are counted for now.
 * Commands sleep instead of spinning, and the join waits for the event
 * the firmware already sends rather than asking repeatedly whether it
 * has happened yet.
 *
 * The SDIO bus itself is single-threaded, so every transfer takes
 * sdiolock: the reader and a sending command are two processes now.
 */
static struct {
	QLock;			/* one command at a time */
	QLock	sdiolock;	/* one transfer at a time */
	Rendez	cmdr;
	Rendez	joinr;
	int	rspid;		/* request id of the reply held below */
	int	rsplen;
	uchar	rsp[2048];
	int	joinstatus;	/* 0 waiting, else 1 + the event's status */
	int	running;
	int	ndata;		/* data frames seen */
	int	nctl;		/* control replies seen */
	int	nevent;		/* event frames seen */
	int	nesc;		/* escan result events seen */
	int	lastetype;
	int	nresync;
	int	nempty;		/* reads that found an empty queue */
	int	nreaderr;	/* reads the bus refused */
	Rendez	linkr;
	int	linkdown;	/* the firmware has reported the link down */
	uchar	txwindow;	/* the firmware's send credit */
	uchar	fcmask;
	long	t0;		/* ticks when the join was issued */
	int	nssid;
	char	ssid[24][33];
	uchar	bssid[24][6];
} rx;

static int
packetrw(int write, uchar *buf, int len)
{
	int n, nb;

	while(len > 0){
		n = len;
		if(n > 2048)
			n = 2048;
		n = (n + 3) & ~3;
		if(n >= Secsize){
			nb = n / Secsize;
			if(sdiocmd53(2, Enumbase, write, 1, 0, buf, nb) != nb)
				return -1;
			n = nb * Secsize;
		}else if(sdiocmd53(2, Enumbase, write, 0, 0, buf, n) != n)
			return -1;
		buf += n;
		len -= n;
	}
	return 0;
}

/*
 * Wait for the firmware to say it has a frame for us.
 *
 * The chip raises an SDIO interrupt; nothing here is wired to one yet, so
 * this polls the CCCR pending byte and then reads the SDIO core's own
 * interrupt status.  A mailbox interrupt with bit 3 set is the firmware
 * announcing that it is ready, which is worth printing once: it is the
 * firmware talking rather than being talked to.
 */
static int
wlintwait(int ms)
{
	u32 ints, mbox;
	int i, t;

	/*
	 * ms == 0 means one look and no waiting.  The delay is a busy wait
	 * and this is called with the SDIO bus locked, so an idle reader
	 * spinning in here holds the lock against every sender for nothing.
	 */
	for(t = 0;; t += 5){
		i = sdiocmd52(0, Cccintpend, 0, 0);
		if(i <= 0){
			if(t + 5 >= ms)
				break;
			delay(5);
			continue;
		}
		sbwindow(sb.sdregs);
		ints = cfgreadl(sb.sdregs + Intstatus);
		cfgwritel(sb.sdregs + Intstatus, ints);
		if(ints & MailboxInt){
			mbox = cfgreadl(sb.sdregs + Hostmboxdata);
			cfgwritel(sb.sdregs + Sbmbox, 2);		/* ack */
			if((mbox & 0x8) && !fw.said){
				print("sdio: the firmware says it is ready\n");
				fw.said = 1;
			}
		}
		if(ints & FrameInt)
			return 0;
		if(t + 5 >= ms)
			break;
		delay(5);
	}
	return -1;
}

/*
 * Read one SDPCM frame.  The header carries its own length twice, once
 * complemented, and a frame that fails that check means the receive side
 * has lost sync -- the cure is to halt and drain it rather than to keep
 * reading rubbish.
 */
static int
wlreadpkt(uchar *buf, int max)
{
	int len, lenck;

	if(packetrw(0, buf, Sdpcmsz) < 0)
		return -1;
	len = buf[0] | buf[1]<<8;
	if(len == 0)
		return 0;
	lenck = buf[2] | buf[3]<<8;
	if(lenck != (len ^ 0xffff) || len < Sdpcmsz || len > max){
		print("sdio: frame header len %#ux lenck %#ux -- resyncing\n",
			len, lenck);
		/*
		 * Bounded, unlike the reference.
		 *
		 * These two drains spin until the frame counters read zero,
		 * and the reader holds the SDIO bus while they do -- so a
		 * counter that never clears is not a slow resync, it is the
		 * whole radio wedged with the lock held and every command
		 * blocked behind it.  That is a plausible cause of the
		 * control channel going silent once data starts flowing.
		 */
		sdiocmd52(1, Framectl, 1, Rfhalt);
		for(lenck = 0; lenck < 1000; lenck++)
			if(sdiocmd52(1, Rfrmcnt + 1, 0, 0) <= 0)
				break;
		for(lenck = 0; lenck < 1000; lenck++)
			if(sdiocmd52(1, Rfrmcnt, 0, 0) <= 0)
				break;
		rx.nresync++;
		return -1;
	}
	if(len > Sdpcmsz)
		if(packetrw(0, buf + Sdpcmsz, len - Sdpcmsz) < 0)
			return -1;
	return len;
}

/*
 * Decode one event frame.  Called only from the reader.
 *
 * The layout: the SDPCM doffset, then a BDC header sized 4 + (its fourth
 * byte << 2), then a 14-byte ethernet header and a 10-byte bcmeth
 * header, then the event message -- whose fields are BIG endian, unlike
 * everything else here.  Event 0 is E_SET_SSID and 16 E_LINK, which is
 * how a join reports its outcome; 69 is E_ESCAN_RESULT, whose payload
 * starts 48 bytes in.
 */
static void
wlevent(uchar *ev, int flen)
{
	int doff, bdc, k, etype, status, flags, nbss, off, rlen, sl, j, dup;
	char name[33];

	doff = ev[7];
	if(flen < doff + 4)
		return;
	bdc = 4 + (ev[doff + 3] << 2);
	if(flen < doff + bdc + 24 + 16)
		return;
	k = doff + bdc + 24;
	/*
	 * wl_event_msg_t, all big endian: version, flags, event_type,
	 * status, reason, ...  The flags matter as much as the type.
	 */
	flags = ev[k+2] << 8 | ev[k+3];
	etype = ev[k+6] << 8 | ev[k+7];
	status = ev[k+8] << 24 | ev[k+9] << 16 | ev[k+10] << 8 | ev[k+11];
	rx.lastetype = etype;
	/*
	 * Say what the firmware is reporting.  A join that never completes
	 * and a join whose completion event is missed look identical from
	 * outside, and only the event stream tells them apart.
	 */
	if(etype != 69 && rx.nevent < 40){
		static char *supstate[] = {
			"disconnected", "connecting", "idrequired",
			"authenticating", "authenticated", "keyxchange",
			"KEYED", "timeout",
		};

		if(etype == 46 && status >= 0 && status < nelem(supstate))
			print("sdio: +%ldms E_PSK_SUP %s\n",
				(long)(TK2MS(m->ticks) - rx.t0), supstate[status]);
		else
			print("sdio: +%ldms event type %d status %d flags %#ux len %d\n",
				(long)(TK2MS(m->ticks) - rx.t0), etype, status,
				flags, flen);
	}

	switch(etype){
	case 16:				/* E_LINK */
		/*
		 * E_LINK reports the link going DOWN as well as up, and the
		 * two differ only in the flags: WLC_EVENT_MSG_LINK, bit 0.
		 * Taking every E_LINK for a successful join made a teardown
		 * indistinguishable from an association -- and that was not
		 * an edge case, it was every second join.
		 *
		 * A join issued while already associated tears the old link
		 * down first, so the sequence was E_AUTH status 4, then
		 * E_LINK (down) fourteen seconds later, and nothing else:
		 * no E_ASSOC, no E_PSK_SUP, no E_SET_SSID.  This reported
		 * ASSOCIATED on it, then found GET_BSSID had nothing to
		 * report, and blamed a stalled control channel.  The
		 * control channel was fine; the radio was not associated.
		 * The second of three joins failed this way in every run,
		 * which is the last of the "intermittency".
		 */
		if((flags & 1) == 0){
			print("sdio: +%ldms the link went DOWN\n",
				(long)(TK2MS(m->ticks) - rx.t0));
			rx.linkdown = 1;
			fw.joined = 0;
			wakeup(&rx.linkr);
			return;
		}
		rx.joinstatus = 1 + status;
		wakeup(&rx.joinr);
		return;
	case 0:					/* E_SET_SSID */
		rx.joinstatus = 1 + status;
		wakeup(&rx.joinr);
		return;
	case 69:				/* E_ESCAN_RESULT */
		rx.nesc++;
		break;
	default:
		return;
	}
	if(flen < k + 48 + 12)
		return;
	k += 48;
	nbss = ev[k+10] | ev[k+11] << 8;
	off = k + 12;
	if(rx.nesc <= 4){
		int z;

		print("sdio: bss_info at %d:", off);
		for(z = 0; z < 56 && off + z < flen; z++)
			print(" %2.2ux", ev[off+z]);
		print("\n");
	}
	while(nbss-- > 0 && off + 24 < flen){
		rlen = ev[off+4] | ev[off+5]<<8 | ev[off+6]<<16 | ev[off+7]<<24;
		if(rlen < 24 || off + rlen > flen)
			break;
		sl = ev[off+18];
		if(sl > 32)
			sl = 32;
		memmove(name, &ev[off+19], sl);
		name[sl] = 0;
		dup = 0;
		for(j = 0; j < rx.nssid; j++)
			if(strcmp(rx.ssid[j], name) == 0)
				dup = 1;
		if(!dup && sl > 0 && rx.nssid < nelem(rx.ssid)){
			strcpy(rx.ssid[rx.nssid], name);
			memmove(rx.bssid[rx.nssid], &ev[off+8], 6);
			rx.nssid++;
		}
		off += rlen;
	}
}

static void
wlrxproc(void *a)
{
	static uchar buf[2048];
	int n;

	USED(a);
	rx.running = 1;
	for(;;){
		/*
		 * Read first; wait for an interrupt only when there was
		 * nothing to read.
		 *
		 * This used to gate every read on wlintwait -- one poll of
		 * the interrupt status, then at most one frame.  That is
		 * wrong, and it was the whole of two separate symptoms.
		 * FrameInt is a latched bit covering however many frames the
		 * firmware has queued, and wlintwait clears it on the way
		 * past; so when three frames arrived together the reader
		 * took one and left the other two in the chip's FIFO until
		 * something else raised the bit again.  The queue drained at
		 * one frame per interrupt.
		 *
		 * From outside that looked like two unrelated bugs.  An
		 * association took about two minutes because each event
		 * waited for the next interrupt -- largely generated by this
		 * driver's own status polling, so the radio appeared to
		 * associate only while being prodded.  And a control reply
		 * queued behind an unread event or data frame never arrived
		 * at all, which is the "control channel is still stalled"
		 * that followed every successful join.
		 *
		 * The reference has always been shaped the other way round:
		 * wlreadpkt unconditionally, intwait only on nothing.  A
		 * read with an empty queue is cheap and says so -- the
		 * header's length field comes back zero.
		 *
		 * The bus lock still covers each transfer.  wlintwait reads
		 * the pending byte and the SDIO core's registers, which are
		 * transfers like any other, and doing either unlocked while
		 * another process sends a command puts two conversations on
		 * one bus.
		 */
		qlock(&rx.sdiolock);
		n = wlreadpkt(buf, sizeof buf);
		if(n == 0)
			rx.nempty++;
		else if(n < 0)
			rx.nreaderr++;
		if(n <= 0)
			wlintwait(0);	/* one look, no delay under the lock */
		qunlock(&rx.sdiolock);
		if(n <= 0){
			tsleep(&up->sleep, return0, nil, 2);
			continue;
		}
		/*
		 * Every frame carries the firmware's flow control: byte 9
		 * is how far the sequence number may run, byte 8 which
		 * channels are choked.  Sending past the window is ignored
		 * by the firmware, which looks exactly like a command that
		 * got no answer -- and nothing here was tracking it.
		 */
		rx.txwindow = buf[9];
		rx.fcmask = buf[8];

		switch(buf[5] & 0xf){
		case 0:				/* control reply */
			rx.nctl++;
			if(n < Sdpcmsz + Cmdsz || buf[7] > n - Cmdsz)
				break;
			if(n > sizeof rx.rsp)
				break;
			memmove(rx.rsp, buf, n);
			rx.rsplen = n;
			rx.rspid = rx.rsp[buf[7] + 10] |
				rx.rsp[buf[7] + 11] << 8;
			wakeup(&rx.cmdr);
			break;
		case 1:
			rx.nevent++;
			wlevent(buf, n);
			break;
		case 2:
			rx.ndata++;
			break;
		}
	}
}

/*
 * Start the reader once, and wait for it to be on its feet: a command
 * issued before it is running would sleep for a reply nobody is there to
 * collect.
 */
static void
wlrxstart(void)
{
	int i;

	if(rx.running)
		return;
	kproc("wlrx", wlrxproc, nil, 0);
	/*
	 * tsleep, not delay.
	 *
	 * delay() is a busy wait: it does not yield, so spinning on it
	 * starves the very process being waited for and the reader never
	 * runs.  That is exactly what happened -- "the frame reader did not
	 * start" after a full second of delay() -- and it would have looked
	 * like kproc failing rather than the waiting being wrong.
	 */
	for(i = 0; i < 100 && !rx.running; i++)
		tsleep(&up->sleep, return0, nil, 10);
	if(!rx.running)
		print("sdio: the frame reader did not start\n");
}

static int
rspready(void *a)
{
	USED(a);
	return rx.rspid == reqid;
}

static int
linkisdown(void *a)
{
	USED(a);
	return rx.linkdown;
}

static int
joined(void *a)
{
	USED(a);
	return rx.joinstatus != 0;
}

/*
 * One control message, sent and answered.
 *
 * The reference does this asynchronously: a reader kproc dispatches
 * frames by channel and wakes whoever is waiting.  There is no reader
 * and no interrupt here yet, so this sends and then polls for its own
 * reply, matching on the request id and skipping anything that is not a
 * control frame.  It is enough to establish that the firmware answers,
 * which is the thing in doubt; the asynchronous version is what the
 * packet path will need.
 */
static int
wlcmd(int write, int op, void *data, int dlen, void *res, int rlen)
{
	static uchar pkt[8192];
	uchar *q;
	int len, tlen, st;

	if(!fw.enabled || !rx.running)
		return -1;
	tlen = write? dlen + rlen : (dlen > rlen? dlen : rlen);
	len = Sdpcmsz + Cmdsz + tlen;
	if(len > sizeof pkt)
		return -1;
	qlock(&rx);
	memset(pkt, 0, len);
	pkt[0] = len;
	pkt[1] = len >> 8;
	pkt[2] = ~len;
	pkt[3] = (~len) >> 8;
	pkt[4] = txseq;
	pkt[7] = Sdpcmsz;
	q = pkt + Sdpcmsz;
	q[0] = op;
	q[1] = op >> 8;
	q[2] = op >> 16;
	q[3] = op >> 24;
	q[4] = tlen;
	q[5] = tlen >> 8;
	q[6] = tlen >> 16;
	q[7] = tlen >> 24;
	q[8] = write? 2 : 0;
	reqid++;
	if(reqid > 0xfffe)
		reqid = 1;
	q[10] = reqid;
	q[11] = reqid >> 8;
	if(dlen > 0)
		memmove(q + Cmdsz, data, dlen);
	if(write && rlen > 0)
		memmove(q + Cmdsz + dlen, res, rlen);

	/*
	 * No flow-control wait here.
	 *
	 * Holding off while txseq equals the advertised window is what the
	 * reference does for DATA frames, but applying it to every command
	 * stalls at startup: before any frame has been received both are
	 * zero, so every early command waited out its timeout and the join
	 * never completed.  The window is tracked (the reader records it)
	 * but not yet enforced; enforcing it belongs with the data path,
	 * where it matters.
	 */
	rx.rspid = -1;
	qlock(&rx.sdiolock);
	st = packetrw(1, pkt, len);
	qunlock(&rx.sdiolock);
	if(st < 0){
		print("sdio: cmd %d could not be sent\n", op);
		qunlock(&rx);
		return -1;
	}
	txseq++;

	/*
	 * Sleep until the reader hands the reply over.
	 *
	 * The reference sleeps with no timeout at all; three seconds was
	 * this driver's own invention, on the reasoning that the firmware
	 * answers in milliseconds.  It usually does, but the one join in
	 * three that took seventeen seconds instead of three shows the
	 * firmware taking a slower path, and a ceiling tight enough to
	 * expire on that is a bug reported rather than a bug found.  A
	 * bound is still wanted -- an unanswered command must not wedge the
	 * caller forever -- but it should be well clear of the firmware's
	 * slow path.
	 */
	tsleep(&rx.cmdr, rspready, nil, 12000);
	if(rx.rspid != reqid){
		print("sdio: cmd %d got no answer\n", op);
		qunlock(&rx);
		return -1;
	}
	q = rx.rsp + rx.rsp[7];
	if(q[12] | q[13] | q[14] | q[15]){
		print("sdio: cmd %d failed, status %#lux\n", op,
			(ulong)(q[12] | q[13]<<8 | q[14]<<16 | q[15]<<24));
		qunlock(&rx);
		return -1;
	}
	if(!write && rlen > 0){
		if(rx.rsplen < rx.rsp[7] + Cmdsz + rlen)
			rlen = rx.rsplen - rx.rsp[7] - Cmdsz;
		if(rlen > 0)
			memmove(res, q + Cmdsz, rlen);
	}
	qunlock(&rx);
	return 0;
}


int
sdiogetvar(char *name, void *val, int len)
{
	return wlcmd(0, GetVar, name, strlen(name) + 1, val, len);
}

int
sdiosetvar(char *name, void *val, int len)
{
	return wlcmd(1, SetVar, name, strlen(name) + 1, val, len);
}

/*
 * Ask the firmware what it is.  "ver" is a string variable every build
 * carries, so it is the cheapest thing that proves the control channel
 * works end to end: a request went out, the firmware parsed it, and a
 * matching reply came back with data in it.
 */
int
sdioversion(char *buf, int len)
{
	memset(buf, 0, len);
	if(sdiogetvar("ver", buf, len - 1) < 0)
		return -1;
	buf[len-1] = 0;
	return 0;
}

static void
put4le(uchar *p, u32 v)
{
	p[0] = v;
	p[1] = v >> 8;
	p[2] = v >> 16;
	p[3] = v >> 24;
}

static int
wlcmdint(int op, int val)
{
	uchar b[4];

	put4le(b, val);
	return wlcmd(1, op, b, 4, nil, 0);
}

/*
 * Set a per-interface (bsscfg) iovar.
 *
 * brcmfmac sets wsec, wpa_auth, auth and sup_wpa this way, not as plain
 * iovars: the name is "bsscfg:<name>" and the buffer carries the
 * interface index ahead of the value.  A global of the same name is a
 * DIFFERENT variable -- it sets and reads back happily and configures
 * nothing for interface 0, which is how sup_wpa looked correct while the
 * supplicant sat idle.
 */
static int
sdiosetbss(char *name, int val)
{
	char nm[32];
	uchar b[8];

	snprint(nm, sizeof nm, "bsscfg:%s", name);
	put4le(b, 0);				/* interface index */
	put4le(b + 4, val);
	return sdiosetvar(nm, b, sizeof b);
}

/*
 * Read a per-interface iovar back.  The global getter reports a
 * DIFFERENT variable of the same name -- that is the trap that made
 * sup_wpa look correct for hours -- so a readback that is meant to prove
 * the interface is configured has to use this form.
 */
static int
sdiogetbss(char *name, int *val)
{
	char nm[40];
	uchar b[8];
	int r;

	/*
	 * A bsscfg GET must CARRY the interface index in its request --
	 * the name alone is not enough.  Writing the index into the result
	 * buffer, as this did, sends nothing and returns whatever the
	 * firmware felt like: it reported auth/wsec/wpa_auth/sup_wpa as 0
	 * on a radio that went on to complete a WPA2 handshake, which is
	 * impossible and should have been read as the instrument failing
	 * rather than the settings being unset.
	 */
	snprint(nm, sizeof nm, "bsscfg:%s", name);
	memset(b, 0, sizeof b);
	put4le(b, 0);				/* interface index */
	memset(nm + strlen(nm) + 1, 0, 4);	/* index 0, right after the name */
	r = wlcmd(0, GetVar, nm, strlen(nm) + 1 + 4, b, sizeof b);
	*val = b[0] | b[1]<<8 | b[2]<<16 | b[3]<<24;
	return r;
}

static int
sdiosetint(char *name, int val)
{
	uchar b[4];

	put4le(b, val);
	return sdiosetvar(name, b, 4);
}

/*
 * Set the radio up, following 9front's wlinit for a 43430.
 *
 * The magic numbers are ioctl opcodes rather than anything derivable: 2
 * is UP/DOWN, 0x14 SET_INFRA, 0x56 the powersave mode (which must be
 * OFF on this part -- FAST wedges it), and 0xb9/0xbb/0x102 the three
 * scan timings.  event_msgs is a bitmap of which events the firmware may
 * report; all of them are enabled except a handful that are pure noise.
 */
int
sdiowlinit(uchar *ea)
{
	uchar eventmask[16];

	if(!fw.enabled)
		return -1;
	if(sdiogetvar("cur_etheraddr", ea, 6) < 0){
		print("sdio: cannot read the radio's address\n");
		return -1;
	}
	print("sdio: radio address %2.2ux:%2.2ux:%2.2ux:%2.2ux:%2.2ux:%2.2ux\n",
		ea[0], ea[1], ea[2], ea[3], ea[4], ea[5]);

	/*
	 * The regulatory domain.
	 *
	 * The nvram sets ccode=ALL, which is a Cypress wildcard rather
	 * than a real country, and a firmware that will not accept it has
	 * no channel list -- which is a plausible reason for both escan
	 * and WLC_SCAN to be refused while WLC_GET_CHANNEL still answers.
	 * Report what it thinks, then name a real one.
	 */
	{
		/*
		 * wl_country_t, not a four-character string: country_abbrev
		 * [4], rev [4], ccode [4].  Asking with four bytes was
		 * refused for being too short (-14) and setting with four
		 * for being a bad argument (-2), which is the structure
		 * saying its own size.
		 */
		uchar cc[12];

		memset(cc, 0, sizeof cc);
		if(sdiogetvar("country", cc, sizeof cc) == 0)
			print("sdio: country \"%s\" rev %d ccode \"%s\"\n",
				(char*)cc, (int)(cc[4] | cc[5]<<8), (char*)&cc[8]);
		memset(cc, 0, sizeof cc);
		cc[0] = 'U';
		cc[1] = 'S';
		put4le(cc + 4, -1);		/* any revision */
		cc[8] = 'U';
		cc[9] = 'S';
		print("sdio: set country US -> %d\n",
			sdiosetvar("country", cc, sizeof cc));
		memset(cc, 0, sizeof cc);
		if(sdiogetvar("country", cc, sizeof cc) == 0)
			print("sdio: country now \"%s\" ccode \"%s\"\n",
				(char*)cc, (char*)&cc[8]);
	}

	sdiosetint("assoc_listen", 10);
	wlcmdint(0x56, 0);			/* powersave off */
	sdiosetint("bus:txglom", 0);
	sdiosetint("bcn_timeout", 10);
	sdiosetint("assoc_retry_max", 3);

	memset(eventmask, 0xff, sizeof eventmask);
	eventmask[40/8] &= ~(1<<(40%8));	/* E_RADIO */
	eventmask[44/8] &= ~(1<<(44%8));	/* E_PROBREQ_MSG */
	eventmask[54/8] &= ~(1<<(54%8));	/* E_IF */
	eventmask[71/8] &= ~(1<<(71%8));	/* E_PROBRESP_MSG */
	eventmask[20/8] &= ~(1<<(20%8));	/* E_TXFAIL */
	eventmask[124/8] &= ~(1<<(124%8));
	sdiosetvar("event_msgs", eventmask, sizeof eventmask);

	wlcmdint(0xb9, 0x28);			/* scan channel time */
	wlcmdint(0xbb, 0x28);			/* scan unassoc time */
	wlcmdint(0x102, 0x82);			/* scan passive time */
	wlcmdint(2, 0);				/* DOWN */
	sdiosetint("roam_off", 1);
	wlcmdint(0x14, 1);			/* SET_INFRA */
	if(wlcmdint(2, 1) < 0){			/* UP */
		print("sdio: the radio would not come up\n");
		return -1;
	}
	/*
	 * Give UP time to take effect, and do NOT try to ask whether it
	 * has.
	 *
	 * The first attempt at this polled ioctl 3, on the assumption that
	 * it was GET_UP.  It is not: in wlioctl's numbering 2 is WLC_UP
	 * and 3 is WLC_DOWN, so the poll took the radio down twenty times
	 * in a row, immediately after bringing it up, and then reported
	 * "GET_UP 0" as though the firmware were at fault.  The scan's
	 * BCME_NOTUP was entirely self-inflicted.
	 *
	 * There is no GET_UP in that list to ask with.  So: wait, and let
	 * the scan's own retry loop absorb what is left.
	 */
	/*
	 * rxmode's settings, which wlinit does through the Ether layer.
	 * None of them obviously gates UP, but they are part of the
	 * sequence the reference is known to work with and leaving them
	 * out is a difference for its own sake.
	 */
	sdiosetint("allmulti", 0);
	wlcmdint(10, 0);			/* SET_PROMISC off */
	sdiosetint("arp_ol", 1);
	sdiosetint("ndoe", 1);
	/*
	 * WLC_UP with NO payload.
	 *
	 * Every UP so far carried a four-byte argument, which is how the
	 * reference writes it; brcmfmac sends BRCMF_C_UP with a
	 * zero-length payload.  An ioctl that expects no data may well
	 * ignore a request that carries some and still answer 0, which
	 * would explain an UP that reports success while the scan keeps
	 * saying the interface is not up.
	 */
	print("sdio: UP (no payload) -> %d\n", wlcmd(1, 2, nil, 0, nil, 0));
	delay(1000);
	print("sdio: radio is UP\n");
	fw.inited = 1;
	return 0;
}

/*
 * Start a passive scan over the 2.4GHz channels and count what comes
 * back.  The escan parameter block is a fixed layout and is taken
 * verbatim from the reference, including its note that the byte order is
 * only right on a little-endian machine -- which this is.
 *
 * The results arrive as events on channel 1.  Parsing them into SSIDs is
 * the next piece of work; for now this reports how many event frames the
 * radio produced, which is the difference between a radio that is
 * listening to the air and one that is merely powered.
 */
int
sdioscan(int *nev)
{
	static uchar params[4+2+2+4+32+6+1+1+4*4+2+2+14*2+32+4] = {
		1,0,0,0,
		1,0,
		0x34,0x12,
		0,0,0,0,
		0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
		0xff,0xff,0xff,0xff,0xff,0xff,
		2,
		0,
		0xff,0xff,0xff,0xff,
		0xff,0xff,0xff,0xff,
		0xff,0xff,0xff,0xff,
		0xff,0xff,0xff,0xff,
		14,0,
		0,0,
		0x01,0x2b,0x02,0x2b,0x03,0x2b,0x04,0x2b,0x05,0x2e,0x06,0x2e,0x07,0x2e,
		0x08,0x2b,0x09,0x2b,0x0a,0x2b,0x0b,0x2b,0x0c,0x2b,0x0d,0x2b,0x0e,0x2b,
		0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
	};
	static uchar pkt[4096];
	int i;

	if(!fw.inited)
		return -1;
	/*
	 * Scan with WLC_SCAN and read the results with WLC_SCAN_RESULTS,
	 * rather than escan.
	 *
	 * escan is refused by this firmware -- status 0xfffffffc every
	 * time -- and that is not "interface down" whatever the error
	 * table says, because WLC_GET_CHANNEL answers with channel 1 at
	 * the same moment: the radio is up.  escan also delivers its
	 * results as events, which needs the asynchronous reader this does
	 * not have yet.
	 *
	 * The older pair is a better fit and needs neither: ioctl 50 takes
	 * the same scan parameters minus escan's version, action and
	 * sync_id, and ioctl 51 hands back the accumulated results in one
	 * buffer.  Synchronous, which is what everything here is.
	 */
	/*
	 * 92 bytes, not 124.
	 *
	 * WLC_SCAN came back 0xfffffff2 -- a length complaint.  The fixed
	 * part of wl_scan_params is 64 bytes, up to and including
	 * channel_num; after it come the channel list and then the SSID
	 * list.  The reference's block counts 32 bytes per SSID, but
	 * brcmfmac's brcmf_ssid_le is 36 (a length word plus the name), so
	 * a block sized the reference's way is the wrong length for this
	 * firmware.  With nssids set to 0 -- a broadcast scan, which is
	 * what is wanted -- the SSID list disappears and the size is just
	 * 64 + 14 channels * 2 = 92.
	 */
	/*
	 * Ask what channels the firmware thinks it may use.
	 *
	 * Only the scan commands are refused; everything else -- ver,
	 * cur_etheraddr, country, the security settings, the PSK, UP,
	 * GET_CHANNEL -- works.  A firmware with an empty channel list
	 * would behave exactly like that: nothing to scan, so the scan is
	 * refused, while every other question still has an answer.  This
	 * distinguishes a regulatory or calibration problem from a bug in
	 * how the scan is being asked for.  WLC_GET_VALID_CHANNELS is 217
	 * and returns a count followed by that many channel numbers.
	 */
	{
		static uchar cl[1024];
		u32 nc;
		int k;

		memset(cl, 0, sizeof cl);
		k = wlcmd(0, 217, nil, 0, cl, sizeof cl);
		nc = cl[0] | cl[1]<<8 | cl[2]<<16 | cl[3]<<24;
		print("sdio: valid channels -> %d, count %lud:", k, (ulong)nc);
		if(k == 0 && nc < 64)
			for(i = 0; i < nc; i++)
				print(" %d", cl[4 + i*4]);
		print("\n");
	}

	/*
	 * escan, not WLC_SCAN.
	 *
	 * WLC_SCAN succeeds now that the regulatory blob is loaded, but it
	 * keeps its results to itself and hands them over through
	 * WLC_SCAN_RESULTS -- a multi-kilobyte reply this reader cannot
	 * collect.  escan reports each network as an EVENT instead, which
	 * arrives as an ordinary small frame.  It was refused before only
	 * because the radio had no channels; that is fixed.
	 *
	 * The block is escan's three extra words -- version, action,
	 * sync_id -- followed by the same scan parameters, so with no SSID
	 * list it is 8 + 64 + 14 channels * 2 = 100 bytes.
	 */
	/*
	 * Clear the list BEFORE starting the scan.
	 *
	 * It was cleared afterwards, with a sleep in between -- and that
	 * sleep is exactly when the results arrive, so the reader filled
	 * the list and this then wiped it.  The decode was right the whole
	 * time: a debug dump showed "GL-BE6500-1f2" being parsed out of a
	 * bss_info while the count printed zero.
	 */
	rx.nssid = 0;
	if(sdiosetvar("escan", params, 8 + 64 + 14*2) < 0){
		print("sdio: escan was refused\n");
		return -1;
	}
	/*
	 * Give the sweep time to finish before asking for its results.
	 *
	 * Three seconds is not obviously enough: fourteen channels with a
	 * passive dwell can take considerably longer, and a scan still in
	 * progress has no results to hand over.  The frames logged while
	 * waiting for the results were all events -- no control reply at
	 * all -- which fits "still scanning" better than it fits a reply
	 * that was sent and missed.
	 */
	tsleep(&up->sleep, return0, nil, 500);
	memset(pkt, 0, sizeof pkt);
	/*
	 * Ask for 4KB of results.
	 *
	 * The firmware wants a buffer it can fill; too small and it
	 * answers BCME_BUFTOOSHORT rather than truncating.  4KB holds a
	 * few dozen networks and fits inside wlcmd's frame.
	 */
	/*
	 * 3000: 1536 was too short (BCME_BUFTOOSHORT, so there really are
	 * networks to report) and 4096 never came back.  A CDC reply rides
	 * in SDPCM frames and a very large one may be split across several,
	 * which this reader does not reassemble; 3000 asks for enough to
	 * satisfy the firmware while staying within a single frame.
	 */
	/*
	 * Show every frame that arrives while waiting for the results.
	 *
	 * 1536 was too short, 3000 and 4096 produce no reply at all.
	 * "No answer" means no control frame with a matching id was seen
	 * in the whole wait -- but frames may well be arriving and being
	 * skipped, and which it is decides whether this is a size problem
	 * or a reassembly problem.
	 */
	fw.rxdebug = 0;
	/*
	 * The reader collects the results; this just waits and reports.
	 */
	/*
	 * tsleep, not delay -- again.
	 *
	 * delay() is a busy wait.  Spinning on it here starves the reader
	 * exactly as it starved its own startup, so the events arrive at a
	 * process that never runs and the scan finds nothing.  The first
	 * time this cost an hour; the symptom the second time was "0
	 * network(s) found" from a scan that had plainly succeeded.
	 */
	for(i = 0; i < 60; i++){
		tsleep(&up->sleep, return0, nil, 200);
		if(rx.nssid >= nelem(rx.ssid))
			break;
	}
	for(i = 0; i < rx.nssid; i++)
		print("sdio: %2.2ux:%2.2ux:%2.2ux:%2.2ux:%2.2ux:%2.2ux  %s\n",
			rx.bssid[i][0], rx.bssid[i][1], rx.bssid[i][2],
			rx.bssid[i][3], rx.bssid[i][4], rx.bssid[i][5],
			rx.ssid[i]);
	print("sdio: %d network(s) found; frames: %d control, %d event "
		"(%d escan), %d data; last event type %d\n",
		rx.nssid, rx.nctl, rx.nevent, rx.nesc, rx.ndata, rx.lastetype);
	*nev = rx.nssid;
	return 0;
}

/*
 * Associate with a network, using the firmware's own supplicant.
 *
 * 9front's driver expects WPA keys from a userspace supplicant and feeds
 * them in with wsec_key.  This part can do the whole handshake itself,
 * which is much less to build: tell it the cipher, the authentication
 * type, that its supplicant is in charge, and the passphrase, then hand
 * it the SSID.
 *
 * wsec_pmk is a wsec_pmk_t -- key_len[2], flags[2], key[64] -- with
 * flags 1 meaning the key is a passphrase rather than a computed PMK.
 *
 * The passphrase is never printed, here or anywhere: it arrives through
 * the ctl file and goes straight into the chip.
 */
int
sdiojoin(char *ssid, char *pass)
{
	uchar params[72], pmk[69], bssid[6];
	uchar *p;
	int n, i;

	if(!fw.inited)
		return -1;
	n = strlen(pass);
	if(n < 8 || n > 63){
		print("sdio: the passphrase must be 8 to 63 characters\n");
		return -1;
	}
	/*
	 * Let go of the old association first, and WAIT for it.
	 *
	 * A join issued while already associated does not re-associate:
	 * the firmware drops the existing link -- E_LINK with the
	 * WLC_EVENT_MSG_LINK flag clear, about eighteen seconds later --
	 * and the join goes nowhere.  Every second join in a run failed
	 * that way, deterministically, which had been read as the
	 * association being flaky.
	 *
	 * The reference never hits this because nothing there re-joins
	 * while up.  Here the fix is to say so explicitly: DISASSOC, wait
	 * for the firmware to confirm the link is down, and only then set
	 * the interface up and ask for the new one.
	 */
	if(fw.joined){
		print("sdio: already associated; disassociating first\n");
		rx.linkdown = 0;
		wlcmdint(52, 0);		/* DISASSOC */
		tsleep(&rx.linkr, linkisdown, nil, 25000);
		if(!rx.linkdown)
			print("sdio: the link never reported down\n");
		fw.joined = 0;
		/*
		 * The firmware needs a moment after the link goes down
		 * before it will take a join; asking immediately is how the
		 * collision happened in the first place.
		 */
		tsleep(&up->sleep, return0, nil, 1000);
	}
	wlcmdint(2, 1);				/* UP */

	/*
	 * Report each of these rather than ignoring them.
	 *
	 * wsec_pmk came back BCME_UNSUPPORTED (-23) while the three
	 * settings before it appeared to succeed, which does not fit: if
	 * the firmware had no internal supplicant, sup_wpa should have
	 * been refused too.  One of these assumptions is wrong and
	 * printing each result says which.
	 */
	/*
	 * sup_wpa has to be set on the BSS CONFIG, not globally.
	 *
	 * The plain "sup_wpa" iovar sets and reads back as 1, which is why
	 * it looked right -- but brcmfmac uses brcmf_fil_bsscfg_int_set,
	 * and a bsscfg iovar is a different variable: the name is
	 * "bsscfg:sup_wpa" and the buffer carries the interface index
	 * ahead of the value.  Setting the global one enables nothing for
	 * interface 0, which would leave the firmware's supplicant idle --
	 * and idle is exactly what it looks like: association completes
	 * and then nothing happens, with no EAPOL reaching the host
	 * either.
	 */
	/*
	 * All of these per interface, in brcmfmac's order: WPA version,
	 * open authentication, the cipher, the key-management mode, and
	 * the supplicant.  Setting wsec and wpa_auth globally -- which is
	 * what this did -- leaves interface 0 unconfigured, and an
	 * unconfigured interface associates happily and then has nothing
	 * to run a handshake with.
	 */
	print("sdio: bsscfg auth=%d wsec=%d wpa_auth=%d sup_wpa=%d\n",
		sdiosetbss("auth", 0),			/* open system */
		sdiosetbss("wsec", 4),			/* AES_ENABLED */
		sdiosetbss("wpa_auth", 0x80),		/* WPA2-PSK */
		sdiosetbss("sup_wpa", 1));		/* in-firmware supplicant */
	{
		uchar b[4];

		memset(b, 0, sizeof b);
		print("sdio: read back sup_wpa -> %d, value %d\n",
			sdiogetvar("sup_wpa", b, 4), b[0]);
	}

	memset(pmk, 0, sizeof pmk);
	pmk[0] = n;
	pmk[1] = n >> 8;
	pmk[2] = 1;				/* WSEC_PASSPHRASE */
	memmove(pmk + 4, pass, n);
	/*
	 * 69 bytes, not 68: brcmfmac's wsec_pmk is key_len[2], flags[2]
	 * and key[2*32+1].  The firmware accepted 68 without complaint,
	 * which is not the same as having understood it.
	 *
	 * The passphrase goes in through an IOCTL, not an iovar.
	 *
	 * SetVar "wsec_pmk" is refused with BCME_UNSUPPORTED (-23) by this
	 * firmware, while sup_wpa sets and reads back as 1 -- so the
	 * internal supplicant is there and only the way of handing it the
	 * key was wrong.  brcmfmac uses BRCMF_C_SET_WSEC_PMK, ioctl 268,
	 * with the same wsec_pmk_t payload.
	 */
	if(wlcmd(1, 268, pmk, sizeof pmk, nil, 0) < 0){
		print("sdio: the passphrase was refused\n");
		return -1;
	}

	/*
	 * The join parameters: ssid, then a scan spec telling it to look
	 * everywhere (-1 for the timings, a broadcast bssid, no channel
	 * list).  68 bytes, not 72 -- the last four are only present when
	 * a channel is named.
	 */
	memset(params, 0, sizeof params);
	p = params;
	n = strlen(ssid);
	if(n > 32)
		n = 32;
	put4le(p, n);
	p += 4;
	memmove(p, ssid, n);
	p += 32;
	put4le(p, 0xff);			/* scan type */
	p += 4;
	put4le(p, -1);				/* nprobes */
	p += 4;
	put4le(p, -1);				/* active time */
	p += 4;
	put4le(p, -1);				/* passive time */
	p += 4;
	put4le(p, -1);				/* home time */
	p += 4;
	memset(p, 0xff, 6);			/* any bssid */
	p += 6;
	p += 2;					/* pad */
	put4le(p, 0);				/* no channel list */

	/*
	 * Arm the wait BEFORE sending the join.
	 *
	 * Clearing joinstatus afterwards loses an event that arrives in
	 * between, and E_SET_SSID arrives almost immediately -- so the
	 * reader would record the outcome and this would wipe it, then
	 * wait twenty seconds for an event that had already come.  It is
	 * the same mistake as clearing the scan list after starting the
	 * scan, and it showed as an outcome that alternated between
	 * success and "no answer" on identical runs.
	 */
	rx.joinstatus = 0;
	/*
	 * Associate with the "join" iovar.
	 *
	 * WLC_SET_SSID with a join_params, which is what brcmfmac uses,
	 * was tried here and gets LESS far: it stops after E_AUTH and
	 * never reaches E_ASSOC, where the join iovar reliably reaches
	 * E_ASSOC with status 0.  So the association itself is fine and
	 * the difference is downstream of it.
	 */
	if(sdiosetvar("join", params, 68) < 0){
		print("sdio: the join was refused\n");
		return -1;
	}
	{
		int a, w, p2, u;

		a = w = p2 = u = -1;
		sdiogetbss("auth", &a);
		sdiogetbss("wsec", &w);
		sdiogetbss("wpa_auth", &p2);
		sdiogetbss("sup_wpa", &u);
		print("sdio: at join: auth %d wsec %d wpa_auth %#ux sup_wpa %d\n",
			a, w, p2, u);
	}
	rx.t0 = TK2MS(m->ticks);
	print("sdio: joining %s ...\n", ssid);

	/*
	 * Wait for the firmware to say what happened.
	 *
	 * The previous version asked GET_BSSID over and over, which with
	 * the old polling took twenty seconds an attempt and never
	 * outlasted the handshake.  The firmware reports the outcome
	 * itself as E_SET_SSID or E_LINK, and the reader turns that into a
	 * wakeup; status 0 is success and anything else is the reason it
	 * failed.
	 */
	/*
	 * Three minutes, not forty seconds.
	 *
	 * Timestamped events show the association taking about two:
	 * E_AUTH at +6s, E_ASSOC at +44s, E_LINK at +77s, E_PSK_SUP KEYED
	 * at +102s, E_JOIN at +114s, E_SET_SSID at +120s.  The forty
	 * second wait expired between E_ASSOC and E_LINK, so the join was
	 * reported as failed while it was still in progress -- and
	 * whether a run "worked" depended on nothing more than whether it
	 * finished inside the window.  That is the whole of the
	 * intermittency.
	 *
	 * Two minutes is far slower than this should be and is worth
	 * understanding separately; it is not a reason to keep timing out
	 * before the answer arrives.
	 */
	tsleep(&rx.joinr, joined, nil, 180000);
	if(rx.joinstatus == 0){
		/*
		 * Say whether any DATA frames arrived.
		 *
		 * The AP is plain WPA2-PSK, so the four-way handshake
		 * should happen -- the question is who runs it.  With the
		 * firmware's own supplicant (sup_wpa 1) EAPOL never reaches
		 * the host and this stays zero; if the host is expected to
		 * do the handshake, the EAPOL frames arrive on channel 2
		 * and this counts them.  That decides whether the
		 * supplicant is really enabled or whether a data path has
		 * to be built.
		 */
		/*
		 * Ask the firmware what it thinks, rather than concluding
		 * from the absence of an event.  GET_BSSID returns
		 * BCME_NOTASSOCIATED (-17) when there is no association and
		 * the AP's address when there is; if it answers with an
		 * address then the association succeeded and only the
		 * completion event was missed, which is a different bug
		 * entirely from a handshake that never ran.
		 */
		print("sdio: NO JOIN after 180s; %d event, %d data frames, "
			"last type %d, %d resync(s)\n",
			rx.nevent, rx.ndata, rx.lastetype, rx.nresync);
		memset(bssid, 0, sizeof bssid);
		i = wlcmd(0, 23, nil, 0, bssid, sizeof bssid);
		print("sdio: GET_BSSID -> %d, %2.2ux:%2.2ux:%2.2ux:%2.2ux:%2.2ux:%2.2ux\n",
			i, bssid[0], bssid[1], bssid[2], bssid[3], bssid[4],
			bssid[5]);
		return -1;
	}
	if(rx.joinstatus != 1){
		print("sdio: join failed, event status %d\n", rx.joinstatus - 1);
		return -1;
	}
	/*
	 * The join event says the association succeeded; give the firmware
	 * a moment to have a BSSID to report.
	 *
	 * E_SET_SSID arrives as soon as the join is accepted, which is
	 * slightly before GET_BSSID has anything to say -- the first
	 * attempt came back empty and was reported as "the join reported
	 * success but there is no BSSID", which is true and was the wrong
	 * conclusion to draw from it.
	 */
	for(i = 0; i < 20; i++){
		memset(bssid, 0, sizeof bssid);
		if(wlcmd(0, 23, nil, 0, bssid, sizeof bssid) == 0 &&
		   (bssid[0] | bssid[1] | bssid[2] | bssid[3] | bssid[4] | bssid[5]))
			break;
		tsleep(&up->sleep, return0, nil, 500);
	}
	if(bssid[0] | bssid[1] | bssid[2] | bssid[3] | bssid[4] | bssid[5]){
		print("sdio: ASSOCIATED with %2.2ux:%2.2ux:%2.2ux:%2.2ux:%2.2ux:%2.2ux\n",
			bssid[0], bssid[1], bssid[2], bssid[3], bssid[4], bssid[5]);
		memmove(fw.bssid, bssid, 6);
		fw.joined = 1;
		return 0;
	}
	/*
	 * The event is authoritative; the BSSID readback is a bonus.
	 *
	 * E_SET_SSID with status 0 IS the association succeeding -- it
	 * arrives after E_ASSOC, E_LINK and E_PSK_SUP, which is the
	 * four-way handshake having run.  Reporting failure because a
	 * follow-up GET_BSSID went unanswered was believing the weaker
	 * evidence over the stronger: the control channel stops answering
	 * once the link is up and data starts flowing, which is a separate
	 * bug in this reader and not a failure to associate.
	 */
	print("sdio: ASSOCIATED with %s\n", ssid);
	{
		uchar b[6];
		int k;

		/*
		 * Now that flow control is honoured and the resync is
		 * bounded, see whether the control channel survives the
		 * link coming up.
		 */
		for(k = 0; k < 10; k++){
			memset(b, 0, sizeof b);
			if(wlcmd(0, 23, nil, 0, b, sizeof b) == 0 &&
			   (b[0]|b[1]|b[2]|b[3]|b[4]|b[5])){
				print("sdio: BSSID %2.2ux:%2.2ux:%2.2ux:%2.2ux:%2.2ux:%2.2ux "
					"after %d tr(ies); window %d fcmask %#ux "
					"resyncs %d empty %d readerr %d recover %d\n",
					b[0], b[1], b[2], b[3], b[4], b[5], k+1,
					rx.txwindow, rx.fcmask, rx.nresync,
					rx.nempty, rx.nreaderr, sdhcinrecover);
				memmove(fw.bssid, b, 6);
				break;
			}
			tsleep(&up->sleep, return0, nil, 500);
		}
		if(k == 10)
			print("sdio: the control channel is still stalled "
				"(window %d fcmask %#ux resyncs %d "
				"empty %d readerr %d recover %d)\n",
				rx.txwindow, rx.fcmask, rx.nresync,
				rx.nempty, rx.nreaderr, sdhcinrecover);
	}
	fw.joined = 1;
	return 0;
}

char*
sdiostate(void)
{
	static char buf[128];

	snprint(buf, sizeof buf,
		"up %d enabled %d joined %d bssid %2.2ux:%2.2ux:%2.2ux:%2.2ux:%2.2ux:%2.2ux\n"
		"chip %d rev %d ram %lud at %#lux loaded %lud nvram %d\n",
		fw.up, fw.enabled, fw.joined, fw.bssid[0], fw.bssid[1],
		fw.bssid[2], fw.bssid[3], fw.bssid[4], fw.bssid[5],
		sb.chipid, sb.chiprev, (ulong)sb.socramsize,
		(ulong)sb.rambase, (ulong)fw.off, fw.nvlen);
	return buf;
}

#ifdef SDIOTEST
enum { Wlon = 129 };		/* VideoCore gpio expander: 128 BT_ON, 129 WL_ON */
extern int mboxsetgpio(int, int);

void
sdiocheck(void)
{
	static uchar blkbuf[Secsize], blkback[Secsize];
	uchar buf[64], back[64];
	int nfn, rev, i, v;

	v = 0;

	/*
	 * Power the radio first.
	 *
	 * The BCM43430's enable is not a SoC pin.  It hangs off the
	 * VideoCore GPIO expander the ARM cannot reach, line 129 (WL_ON;
	 * 128 is BT_ON), and the only way to it is to ask the firmware --
	 * mboxsetgpio() in mailbox.c.  A radio that was never powered
	 * answers CMD5 exactly the way a radio that is not there does, so
	 * probing without this cannot tell "no chip" from "chip asleep",
	 * and that is the one distinction this probe exists to make.
	 *
	 * QEMU models no expander and no BCM43430, so this is a no-op
	 * there and the failure to set it is reported rather than fatal.
	 */
	/*
	 * Before asking why one line was refused, establish whether the
	 * firmware carries these tags at all.
	 *
	 * The first attempt printed "response 0x80000000 tag 0x8": the
	 * mailbox call itself succeeded and the TAG's response word came
	 * back with bit 31 clear, which in this protocol means the
	 * firmware did not handle that tag -- not that it handled it and
	 * said no.  A request that is simply malformed looks the same
	 * from outside, so that alone does not name a cause.
	 *
	 * The rest of mailbox.c is the control: memory, MAC, board
	 * revision, serial, OTP, clocks and the framebuffer all answer
	 * through the identical request path, and mboxsetgpio is built
	 * field for field like mboxsetclock, which works.  So the request
	 * shape is not in question and the remaining question is whether
	 * 0x00030041/0x00038041 exist in THIS firmware.  Reading the
	 * lines answers it: a GET that is also unhandled means the whole
	 * expander family is missing and no amount of work on the SET
	 * will help.
	 */
	{
		extern int mboxgetgpio(int, int*);
		extern int mboxgetfwrev(u32*);
		u32 fw;
		int st;

		if(mboxgetfwrev(&fw) == 0)
			print("sdio: firmware revision %#lux\n", (ulong)fw);
		else
			print("sdio: firmware revision unavailable\n");
		for(i = 128; i <= 131; i++){
			st = -1;
			if(mboxgetgpio(i, &st) < 0)
				print("sdio: gpio %d: GET unhandled\n", i);
			else
				print("sdio: gpio %d reads %d\n", i, st);
		}
	}

	/*
	 * Is SET missing, or is WL_ON refused?
	 *
	 * GET (0x00030041) answers for every line and the values are
	 * coherent -- 128 BT_ON 1, 129 WL_ON 1, 130 PWR_LED_OFF 0, 131
	 * GLOBAL_RESET 1 -- so the expander tag family is present and the
	 * request path is right.  Only SET (0x00038041) comes back with
	 * bit 31 clear.  Two explanations survive that: the firmware does
	 * not carry the SET tag at all, or it carries it and declines the
	 * lines it manages itself, of which the Wi-Fi enable would be one.
	 *
	 * Writing a DIFFERENT line separates them.  130 is PWR_LED_OFF,
	 * and writing it back the value it already reads changes nothing
	 * on the board whichever way the call goes.
	 */
	{
		extern int mboxsetgpio(int, int);
		int gv;

		/*
		 * Try the SET request with each plausible request-length
		 * field before concluding anything about the firmware.
		 * The working GET on these same lines sends 4 where this
		 * sends 8; 0 is what a pure-response tag would carry.
		 */
		{
			extern int mboxsetgpioreq(int, int, int, u32*);
			u32 tr;
			int rb;

			for(rb = 0; rb <= 8; rb += 4){
				tr = 0;
				if(mboxsetgpioreq(130, 0, rb, &tr) == 0)
					print("sdio: SET reqlen %d WORKED "
						"(tag %#lux)\n", rb, (ulong)tr);
				else
					print("sdio: SET reqlen %d unhandled "
						"(tag %#lux)\n", rb, (ulong)tr);
			}
		}

		gv = 0;
		if(mboxgetgpio(130, &gv) == 0){
			if(mboxsetgpio(130, gv) < 0)
				print("sdio: SET refused for 130 too: the tag is missing\n");
			else
				print("sdio: SET works for 130: WL_ON is refused specifically\n");
		}
	}

	if(mboxsetgpio(Wlon, 1) < 0)
		print("sdio: WL_ON (firmware gpio %d) not set: "
			"a sleeping radio and an absent one look alike\n", Wlon);
	else
		delay(150);		/* the chip needs a moment after power */

	/*
	 * Two preconditions the radio needs before CMD5 can mean
	 * anything, both read-only, both free.
	 *
	 * The BCM43438 wants a 32.768kHz low-power oscillator, and on this
	 * board it comes from the SoC: GPCLK2 on GPIO 43, set up by the
	 * firmware before the kernel runs.  A radio with no LPO never
	 * brings its SDIO interface up, and the symptom is exactly what is
	 * seen here -- an enable line that reads high and a CMD5 that
	 * times out with the bus idle.  Nothing in this kernel programs
	 * GPCLK2, so the question is whether the firmware left it running
	 * and whether anything since has disturbed it.
	 *
	 * And read the SDIO pins BACK.  sdioinit writes Alt3 to 34-39 and
	 * has never once checked that it took; a mux that did not move
	 * would produce this same silence, and "I wrote the register" is
	 * not the same claim as "the pin is in that function".
	 */
	{
		extern int gpiofselget(int);
		volatile u32 *cm = (volatile u32*)(BCMPERIPH + 0x101000);
		u32 ctl, div;
		int f;

		f = gpiofselget(43);
		ctl = cm[0x80/4];
		div = cm[0x84/4];
		print("sdio: gpio43 fsel %d (4 = alt0 = GPCLK2), "
			"GP2CTL %#lux GP2DIV %#lux\n",
			f, (ulong)ctl, (ulong)div);
		if((ctl & (1<<4)) == 0)
			print("sdio: GPCLK2 IS NOT ENABLED -- the radio has no "
				"32kHz LPO and cannot answer CMD5\n");
		for(i = 34; i <= 39; i++)
			gpiofsel(i, Alt3);
		for(i = 34; i <= 39; i++)
			if(gpiofselget(i) != Alt3)
				print("sdio: gpio%d did NOT take Alt3 "
					"(reads %d)\n", i, gpiofselget(i));
	}

	/*
	 * Which board is this, exactly?
	 *
	 * Everything on the SoC side now checks out -- pins routed and
	 * read back, LPO running at exactly 32768Hz, enable high, bus
	 * clock legal -- and nothing answers.  Two hypotheses are left:
	 * the chip needs a reset that cannot be performed without
	 * SET_GPIO_STATE, or there is no chip on those pins.  The board
	 * revision settles the second, and it costs one mailbox call.
	 * It also decides which firmware and which .bin a port of
	 * ether4330 would need, so it is worth having written down
	 * either way: a 3B carries a BCM43438, a 3B+ a BCM43455.
	 */
	/*
	 * Does the controller's Capabilities register agree with the
	 * firmware about the EMMC clock?
	 *
	 * The divider is computed from Capabilities bits 8-15, and that
	 * field is unreliable on this part -- sdhcispeed carries a
	 * firmware fallback for the case where it reads zero, which is an
	 * admission that it is not to be trusted.  config.txt on this card
	 * sets core_freq=250, and the EMMC clock is derived from the core
	 * clock, so a Capabilities value of 200MHz is worth checking
	 * rather than believing.  If the two disagree, the 400kHz this
	 * driver reports is arithmetic on a wrong number and the bus is
	 * running at some other speed entirely.
	 */
	{
		extern int mboxgetclock(int, u32*);
		u32 fwhz;
		int caps;

		caps = (((volatile u32*)SDHCI)[Capabilities] >> 8) & 0xff;
		if(mboxgetclock(Emmcclkid, &fwhz) == 0)
			print("sdio: EMMC clock -- capabilities says %d MHz, "
				"firmware says %ud Hz\n", caps, fwhz);
		else
			print("sdio: EMMC clock -- capabilities says %d MHz, "
				"firmware will not say\n", caps);
	}

	{
		extern int mboxgetrevserial(u32*, uvlong*);
		u32 brev;
		uvlong ser;

		if(mboxgetrevserial(&brev, &ser) == 0)
			print("sdio: board revision %#lux serial %llux\n",
				(ulong)brev, ser);
		else
			print("sdio: board revision unavailable\n");
	}

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

	/*
	 * Dump the card common control registers.
	 *
	 * The CMD53 exchange below writes 64 bytes to function 1 at
	 * 0x400 and reads them back, which is a fair test of the QEMU
	 * SDIO function model it was written against -- that model has
	 * plain readable memory there.  A BCM43438 does not: function 1
	 * at that offset is the chip's backplane window, and reading it
	 * without first setting the window up is not a meaningful
	 * request.  So a CMD53 failure here is not evidence that the
	 * transport is broken, and it should not be read as one.
	 *
	 * What IS worth having from real silicon is the card describing
	 * itself over CMD52, which works.  This dump is that: the whole
	 * low CCCR, including the capability byte and the CIS pointer,
	 * from the actual chip.
	 */
	print("sdio: CCCR");
	for(i = 0; i <= 0x16; i++){
		v = sdiocmd52(0, i, 0, 0);
		if(v < 0){
			print(" <read of %#ux failed>", i);
			break;
		}
		print(" %2.2ux", v);
	}
	print("\n");

	/*
	 * Set the block sizes before any CMD53.
	 *
	 * The dump above says function 0's block size (CCCR 0x10/0x11) is
	 * ZERO on this chip as it comes up, and function 1's FBR block
	 * size has never been set either.  Every real SDIO driver
	 * programs both before it transfers anything, and a card asked to
	 * move data with no block size agreed is being asked something
	 * meaningless.
	 *
	 * 64 bytes, which is what ether4330 uses for this part.
	 */
	if(sdiocmd52(0, 0x10, 1, 64) < 0 || sdiocmd52(0, 0x11, 1, 0) < 0)
		print("SDIO-WARN could not set the function 0 block size\n");
	if(sdiocmd52(0, 0x110, 1, 64) < 0 || sdiocmd52(0, 0x111, 1, 0) < 0)
		print("SDIO-WARN could not set the function 1 block size\n");
	v = sdiocmd52(0, 0x10, 0, 0);
	i = sdiocmd52(0, 0x11, 0, 0);
	sdioblksize = v | (i << 8);
	if(sdioblksize <= 0 || sdioblksize > Secsize)
		sdioblksize = Secsize;
	print("sdio: function 0 block size now %d\n", sdioblksize);

	/*
	 * Read the chip's OWN ID through the backplane window -- first
	 * with CMD52 alone, then the same four bytes with one CMD53.
	 *
	 * This is the test that was missing.  Every CMD53 attempt so far
	 * used function 1 offset 0x400, which is plain memory on the
	 * QEMU function model and the backplane window on real silicon,
	 * so a failure there said nothing about the transport.  Here both
	 * transports read the SAME four bytes at the SAME address, and
	 * CMD52 is already known to work -- so CMD52 is the control and
	 * any disagreement is CMD53's.
	 *
	 * The window is set through function 1's SBADDRLOW/MID/HIGH
	 * (0x1000a-c); the low fifteen bits of the backplane address are
	 * then the offset within the window.  0x18000000 is the SI
	 * enumeration space, whose first word is the chipid register.
	 *
	 * A BCM43430 should say 0xa9a6 in the low sixteen bits -- 43430
	 * in hex.  That is a falsifiable prediction about which chip is
	 * on the other end, not just a liveness check.
	 */
	{
		uchar id52[4], id53[4];
		int bad;

		sdiocmd52(1, 0x1000a, 1, (0x18000000 >> 8) & 0x80);
		sdiocmd52(1, 0x1000b, 1, (0x18000000 >> 16) & 0xff);
		sdiocmd52(1, 0x1000c, 1, (0x18000000 >> 24) & 0xff);

		bad = 0;
		for(i = 0; i < 4; i++){
			v = sdiocmd52(1, i, 0, 0);
			if(v < 0){
				bad = 1;
				break;
			}
			id52[i] = v;
		}
		if(bad)
			print("SDIO-BACKPLANE-FAIL CMD52 read of the chipid "
				"register\n");
		else
			/*
			 * chipid register: id in bits 0-15, revision in
			 * 16-19, package in 20-23, core count in 24-27.
			 * The first version of this printed id52[3]&0xf
			 * as the revision, which is bits 24-27 -- the
			 * core count -- and reported "rev 5" for a part
			 * that is revision 1.
			 */
			v = id52[0] | id52[1] << 8 | id52[2] << 16 | id52[3] << 24;
			print("sdio: chipid %#lux -> chip %#ux rev %d, "
				"%d cores\n", (ulong)v, v & 0xffff,
				(v >> 16) & 0xf, (v >> 24) & 0xf);

		/*
		 * And block mode, at size, which is the thing the
		 * firmware upload actually depends on.
		 *
		 * The four-byte read below proves the byte-mode data
		 * path and nothing more.  Loading this part means
		 * several hundred kilobytes of BLOCK writes, so a
		 * transport that is only known good for four bytes is
		 * not known good for that.
		 *
		 * The enumeration space is readable and its first word
		 * is already known from CMD52, so reading 8 blocks of 64
		 * over it is checkable: the first four bytes must be the
		 * chipid, and every byte must agree with the same region
		 * read byte-mode.  That compares block against byte over
		 * identical addresses rather than trusting either alone.
		 */
		{
			static uchar blk[512];

			memset(blk, 0, sizeof blk);
			/*
			 * ONE block before many.
			 *
			 * Fixing the block size took the end-bit error
			 * away and left a data CRC, and that can still be
			 * either of two things: multi-block transfers
			 * being wrong, or this address range not being
			 * readable as a long span -- the enumeration space
			 * is registers, not memory, and reading across it
			 * is not obviously legal.  A single block settles
			 * which: it covers only the first 64 bytes, which
			 * hold the chipid word that CMD52 already read.
			 */
			/*
			 * Sb32bit (0x8000) OR'd into the offset.
			 *
			 * 9front's sbrw passes off|Sb32bit on every
			 * backplane access; it asks the chip for 32-bit
			 * access to the window.  The multi-block read
			 * here omitted it and got a data CRC, which is
			 * the chip declining to drive a transfer it was
			 * not asked for properly rather than a broken
			 * transport.  A four-byte byte-mode read happened
			 * to work without it, which is why it went
			 * unnoticed.
			 */
			if(sdiocmd53(1, Sb32bit, 0, 1, 1, blk, 1) != 1)
				print("SDIO-BLOCK1-FAIL one %d-byte block -- %s "
					"(interrupt %#lux)\n", sdioblksize,
					sdio53why, (ulong)sdio53int);
			else if(blk[0] != id52[0] || blk[1] != id52[1])
				print("SDIO-BLOCK1-WRONG %2.2ux %2.2ux vs chipid "
					"%2.2ux %2.2ux\n", blk[0], blk[1],
					id52[0], id52[1]);
			else
				print("sdio: BLOCK1-OK one %d-byte block reads "
					"the chipid correctly\n", sdioblksize);

			/*
			 * Where does multi-block start failing, and is it
			 * the incrementing address?
			 *
			 * One block works and eight do not.  9front reads
			 * exactly these 512 bytes as 8x64 in corescan, so
			 * the request is legal and the bug is here.  Walk
			 * the block count, and try the eight-block case
			 * once more with the address held still: if fixed
			 * addressing works, the fault is in how the
			 * address advances, not in multi-block itself.
			 */
			/*
			 * Which window offsets can be read at all?
			 *
			 * With one block per command, "2 blocks" failing
			 * means the SECOND single-block read -- window
			 * offset 0x40 -- failed while offset 0 worked.  So
			 * this is the address, not the transfer size, and
			 * the thing to do is map it rather than guess.
			 * Byte-mode CMD52 of the same offset is the
			 * control: if CMD52 can read what a 64-byte block
			 * cannot, the fault is in the block path; if
			 * neither can, the region is not readable.
			 */
			/*
			 * How far from offset 0 does CMD53 still work?
			 *
			 * Every access at 0x40 fails -- byte mode, block
			 * mode, flag or no flag -- while CMD52 reads the
			 * same address happily.  So CMD53 reaches window
			 * offset 0 and nothing else, and the question is
			 * where it stops.  A fine scan with the form most
			 * likely to succeed (byte mode, four bytes, the
			 * 32-bit flag) against a CMD52 control at the same
			 * address.
			 */
			/*
			 * REQUEST THE BACKPLANE CLOCK FIRST.
			 *
			 * Reads succeed for window offsets 0x00-0x3c and
			 * fail from 0x40 on, for four-byte and sixty-four
			 * byte transfers alike: exactly the first 64 bytes
			 * are reachable.  That is the shape of a backplane
			 * that has not been clocked -- the always-on
			 * registers answer and nothing else does -- rather
			 * than anything about transfer size, which is what
			 * the last several experiments were chasing.
			 *
			 * Clkcsr is function 1 register 0x1000e: ask for
			 * the ALP clock and wait for it to be available.
			 */
			{
				int k, cc;

				sdiocmd52(1, Clkcsr, 1, 0);
				delay(1);
				sdiocmd52(1, Clkcsr, 1, Nohwreq | ReqALP);
				for(k = 0; k < 200; k++){
					cc = sdiocmd52(1, Clkcsr, 0, 0);
					if(cc >= 0 && (cc & (ALPavail|HTavail)))
						break;
					delay(1);
				}
				sdiocmd52(1, Clkcsr, 1, Nohwreq | ForceALP);
				delay(1);
				print("sdio: Clkcsr %#ux after %d ms%s\n",
					sdiocmd52(1, Clkcsr, 0, 0), k,
					k >= 200? " (ALP NEVER CAME)" : "");
			}

			sbinit();
		}

		memset(id53, 0, sizeof id53);
		if(sdiocmd53(1, Sb32bit, 0, 0, 1, id53, 4) != 4)
			print("SDIO-CMD53-BACKPLANE-FAIL -- %s "
				"(interrupt %#lux status %#lux)\n", sdio53why,
				(ulong)sdio53int, (ulong)sdio53stat);
		else if(!bad && memcmp(id52, id53, 4) == 0)
			print("sdio: CMD53-OK the same four bytes read back "
				"identically through CMD53\n");
		else
			print("sdio: CMD53-WRONG read %2.2ux %2.2ux %2.2ux %2.2ux, "
				"CMD52 said %2.2ux %2.2ux %2.2ux %2.2ux\n",
				id53[0], id53[1], id53[2], id53[3],
				id52[0], id52[1], id52[2], id52[3]);
	}

	for(i = 0; i < sizeof buf; i++)
		buf[i] = 0xa0 + i;
	memset(back, 0, sizeof back);
	if(sdiocmd53(1, 0x400, 1, 0, 1, buf, sizeof buf) != sizeof buf){
		print("SDIO-FAIL CMD53 write -- %s (interrupt %#lux status %#lux)\n", sdio53why, (ulong)sdio53int, (ulong)sdio53stat);
		return;
	}
	if(sdiocmd53(1, 0x400, 0, 0, 1, back, sizeof back) != sizeof back){
		print("SDIO-CMD53-NA read -- %s (interrupt %#lux status %#lux); "
			"expected against a real BCM43438, whose function 1 at "
			"0x400 is a backplane window, not memory\n",
			sdio53why, (ulong)sdio53int, (ulong)sdio53stat);
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
		print("SDIO-FAIL CMD53 block write -- %s (interrupt %#lux)\n", sdio53why, (ulong)sdio53int);
		return;
	}
	if(sdiocmd53(1, 0x800, 0, 1, 1, blkback, 1) != 1){
		print("SDIO-FAIL CMD53 block read -- %s (interrupt %#lux)\n", sdio53why, (ulong)sdio53int);
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
