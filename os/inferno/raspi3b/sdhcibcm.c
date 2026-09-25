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
 * Widen the bus and raise the clock, or not.  Off while the intermittent
 * CMD53 failures are being pinned down: every measurement before the
 * four-bit change was taken at 1-bit and 400kHz.
 */
static int sdiofast = 0;
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
static void
sdhcirecover(Ctlr *c, u32 flags)
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
		blksize = sdioblksize;
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
	 * Prove the chip's RAM can be WRITTEN, not just read.
	 *
	 * Every transfer measured so far has been a read, and the
	 * firmware upload is 399344 bytes of writes.  A pattern with a
	 * position in every word catches a transfer that lands at the
	 * wrong offset as well as one that corrupts, which a constant
	 * fill would not.
	 */
	{
		static uchar w[512], rb[512];
		int i, bad;

		for(i = 0; i < sizeof w; i++)
			w[i] = (i * 7 + 0x5a) & 0xff;
		memset(rb, 0, sizeof rb);
		if(sbmem(1, w, sizeof w, sb.rambase) < 0)
			print("sdio: RAM-WRITE-FAIL\n");
		else if(sbmem(0, rb, sizeof rb, sb.rambase) < 0)
			print("sdio: RAM-READBACK-FAIL\n");
		else{
			bad = 0;
			for(i = 0; i < sizeof w; i++)
				if(w[i] != rb[i])
					bad++;
			if(bad == 0)
				print("sdio: RAM-OK 512 bytes written to chip RAM "
					"and read back identical\n");
			else
				print("sdio: RAM-WRONG %d of 512 bytes differ "
					"(%2.2ux vs %2.2ux)\n", bad, w[0], rb[0]);
		}

		/*
		 * And at the size the firmware actually is.
		 *
		 * 512 bytes stays inside one window.  The firmware is
		 * 399344 bytes, which slides the window a dozen times and
		 * is the first thing to exercise sbmem's clipping at a
		 * window boundary -- the place an off-by-one would put the
		 * tail of one chunk at the start of the next.  No buffer
		 * that size exists here, so it goes out in 4KB pieces with
		 * a position-dependent pattern and comes back the same
		 * way; a chunk landing at the wrong offset shows up as a
		 * mismatch rather than being invisible the way a constant
		 * fill would be.
		 */
		{
			static uchar chunk[4096];
			int k, j, nbad, off;
			enum { Fwsize = 399344 };

			nbad = 0;
			for(off = 0; off < Fwsize; off += sizeof chunk){
				k = Fwsize - off;
				if(k > sizeof chunk)
					k = sizeof chunk;
				for(j = 0; j < k; j++)
					chunk[j] = ((off + j) * 31 + 0x9e) & 0xff;
				if(sbmem(1, chunk, k, sb.rambase + off) < 0){
					print("sdio: BIG-WRITE-FAIL at %d\n", off);
					nbad = -1;
					break;
				}
			}
			if(nbad == 0)
				for(off = 0; off < Fwsize; off += sizeof chunk){
					k = Fwsize - off;
					if(k > sizeof chunk)
						k = sizeof chunk;
					memset(chunk, 0, k);
					if(sbmem(0, chunk, k, sb.rambase + off) < 0){
						print("sdio: BIG-READ-FAIL at %d\n", off);
						nbad = -1;
						break;
					}
					for(j = 0; j < k; j++)
						if(chunk[j] != (uchar)(((off + j) * 31 + 0x9e) & 0xff))
							nbad++;
				}
			if(nbad == 0)
				print("sdio: BIG-OK %d bytes through chip RAM "
					"intact\n", Fwsize);
			else if(nbad > 0)
				print("sdio: BIG-WRONG %d bytes differ\n", nbad);
		}
	}
	return 0;
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
