/*
 * BCM2835 I2S/PCM (0x3f203000): the SoC's audio serialiser.  A frame
 * of programmable length is clocked out of a 64-word TX FIFO and in to
 * a 64-word RX FIFO once per frame period, on GPIO 18-21.  This is how
 * a DAC or a MEMS microphone HAT is attached to a Pi.
 *
 * WHAT IS DIFFERENT ABOUT THIS BLOCK, and why the order below matters.
 *
 * 1.  It has no baud rate of its own.  The frame rate is the clock
 *     manager's PCM clock divided by the frame length in bits, so the
 *     sample rate is set in two places at once -- CM_PCMDIV and
 *     MODE_A's FLEN.  Getting one right and the other wrong gives
 *     audio at the wrong pitch rather than an error, so i2sconfig()
 *     below sets both from a single requested rate and returns what it
 *     actually achieved.
 *
 * 2.  The PCM clock needs the same kill/wait/set/enable dance as the
 *     PWM clock, with the 0x5a password on every write (pwmbcm.c).
 *     Unlike the PWM it usually needs the *fractional* divider too:
 *     48kHz stereo at 32 bits a channel wants a 3.072MHz bit clock,
 *     and 19.2MHz/3.072MHz is 6.25, not an integer.
 *
 * 3.  The FIFOs must be primed before TXON is set.  The serialiser
 *     starts clocking immediately, and an empty TX FIFO underflows on
 *     the first frame -- TXERR gets set and the first samples are
 *     whatever the pin was already doing.  Fill first, enable second.
 *
 * 4.  TXCLR and RXCLR are self-clearing and take two PCM clocks to
 *     act.  Reading them back to confirm the clear is a mistake: they
 *     read zero even while the clear is in progress.
 *
 * 5.  CS_A must never be read-modify-written.  TXERR and RXERR are
 *     write-one-to-clear, so an innocent-looking r[Cs] |= Txon reads
 *     the register with an error bit set, writes it back set, and
 *     clears the error as a side effect -- losing the one piece of
 *     information you would want after an underflow.  So this file
 *     keeps a shadow of the writable bits and always writes CS_A
 *     absolutely.  This is not an emulator artifact; it is how the
 *     silicon behaves, and it is the single easiest way to write a
 *     driver that loses errors it appeared to check for.
 *
 * The best-practices configuration is i2sconfig(48000): 64-clock
 * frames, two 32-bit channel slots carrying 16-bit samples left
 * justified, frame sync low for the left channel -- which is plain
 * I2S, what a PCM5102 or an SGTL5000 expects.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

extern void gpiofsel(int, int);		/* gpiobcm.c */

/* run the checks that need the PCM clock; see i2sinit() */
int i2sdeep = 0;
extern uvlong systmrread(void);		/* systmrbcm.c */

enum {
	/* PCM registers, word offsets */
	Cs	= 0x00/4,
	Fifo	= 0x04/4,
	Mode	= 0x08/4,
	Rxc	= 0x0c/4,
	Txc	= 0x10/4,
	Dreq	= 0x14/4,
	Inten	= 0x18/4,
	Intstc	= 0x1c/4,
	Gray	= 0x20/4,

	/* Cs */
	Csen	= 1<<0,		/* enable the block */
	Rxon	= 1<<1,
	Txon	= 1<<2,
	Txclr	= 1<<3,		/* self-clearing */
	Rxclr	= 1<<4,		/* self-clearing */
	Txthrshift = 5,
	Rxthrshift = 7,
	Dmaen	= 1<<9,
	Txsync	= 1<<13,
	Rxsync	= 1<<14,
	Txerr	= 1<<15,	/* write one to clear */
	Rxerr	= 1<<16,	/* write one to clear */
	Txw	= 1<<17,	/* TX FIFO needs writing */
	Rxr	= 1<<18,	/* RX FIFO needs reading */
	Txd	= 1<<19,	/* TX FIFO has room */
	Rxd	= 1<<20,	/* RX FIFO has data */
	Txe	= 1<<21,	/* TX FIFO empty */
	Rxf	= 1<<22,	/* RX FIFO full */
	Rxsex	= 1<<23,	/* sign-extend received samples */
	/* the writable bits of CS_A; everything else in it is status */
	Csctl	= Csen|Rxon|Txon|Txclr|Rxclr|(3<<Txthrshift)|(3<<Rxthrshift)|Dmaen|Rxsex,

	/* Mode */
	Fslenshift = 0,
	Flenshift = 10,
	Fsi	= 1<<20,	/* invert frame sync */
	Fsm	= 1<<21,	/* frame sync is an input */
	Clki	= 1<<22,	/* invert the bit clock */
	Clkm	= 1<<23,	/* bit clock is an input */
	Clkdis	= 1<<28,	/* stop the clock */

	/* Rxc/Txc: channel 1 in the top half, channel 2 in the bottom */
	Chwex	= 1<<15,	/* add 16 to the width */
	Chen	= 1<<14,
	Chposshift = 4,
	Ch1shift = 16,

	/* Inten/Intstc */
	Itxw	= 1<<0,
	Irxr	= 1<<1,
	Itxerr	= 1<<2,
	Irxerr	= 1<<3,

	Fifodepth = 64,

	/* Clock manager, word offsets from CPRMAN */
	Pcmctl	= 0x098/4,
	Pcmdiv	= 0x09c/4,

	Cmpassword = 0x5a000000,
	Cmenable = 1<<4,
	Cmkill	= 1<<5,
	Cmbusy	= 1<<7,
	Cmsrcosc = 1,		/* source 1: the 19.2MHz crystal */
	Cmmash1	= 1<<9,		/* one-stage MASH, needed for a fraction */

	Oschz	= 19200000,

	Framebits = 64,		/* two 32-bit channel slots */
	Alt0	= 4,		/* GPIO 18-21 carry PCM in alt0 */

	Timeout	= 100000,

	/*
	 * Timed attempts for the drain and fill checks; the best of
	 * them is used, since scheduling delay is one-sided.
	 */
	Ntimed	= 5,
};

static u32*
i2s(void)
{
	return (u32*)I2S0;
}

static u32*
cm(void)
{
	return (u32*)CPRMAN;
}

/*
 * A shadow of the writable control bits of CS_A.  Everything below
 * writes the register from this rather than from a read of it; see
 * point 5 at the top of the file for why that is not fussiness.
 */
static u32 csshadow;

/* Set the control bits absolutely. */
static void
cswrite(u32 bits)
{
	csshadow = bits;
	i2s()[Cs] = csshadow;
}

/*
 * Clear write-one-to-clear status bits, leaving the control bits where
 * they are.  Passing a self-clearing bit such as Txclr through here is
 * correct too: it acts once and reads back zero.
 */
static void
csack(u32 bits)
{
	i2s()[Cs] = csshadow | bits;
}

/*
 * Point the PCM clock at the crystal divided by divi + divf/4096, and
 * return the resulting frequency in Hz.  As with the PWM the clock has
 * to be stopped, and *seen* to be stopped, before the divisor will
 * take; and seen to be running afterwards, because a divisor that was
 * silently ignored leaves a serialiser that never clocks a frame.
 */
ulong
i2sclock(int divi, int divf)
{
	u32 *r = cm();
	int i;

	if(divi < 2)
		divi = 2;
	if(divi > 0xfff)
		divi = 0xfff;
	divf &= 0xfff;

	r[Pcmctl] = Cmpassword | Cmkill;
	for(i = 0; i < Timeout; i++)
		if((r[Pcmctl] & Cmbusy) == 0)
			break;
	if(i == Timeout)
		return 0;

	r[Pcmdiv] = Cmpassword | (divi << 12) | divf;
	r[Pcmctl] = Cmpassword | Cmsrcosc | (divf ? Cmmash1 : 0);
	r[Pcmctl] = Cmpassword | Cmsrcosc | (divf ? Cmmash1 : 0) | Cmenable;

	for(i = 0; i < Timeout; i++)
		if(r[Pcmctl] & Cmbusy)
			break;
	if(i == Timeout)
		return 0;

	return (ulong)(((uvlong)Oschz * 4096) / ((uvlong)divi * 4096 + divf));
}

/* Route the four PCM signals to the pins that carry them. */
void
i2spins(void)
{
	gpiofsel(18, Alt0);		/* PCM_CLK */
	gpiofsel(19, Alt0);		/* PCM_FS */
	gpiofsel(20, Alt0);		/* PCM_DIN */
	gpiofsel(21, Alt0);		/* PCM_DOUT */
}

/*
 * Configure plain I2S at the requested sample rate: 64-clock frames,
 * two 32-bit slots carrying 16-bit samples, frame sync marking the
 * left channel.  Returns the sample rate actually achieved, which is
 * not always the one asked for -- the caller should look at it.
 *
 * The block is left enabled with both FIFOs cleared and the
 * serialiser stopped, so the caller can prime the TX FIFO before
 * starting it.  That ordering is the point: see the note at the top.
 */
ulong
i2sconfig(ulong rate)
{
	u32 *r = i2s();
	uvlong want;
	ulong bitclk;
	int divi, divf;
	u32 chan;

	/*
	 * The bit clock is rate * 64.  Work out the crystal divisor as a
	 * 12.12 fixed-point number, which is what CM_PCMDIV holds, so a
	 * ratio like 19.2MHz/3.072MHz = 6.25 lands exactly rather than
	 * being truncated to 6.
	 */
	want = (uvlong)rate * Framebits;
	if(want == 0)
		return 0;
	divi = (int)(Oschz / want);
	divf = (int)((((uvlong)Oschz % want) * 4096) / want);

	bitclk = i2sclock(divi, divf);
	if(bitclk == 0)
		return 0;

	/*
	 * Master mode: the SoC drives both the bit clock and frame sync,
	 * so CLKM and FSM stay clear.  FSLEN of 32 makes frame sync a
	 * square wave -- one channel slot high, one low -- which is what
	 * I2S means by left and right.
	 */
	r[Mode] = ((Framebits - 1) << Flenshift) |
		((Framebits/2) << Fslenshift);

	/*
	 * Both channels enabled, 16 bits wide.  CHWID holds width - 8, so
	 * 16-bit samples are CHWID 8 with CHWEX clear.  Channel 1 starts
	 * at clock 1 and channel 2 at clock 33: the one-clock offset is
	 * what distinguishes I2S from left-justified, and getting it
	 * wrong shifts every sample by a bit.
	 */
	chan = (Chen | (1 << Chposshift) | 8) << Ch1shift;
	chan |= Chen | ((Framebits/2 + 1) << Chposshift) | 8;
	r[Txc] = chan;
	r[Rxc] = chan;

	/* Enable, then clear both FIFOs; the clears are self-clearing. */
	cswrite(Csen);
	csack(Txclr | Rxclr);

	return bitclk / Framebits;
}

/* Stop the serialiser but leave the configuration in place. */
void
i2sstop(void)
{
	cswrite(csshadow & ~(Txon|Rxon));
}

/*
 * Bring the block up and prove it works, the way pwmbcm.c does for the
 * PWM.  Three things are checked, in increasing order of how much they
 * can tell you:
 *
 *   the FIFOs and their flags, statically, with the serialiser stopped;
 *   the error and interrupt-status bits, which are easy to get
 *     backwards because both are write-one-to-clear;
 *   and the frame rate, dynamically, by timing how long the
 *     serialiser takes to drain a full FIFO and comparing that against
 *     the 1MHz system timer, which shares nothing with the PCM clock.
 *
 * The last is the one that matters.  A block whose registers all read
 * back correctly and whose serialiser runs at the wrong rate is a
 * working driver and broken audio, and the only way to see it here
 * rather than in a DAC is to time it against an independent clock.
 */
void
i2sinit(void)
{
	u32 *r = i2s();
	ulong rate, elapsed, expect;
	uvlong t1, t2;
	long err;
	int i, k;

	/*
	 * Is the block there?  MODE_A is plain read/write storage, so a
	 * value that does not read back means nothing is mapped here --
	 * which is what an emulator without a PCM model looks like.
	 */
	r[Mode] = 0x000fffff;
	if(r[Mode] != 0x000fffff){
		print("I2S-NONE no PCM block at %#p\n", (void*)I2S0);
		r[Mode] = 0;
		return;
	}
	r[Mode] = 0;

	/*
	 * Only the writable bits.  CS_A's top half is status -- FIFO
	 * empty, FIFO has room, FIFO needs writing, and the two sync
	 * bits -- and an idle block on the board reports 0x2a6000 there,
	 * which is all five of them and entirely correct.  QEMU's model
	 * reports zero, so "CS is 0 at reset" passed there and called a
	 * working part broken here.
	 */
	if((r[Cs] & Csctl) != 0){
		print("I2S-FAIL CS control bits are %#ux at reset, expected 0 (CS %#ux)\n",
			r[Cs] & Csctl, r[Cs]);
		return;
	}

	/*
	 * Everything past here needs the PCM clock, and starting it means
	 * killing and reprogramming a clock in the VideoCore's own clock
	 * manager.  On the board that is not ours to take: the firmware
	 * owns CPRMAN, and the first boot that got this far -- the CS
	 * assertion above used to stop before it -- hung in screeninit(),
	 * which is the next thing to ask the firmware for anything.  The
	 * register-level checks above need no clock and still run.
	 *
	 * Set i2sdeep to run the timing checks on a board where the
	 * firmware is not being asked for anything else.
	 */
	if(!i2sdeep){
		print("I2S-NOCLOCK register checks pass; the timing checks want "
			"the VideoCore's PCM clock and do not take it\n");
		return;
	}
	i2spins();
	rate = i2sconfig(48000);
	if(rate == 0){
		print("I2S-FAIL clock never started (ctl %#ux div %#ux)\n",
			cm()[Pcmctl], cm()[Pcmdiv]);
		return;
	}

	/*
	 * Static FIFO checks, with the serialiser stopped so nothing
	 * drains underneath them.
	 */
	if((r[Cs] & Txe) == 0 || (r[Cs] & Txd) == 0){
		print("I2S-FAIL TX FIFO not empty after a clear (cs %#ux)\n",
			r[Cs]);
		return;
	}
	if(r[Cs] & Rxd){
		print("I2S-FAIL RX FIFO has data after a clear (cs %#ux)\n",
			r[Cs]);
		return;
	}
	for(i = 0; i < Fifodepth; i++)
		r[Fifo] = 0x11111111 * (i & 0xf);
	if(r[Cs] & (Txe|Txd)){
		print("I2S-FAIL TX FIFO not full after %d words (cs %#ux)\n",
			Fifodepth, r[Cs]);
		return;
	}

	/* Overrun it, and confirm the block says so rather than dropping. */
	r[Fifo] = 0xdeadbeef;
	if((r[Cs] & Txerr) == 0){
		print("I2S-FAIL overrunning the TX FIFO did not raise TXERR\n");
		return;
	}

	/*
	 * Stopping the block must not lose the error.  This is the
	 * regression test for point 5 at the top of the file: written as
	 * r[Cs] &= ~(Txon|Rxon), i2sstop() reads CS with TXERR set,
	 * writes it back set, and clears it as a side effect.
	 */
	i2sstop();
	if((r[Cs] & Txerr) == 0){
		print("I2S-FAIL stopping the block cleared TXERR (cs %#ux)\n",
			r[Cs]);
		return;
	}

	/* TXERR is write-one-to-clear, and clearing it must not stop the block. */
	csack(Txerr);
	if(r[Cs] & Txerr){
		print("I2S-FAIL TXERR did not clear on write-one (cs %#ux)\n",
			r[Cs]);
		return;
	}
	if((r[Cs] & Csen) == 0){
		print("I2S-FAIL clearing TXERR also disabled the block (cs %#ux)\n",
			r[Cs]);
		return;
	}

	/*
	 * With the interrupt enabled, a fresh overrun must latch in
	 * INTSTC as well as in CS.  The FIFO is still full, so overrunning
	 * it again is all it takes.
	 */
	r[Inten] = Itxerr;
	r[Fifo] = 0xdeadbeef;
	if((r[Intstc] & Itxerr) == 0){
		print("I2S-FAIL TXERR did not latch in INTSTC (%#ux)\n",
			r[Intstc]);
		return;
	}
	r[Intstc] = Itxerr;
	if(r[Intstc] & Itxerr){
		print("I2S-FAIL INTSTC did not clear on write-one\n");
		return;
	}
	r[Inten] = 0;
	csack(Txerr);

	/*
	 * Reading the RX FIFO while it is empty is a driver bug, and the
	 * block reports it.
	 */
	i = r[Fifo];
	USED(i);
	if((r[Cs] & Rxerr) == 0){
		print("I2S-FAIL reading an empty RX FIFO did not raise RXERR\n");
		return;
	}
	csack(Rxerr);
	if(r[Cs] & (Txerr|Rxerr)){
		print("I2S-FAIL errors still set before timing (cs %#ux)\n",
			r[Cs]);
		return;
	}

	/*
	 * The dynamic check.  The TX FIFO is still full; start the
	 * serialiser and time how long it takes to empty.  At 48kHz that
	 * is 64 frames, so 1333us, and the system timer is the judge.
	 */
	/*
	 * Best of Ntimed, and the loop refills the FIFO each time.  What
	 * is being measured is how long the serialiser takes; what is
	 * observed is how long the kernel took to notice, and everything
	 * between them -- an interrupt, a preemption, a console drain --
	 * only ever makes the second larger.  The error is one-sided, so
	 * the minimum of several runs is the best estimate available
	 * from here.  1333us with a quarter's tolerance leaves 333us,
	 * and a single scheduling hiccup is bigger than that; the SMI
	 * check, which is the same measurement over a longer window,
	 * failed exactly that way before it was given this treatment.
	 */
	expect = (ulong)(((uvlong)Fifodepth * 1000000) / rate);
	elapsed = 0;
	for(k = 0; k < Ntimed; k++){
		ulong once;

		csack(Txclr);
		csack(Txerr);
		for(i = 0; i < Fifodepth; i++)
			r[Fifo] = 0x11111111 * (i & 0xf);
		t1 = systmrread();
		cswrite(csshadow | Txon);
		for(i = 0; i < Timeout; i++)
			if(r[Cs] & Txe)
				break;
		t2 = systmrread();
		/*
		 * The drain loop breaks the instant TXE sets, which is one
		 * frame before the serialiser actually underflows.  Give it
		 * that frame, so stopping has a real error to preserve.
		 */
		delay(1);
		i2sstop();
		if(i == Timeout){
			print("I2S-FAIL TX FIFO never drained (cs %#ux)\n", r[Cs]);
			return;
		}
		once = (ulong)(t2 - t1);
		if(elapsed == 0 || once < elapsed)
			elapsed = once;
	}
	err = (long)elapsed - (long)expect;
	if(err < 0)
		err = -err;
	if(expect == 0 || err > (long)(expect/4)){
		print("I2S-FAIL draining %d frames took %lud us at best of %d, "
			"expected %lud at %lud Hz\n",
			Fifodepth, elapsed, Ntimed, expect, rate);
		return;
	}

	/*
	 * The serialiser has been underflowing for a millisecond, so
	 * TXERR must be set here -- and must have survived i2sstop().
	 */
	if((r[Cs] & Txerr) == 0){
		print("I2S-FAIL underflow after the drain did not raise TXERR, "
			"or stopping cleared it (cs %#ux)\n", r[Cs]);
		return;
	}

	print("i2s: pcm at %#p, %lud Hz frames, TX drained %d in %lud us "
		"(%lud expected)\n", (void*)I2S0, rate, Fifodepth, elapsed,
		expect);

	/* And the same for reception, best of Ntimed for the same reason. */
	elapsed = 0;
	for(k = 0; k < Ntimed; k++){
		ulong once;

		csack(Txclr | Rxclr);
		csack(Txerr | Rxerr);
		t1 = systmrread();
		cswrite(csshadow | Rxon);
		for(i = 0; i < Timeout; i++)
			if(r[Cs] & Rxf)
				break;
		t2 = systmrread();
		i2sstop();
		if(i == Timeout){
			print("I2S-FAIL RX FIFO never filled (cs %#ux)\n", r[Cs]);
			return;
		}
		once = (ulong)(t2 - t1);
		if(elapsed == 0 || once < elapsed)
			elapsed = once;
	}
	err = (long)elapsed - (long)expect;
	if(err < 0)
		err = -err;
	if(err > (long)(expect/4)){
		print("I2S-FAIL filling %d frames took %lud us at best of %d, "
			"expected %lud\n", Fifodepth, elapsed, Ntimed, expect);
		return;
	}
	print("i2s: RX filled %d in %lud us\n", Fifodepth, elapsed);

	cswrite(0);
	print("I2S-OK 48kHz frames, both FIFOs, errors, and the frame rate "
		"timed against the system timer\n");
}
