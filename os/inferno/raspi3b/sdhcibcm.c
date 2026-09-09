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
	r[Control1] = (0x80 << 8) | (0xe << 16) | Clkintlen;
	if(awaitbit(&r[Control1], Clkstable, 1) < 0)
		return -1;
	r[Control1] |= Clken;

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
