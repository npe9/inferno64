/*
 * BCM2835 Secondary Memory Interface (0x3f600000).
 *
 * SMI drives a parallel bus off the SoC on GPIO 0-25 in alt1: an
 * address, up to eighteen data lines, and read/write strobes.  It is
 * how a Pi talks to an FPGA, a parallel LCD controller or a camera
 * sensor, and it is the only peripheral on this SoC whose *timing* is
 * programmable in the same sense a memory controller's is.
 *
 * Two ways to move data, and they are for different things:
 *
 *   Direct mode (SMIDCS/SMIDA/SMIDD) asserts one address and one word.
 *   It is for registers on the far side -- a control write, a status
 *   read -- and needs no FIFO.
 *
 *   Programmed mode (SMICS/SMIL/SMIA/SMID) is given a length and moves
 *   that many words through a FIFO, at a rate the device settings
 *   registers set.  It is for bulk, and it is what DMA pairs with.
 *
 * FOUR THINGS THIS BLOCK GETS A DRIVER WRONG.
 *
 * 1.  The rate is not a divisor.  A word takes setup + strobe + hold +
 *     pace cycles of the SMI clock, all programmed per device, and
 *     there are four independent device banks so one bus can carry
 *     peripherals with different timing.  Getting the arithmetic wrong
 *     gives a bus that works at the wrong speed rather than an error,
 *     which on real hardware means marginal signals rather than a
 *     failure you can see.
 *
 * 2.  DONE means different things in each direction.  For a write it
 *     is set when the last word has gone.  For a read it is NOT set
 *     until the FIFO has also been emptied -- so a driver that waits
 *     for DONE and only then starts reading waits forever.  The right
 *     shape is to drain while polling, which is what smiread() does.
 *
 * 3.  SMIFD's two counters are six bits.  They saturate at 63 and
 *     cannot express a full 64-word FIFO, so a driver that reads FCNT
 *     and drains exactly that many words leaves one behind every time
 *     the FIFO fills completely.
 *
 * 4.  SMICS must not be read-modify-written.  AFERR, SETERR and DONE
 *     are write-one-to-clear, so an r[Cs] |= Start reads the register
 *     with an error set, writes it back set, and clears it as a side
 *     effect.  This file keeps a shadow of the writable bits, the same
 *     discipline i2sbcm.c needs for the same reason.
 *
 * Register layout and bit meanings are from the Raspberry Pi kernel's
 * include/linux/broadcom/bcm2835_smi.h, which documents every bit
 * rather than merely naming it.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

extern uvlong systmrread(void);		/* systmrbcm.c */

enum {
	/* SMI registers, word offsets */
	Cs	= 0x00/4,
	L	= 0x04/4,
	A	= 0x08/4,
	D	= 0x0c/4,
	Dsr0	= 0x10/4,
	Dsw0	= 0x14/4,
	Dc	= 0x30/4,
	Dcs	= 0x34/4,
	Da	= 0x38/4,
	Dd	= 0x3c/4,
	Fd	= 0x40/4,

	/* SMICS */
	Rxf	= 1<<31,
	Txe	= 1<<30,
	Rxd	= 1<<29,
	Txd	= 1<<28,
	Rxr	= 1<<27,
	Txw	= 1<<26,
	Aferr	= 1<<25,	/* FIFO read empty or written full; w1c */
	Pxldat	= 1<<14,
	Seterr	= 1<<13,	/* settings written during a transfer; w1c */
	Intr	= 1<<11,
	Intt	= 1<<10,
	Intd	= 1<<9,
	Write	= 1<<5,		/* 1 = write to the device, 0 = read */
	Clear	= 1<<4,		/* clear the FIFO */
	Start	= 1<<3,
	Active	= 1<<2,
	Done	= 1<<1,		/* w1c */
	Enable	= 1<<0,

	/* device settings: read bank */
	Rsetupshift = 24,	/* 6 bits */
	Rholdshift = 16,	/* 6 bits */
	Rpaceshift = 8,		/* 7 bits */
	/* Rstrobe is 7 bits at 0 */

	/* device settings: write bank, same shape */
	Wsetupshift = 24,
	Wholdshift = 16,
	Wpaceshift = 8,

	/* SMIDCS */
	Dcswrite = 1<<3,
	Dcsdone	= 1<<2,		/* w1c */
	Dcsstart = 1<<1,
	Dcsenable = 1<<0,

	/* SMIFD */
	Flvlshift = 8,
	Fcntmask = 0x3f,

	/* Clock manager, word offsets from CPRMAN */
	Smictl	= 0x0b0/4,
	Smidiv	= 0x0b4/4,

	Cmpassword = 0x5a000000,
	Cmenable = 1<<4,
	Cmkill	= 1<<5,
	Cmbusy	= 1<<7,
	Cmsrcosc = 1,

	Smidivishift = 12,	/* only 4 bits on this mux */
	Smidivfshift = 4,	/* 8 bits */

	Oschz	= 19200000,

	/* The timing this driver programs for device 0. */
	Setup	= 32,
	Strobe	= 64,
	Hold	= 32,
	Pace	= 0,
	Cycles	= Setup + Strobe + Hold + Pace,

	Divi	= 15,		/* the slowest this mux goes: 1.28MHz */

	Maxfifo	= 256,		/* an upper bound for the depth probe */
	Timeout	= 1000000,
};

static u32*
smi(void)
{
	return (u32*)SMI0;
}

static u32*
cm(void)
{
	return (u32*)CPRMAN;
}

/*
 * A shadow of the writable control bits of SMICS.  See point 4 at the
 * top: this register must never be read-modify-written.
 */
static u32 csshadow;

static void
cswrite(u32 bits)
{
	csshadow = bits;
	smi()[Cs] = csshadow;
}

/* Clear write-one-to-clear status, or pulse a one-shot bit. */
static void
csack(u32 bits)
{
	smi()[Cs] = csshadow | bits;
}

/*
 * Start the SMI clock at the crystal divided by divi.  Same
 * kill/wait/set/enable/wait dance as the PWM and PCM clocks, with the
 * 0x5a password on every write; the divisor here is only four bits.
 */
ulong
smiclock(int divi)
{
	u32 *r = cm();
	int i;

	if(divi < 1)
		divi = 1;
	if(divi > 0xf)
		divi = 0xf;

	r[Smictl] = Cmpassword | Cmkill;
	for(i = 0; i < Timeout; i++)
		if((r[Smictl] & Cmbusy) == 0)
			break;
	if(i == Timeout)
		return 0;

	r[Smidiv] = Cmpassword | (divi << Smidivishift);
	r[Smictl] = Cmpassword | Cmsrcosc;
	r[Smictl] = Cmpassword | Cmsrcosc | Cmenable;

	for(i = 0; i < Timeout; i++)
		if(r[Smictl] & Cmbusy)
			break;
	if(i == Timeout)
		return 0;
	return Oschz / divi;
}

/*
 * Program the timing for one of the four device banks.  All four
 * fields are "minimum 1" in the hardware, so a zero is one cycle; this
 * passes them through unchanged so the caller sees what it asked for.
 */
void
smitiming(int dev, int setup, int strobe, int hold, int pace)
{
	u32 *r = smi();
	u32 v;

	v = ((u32)setup << Rsetupshift) | ((u32)hold << Rholdshift) |
		((u32)pace << Rpaceshift) | (u32)strobe;
	r[Dsr0 + dev*2] = v;
	r[Dsw0 + dev*2] = v;
}

/*
 * A programmed read of n words into buf.
 *
 * The shape matters.  DONE is not set for a read until the FIFO has
 * been emptied as well, so this drains while polling rather than
 * waiting for DONE and then draining -- the latter never returns.
 */
int
smiread(u32 *buf, int n)
{
	u32 *r = smi();
	int i, got;

	cswrite(Enable);
	csack(Clear);
	csack(Aferr | Seterr | Done);
	r[L] = n;
	r[A] = 0;			/* device 0, address 0 */

	cswrite(Enable);		/* Write clear: this is a read */
	csack(Start);

	got = 0;
	for(i = 0; i < Timeout && got < n; i++)
		if(r[Cs] & Rxd)
			buf[got++] = r[D];
	if(got < n)
		return -1;
	return got;
}

/*
 * Bring the block up and prove what can be proved without a device on
 * the far side of the pins -- which is everything except the pins.
 *
 * The check that carries the weight is the last one: a programmed
 * transfer is timed against the 1MHz system timer and compared with
 * what the device settings registers say it should take.  Those
 * registers are the whole point of this block, and without an
 * independent clock they are just storage a driver writes and never
 * sees again.
 */
void
smiinit(void)
{
	u32 *r = smi();
	static u32 buf[Maxfifo];
	ulong smihz, wordhz, elapsed, expect;
	uvlong t1, t2;
	long err;
	int i, depth, n;

	/*
	 * Is the block there?  A device settings register is plain
	 * read/write storage while no transfer is running, so a value
	 * that does not come back means nothing is mapped here.
	 */
	r[Dsr0] = 0x0f0f0f0f;
	if(r[Dsr0] != 0x0f0f0f0f){
		print("SMI-NONE no SMI block at %#p\n", (void*)SMI0);
		r[Dsr0] = 0;
		return;
	}
	r[Dsr0] = 0;

	smihz = smiclock(Divi);
	if(smihz == 0){
		print("SMI-FAIL clock never started (ctl %#ux div %#ux)\n",
			cm()[Smictl], cm()[Smidiv]);
		return;
	}
	smitiming(0, Setup, Strobe, Hold, Pace);
	wordhz = smihz / Cycles;

	cswrite(Enable);
	csack(Clear);
	csack(Aferr | Seterr | Done);
	if(r[Cs] & (Aferr|Seterr)){
		print("SMI-FAIL errors will not clear (cs %#ux)\n", r[Cs]);
		return;
	}
	if((r[Cs] & Txe) == 0 || (r[Cs] & Txd) == 0){
		print("SMI-FAIL FIFO not empty after a clear (cs %#ux)\n", r[Cs]);
		return;
	}

	/*
	 * Measure the FIFO depth rather than assuming it.  A test built
	 * on a remembered constant passes for the wrong reason the day
	 * the constant is wrong, and this one is cheap.
	 */
	for(depth = 0; depth < Maxfifo; depth++){
		if((r[Cs] & Txd) == 0)
			break;
		r[D] = 0x1000 + depth;
	}
	if(depth == 0 || depth == Maxfifo){
		print("SMI-FAIL FIFO depth probe gave %d (cs %#ux)\n",
			depth, r[Cs]);
		return;
	}
	if((r[Cs] & Rxf) == 0){
		print("SMI-FAIL FIFO not full after %d words (cs %#ux)\n",
			depth, r[Cs]);
		return;
	}

	/*
	 * The six-bit counter cannot express a full FIFO.  Check that,
	 * rather than checking that FCNT equals the depth, which is what
	 * a driver written from the field width alone would expect.
	 */
	if(depth > Fcntmask && (r[Fd] & Fcntmask) != Fcntmask){
		print("SMI-FAIL FCNT is %ud with %d words in a %d-deep FIFO\n",
			r[Fd] & Fcntmask, depth, depth);
		return;
	}

	/* Overrun it, and confirm the block says so. */
	r[D] = 0xdeadbeef;
	if((r[Cs] & Aferr) == 0){
		print("SMI-FAIL writing a full FIFO did not raise AFERR\n");
		return;
	}
	csack(Aferr);
	if(r[Cs] & Aferr){
		print("SMI-FAIL AFERR did not clear on write-one\n");
		return;
	}

	/* Drain it, then underrun it. */
	for(i = 0; i < depth; i++){
		u32 v = r[D];
		USED(v);
	}
	if((r[Cs] & Txe) == 0){
		print("SMI-FAIL FIFO not empty after draining %d (cs %#ux)\n",
			depth, r[Cs]);
		return;
	}
	{
		u32 v = r[D];			/* one too many */
		USED(v);
	}
	if((r[Cs] & Aferr) == 0){
		print("SMI-FAIL reading an empty FIFO did not raise AFERR\n");
		return;
	}
	csack(Aferr);

	/*
	 * Time a programmed read.  This is the check that gives the
	 * device settings registers an observable consequence.
	 */
	n = depth;
	csack(Clear);
	csack(Aferr | Seterr | Done);
	t1 = systmrread();
	if(smiread(buf, n) < 0){
		print("SMI-FAIL programmed read of %d words did not finish "
			"(cs %#ux)\n", n, r[Cs]);
		return;
	}
	t2 = systmrread();
	elapsed = (ulong)(t2 - t1);
	expect = (ulong)(((uvlong)n * 1000000) / wordhz);
	err = (long)elapsed - (long)expect;
	if(err < 0)
		err = -err;
	if(expect == 0 || err > (long)(expect/4)){
		print("SMI-FAIL reading %d words took %lud us, expected %lud "
			"at %lud words/s\n", n, elapsed, expect, wordhz);
		return;
	}

	/*
	 * And DONE, which only arrives once the FIFO has been emptied
	 * too.  smiread() drained as it went, so it should be set now.
	 */
	if((r[Cs] & Done) == 0){
		print("SMI-FAIL DONE not set after a drained read (cs %#ux)\n",
			r[Cs]);
		return;
	}
	csack(Done);

	/*
	 * SETERR: writing a settings register while a transfer is
	 * running is an error the block reports.  This needs no FIFO and
	 * no device, so it is a second error path independent of AFERR.
	 */
	csack(Clear);
	csack(Aferr | Seterr | Done);
	r[L] = n;
	r[A] = 0;
	cswrite(Enable);
	csack(Start);
	if((r[Cs] & Active) == 0){
		print("SMI-FAIL transfer not ACTIVE after START (cs %#ux)\n",
			r[Cs]);
		return;
	}
	r[L] = 1;				/* not allowed while active */
	if((r[Cs] & Seterr) == 0){
		print("SMI-FAIL a settings write during a transfer did not "
			"raise SETERR (cs %#ux)\n", r[Cs]);
		return;
	}
	if(r[L] != n){
		print("SMI-FAIL SETERR was raised but the write took anyway "
			"(%ud)\n", r[L]);
		return;
	}
	csack(Seterr);

	/* Let it finish, then put the block back. */
	for(i = 0; i < Timeout; i++)
		if(r[Cs] & Rxd)
			break;
	csack(Clear);
	csack(Aferr | Seterr | Done);
	cswrite(0);

	print("smi: smi at %#p, clock %lud Hz, %d cycles a word, %lud words/s\n",
		(void*)SMI0, smihz, Cycles, wordhz);
	print("smi: FIFO %d words, read %d in %lud us (%lud expected)\n",
		depth, n, elapsed, expect);
	print("SMI-OK timing registers, FIFO depth, both error paths, and a "
		"programmed read timed against the system timer\n");
}
