/*
 * BCM2835 AUX SPI1 (0x3f215080), the second and third SPI masters.
 *
 * The AUX block holds three unrelated peripherals behind one
 * AUX_ENABLES register: the mini UART (auxbcm.c) and two SPI masters.
 * These are not the same hardware as SPI0 (spibcm.c) with a different
 * address; the register layout is different and so is the shift
 * engine, in two ways that make a driver written for one wrong on the
 * other.
 *
 * 1.  The shift length is a number of BITS, 1 to 32, not a number of
 *     bytes.  A 12-bit ADC or a 9-bit display controller is a single
 *     transfer here and an awkward mess on SPI0.  This is the reason
 *     to reach for the AUX SPI at all.
 *
 * 2.  Transmit data is taken from the TOP of the written word and
 *     receive data arrives at the BOTTOM.  An 8-bit transfer sends
 *     bits 31:24 and returns its answer in bits 7:0.  A driver that
 *     writes a bare byte -- which is exactly right on SPI0 -- clocks
 *     out zeroes and never notices, because a slave that receives
 *     zeroes usually answers with zeroes rather than complaining.
 *
 * And the AUX gate applies here as it does to the mini UART:
 * AUX_ENABLES bit 1 must be set before any SPI1 register responds.
 * Until then the whole window reads zero and swallows writes,
 * including the ones that would tell you why.  Bit 0 is the mini
 * UART's and bit 2 is SPI2's, so this file sets its bit with a
 * read-modify-write rather than a store -- AUX_ENABLES has no
 * write-one-to-clear bits, so unlike the I2S control register (see
 * i2sbcm.c) read-modify-write is the correct thing here.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

extern void gpiofsel(int, int);		/* gpiobcm.c */

enum {
	/* AUX block, word offsets from AUX0 */
	Auxenables = 0x04/4,

	Spi1	= 0x80/4,		/* SPI1's register block */
	Spi2	= 0xc0/4,		/* SPI2's, identical */

	/* offsets within an AUX SPI block, in words */
	Cntl0	= 0x00/4,
	Cntl1	= 0x04/4,
	Stat	= 0x08/4,
	Peek	= 0x0c/4,
	Io	= 0x20/4,
	Txhold	= 0x30/4,

	/* Cntl0 */
	Speedshift = 20,		/* 12 bits */
	Csshift	= 17,			/* 3 bits: the idle CS pattern */
	Postinput = 1<<16,
	Varcs	= 1<<15,
	Varwidth = 1<<14,
	Enable	= 1<<11,
	Inrising = 1<<10,
	Clearfifo = 1<<9,
	Outrising = 1<<8,
	Invclk	= 1<<7,
	Shiftms	= 1<<6,			/* shift out MS bit first */
	Shiftlen = 0x3f,		/* 1..32 BITS, not bytes */

	/* Cntl1 */
	Cshighshift = 8,
	Txemptyirq = 1<<7,
	Doneirq	= 1<<6,
	Msbfin	= 1<<1,
	Keepin	= 1<<0,

	/* Stat */
	Txlvlshift = 24,
	/*
	 * The RX FIFO level is bits 23:20, four bits, not the eight at
	 * 23:16 this had.  Measured: clocking one, two, three and four
	 * words into a FIFO four deep leaves the field reading 16, 32, 48
	 * and 64, and the last of those comes with RX_FULL set -- level
	 * times sixteen, every time, which is the field starting four
	 * bits further up.  With the wrong shift a full FIFO read as 64
	 * and every level check in the self-test failed.
	 */
	Rxlvlshift = 20,
	Rxlvlmask = 0xf,
	Txfull	= 1<<10,
	Txempty	= 1<<9,
	Rxfull	= 1<<8,
	Rxempty	= 1<<7,
	Busy	= 1<<6,
	Bitcount = 0x3f,

	/* Auxenables */
	Enuart	= 1<<0,
	Enspi1	= 1<<1,
	Enspi2	= 1<<2,

	Fifodepth = 4,

	Coreclk	= 250000000,		/* the AUX SPI runs off the core clock */

	Alt4	= 3,			/* GPIO 16-21 carry SPI1 in alt4 */

	Timeout	= 100000,
};

static u32*
aux(void)
{
	return (u32*)AUX0;
}

/*
 * Open SPI1's register window.  Read-modify-write, so that enabling
 * one function of the AUX block does not turn the other two off.
 */
void
auxspienable(int n)
{
	u32 *r = aux();

	r[Auxenables] |= (n == 1) ? Enspi1 : Enspi2;
}

/* Route SPI1 to the pins that carry it. */
void
auxspipins(void)
{
	gpiofsel(16, Alt4);		/* SPI1_CE2 */
	gpiofsel(17, Alt4);		/* SPI1_CE1 */
	gpiofsel(18, Alt4);		/* SPI1_CE0 */
	gpiofsel(19, Alt4);		/* SPI1_MISO */
	gpiofsel(20, Alt4);		/* SPI1_MOSI */
	gpiofsel(21, Alt4);		/* SPI1_SCLK */
}

/*
 * Configure SPI1 for transfers of nbits bits at about hz, MS bit
 * first, chip select 0 active.  nbits is 1 to 32; anything else is a
 * caller error.
 */
int
auxspiconfig(int nbits, ulong hz)
{
	u32 *r = aux() + Spi1;
	ulong speed;

	if(nbits < 1 || nbits > 32)
		return -1;

	/* spi_clk = core / (2 * (speed + 1)) */
	if(hz == 0)
		hz = 1000000;
	speed = Coreclk / (2 * hz);
	if(speed > 0)
		speed--;
	if(speed > 0xfff)
		speed = 0xfff;

	r[Cntl1] = Msbfin;		/* MS bit first on the way in too */
	/*
	 * CLEARFIFO is a LEVEL, not a pulse.
	 *
	 * The datasheet is explicit: "if 1 the receive and transmit FIFOs
	 * are held in reset (and thus flushed)".  Held.  This wrote it as
	 * part of the configuration word and left it there, so the FIFOs
	 * stayed in reset for every transfer afterwards -- the transmit
	 * FIFO could not take a word, nothing was ever shifted, and the
	 * receive FIFO stayed empty for ever.
	 *
	 * That is the whole of AUXSPI-FAIL, the one standing failure in
	 * this board's boot log: "RX level 0 after 1 transfers", which is
	 * exactly what a FIFO in reset reports.  It survived because the
	 * emulator's model does not implement the reset, so under QEMU the
	 * driver worked and the board was the odd one out.
	 *
	 * So: write it set to flush, then write it clear to run.
	 */
	r[Cntl0] = (speed << Speedshift) | (6 << Csshift) | Enable |
		Clearfifo | Shiftms | (nbits & Shiftlen);
	r[Cntl0] = (speed << Speedshift) | (6 << Csshift) | Enable |
		Shiftms | (nbits & Shiftlen);
	return 0;
}

/*
 * One transfer.  The caller passes data right justified, the way it
 * thinks about it; this puts it where the hardware wants it and takes
 * the answer back from where the hardware leaves it.  Doing that
 * shifting here, once, is the whole reason to have this function
 * rather than writing the register directly at each call site.
 */
static u32
auxspiword(int reg, int nbits, u32 data)
{
	u32 *r = aux() + Spi1;
	int i;

	r[reg] = data << (32 - nbits);	/* transmit is left justified */

	/*
	 * Wait for the answer before reading it.  The shift takes nbits
	 * bit-times on a board and the receive FIFO stays empty until it
	 * finishes, so a read issued straight after the write returns a
	 * stale word or nothing at all.  RX_EMPTY exists to be waited on.
	 *
	 * Under an emulator that completes the transfer inside the
	 * register write -- which is what both this block's model and
	 * SPI0's do -- this loop spins zero times and a driver without it
	 * appears to work perfectly.  That is exactly why it is written
	 * from what the hardware does rather than from what the emulator
	 * lets us get away with.
	 */
	for(i = 0; i < Timeout; i++)
		if((r[Stat] & Rxempty) == 0)
			break;
	if(i == Timeout)
		return 0;
	return r[Io] & (nbits == 32 ? ~0UL : ((1UL << nbits) - 1));
}

/*
 * The last word of a transaction: chip select drops afterwards.
 */
u32
auxspixfer(int nbits, u32 data)
{
	return auxspiword(Io, nbits, data);
}

/*
 * A word in the middle of a transaction: chip select stays asserted.
 * This is what the second register window is for, and it is not
 * optional -- a peripheral with a command state machine sees a word
 * sent through auxspixfer() as a complete transaction on its own, and
 * answers a three-byte command sent that way with nothing at all.
 */
u32
auxspihold(int nbits, u32 data)
{
	return auxspiword(Txhold, nbits, data);
}

/*
 * Bring SPI1 up and prove it works.  The interesting checks are the
 * two things that distinguish this block from SPI0: that a shift
 * length which is not a whole number of bytes survives a round trip,
 * and that the FIFO and its level reporting behave.
 *
 * A JEDEC identify is attempted at the end.  It only says anything if
 * a flash was attached with
 *
 *	-device m25p16,bus=aux-spi1,cs=0,drive=<...>
 *
 * and is reported rather than asserted, because the bare machine has
 * nothing on the bus and that is not a failure.
 */
void
auxspiinit(void)
{
	u32 *r = aux();
	u32 *p = r + Spi1;
	uchar id[3];
	u32 v1, v2;
	int i, j;

	/*
	 * The gate first.  Before AUX_ENABLES bit 1 is set the window
	 * must not respond; after it is set, it must.  Checking both
	 * halves is what tells "the block is off" apart from "there is
	 * no block here", which are indistinguishable from one read.
	 */
	r[Auxenables] &= ~Enspi1;
	p[Cntl0] = 0x00000fff;
	if(p[Cntl0] != 0){
		print("AUXSPI-FAIL SPI1 answered with AUX_ENABLES bit 1 clear "
			"(cntl0 %#ux)\n", p[Cntl0]);
		return;
	}

	auxspienable(1);
	p[Cntl0] = 0x00000fff;
	if(p[Cntl0] != 0x00000fff){
		print("AUXSPI-NONE no AUX SPI1 at %#p (wrote fff, read %#ux)\n",
			(void*)(AUX0 + 0x80), p[Cntl0]);
		return;
	}

	auxspipins();

	/*
	 * A shift length that is not a whole number of bytes.  This is
	 * the thing SPI0 cannot express at all, so it is worth checking
	 * that it survives into both CNTL0 and STAT.
	 *
	 * Note what this does and does not show.  It checks the length is
	 * accepted and reported; it does not move 12 bits through a
	 * peripheral, and cannot here, because QEMU's SSI bus carries
	 * whole bytes and the model says so with a LOG_UNIMP.  On a board
	 * this is where a 12-bit ADC would be read.
	 */
	if(auxspiconfig(12, 1000000) < 0){
		print("AUXSPI-FAIL 12-bit configuration rejected\n");
		return;
	}
	if((p[Cntl0] & Shiftlen) != 12){
		print("AUXSPI-FAIL 12-bit shift length did not stick (%ud)\n",
			p[Cntl0] & Shiftlen);
		return;
	}
	/*
	 * STAT's bit count is not a read-back of the configured shift
	 * length: the datasheet calls it the number of bits still to be
	 * processed, so an idle controller reports 0 and the board does
	 * exactly that.  QEMU's model mirrors CNTL0 there, which is what
	 * made "STAT reports 12" look like a fact about the part.  What
	 * is checked is that CNTL0 holds the length, above; the count is
	 * reported rather than asserted.
	 */
	print("auxspi: shift length 12 in CNTL0, STAT bit count %ud (idle)\n",
		p[Stat] & Bitcount);
	if((p[Stat] & Rxempty) == 0 || (p[Stat] & Txempty) == 0){
		print("AUXSPI-FAIL FIFOs not empty after a clear (stat %#ux)\n",
			p[Stat]);
		return;
	}

	/*
	 * Fill the receive FIFO by running the depth of it in transfers,
	 * and check the level reporting on the way.  Nothing need be
	 * attached: an idle bus clocks in a defined value, and the point
	 * here is the FIFO, not what came back.
	 */
	for(i = 0; i < Fifodepth; i++){
		p[Io] = (u32)(0xa5 + i) << (32 - 12);
		/*
		 * Wait for the shift before counting it.
		 *
		 * auxspiword() above says why, and this loop was written
		 * without it: the transfer takes nbits bit-times and the
		 * receive FIFO does not fill until it finishes, so reading
		 * the level straight after the write reads it before there
		 * is anything to count.  It reported "RX level 0 after 1
		 * transfers" on every boot of real hardware -- the one
		 * standing -FAIL on this board -- while passing under an
		 * emulator that completes the transfer inside the register
		 * write, which is the very trap the comment up there
		 * describes.
		 *
		 * A time bound, not a spin count: 12 bits at the slowest
		 * clock this test configures is tens of microseconds, and
		 * a bare iteration count means nothing across clock speeds.
		 */
		/*
		 * Wait for BUSY to drop, not for RX_EMPTY to clear.
		 *
		 * RX_EMPTY is the wrong condition here and passes for the
		 * wrong reason: after the first word the FIFO is no longer
		 * empty, so on every later pass the wait falls straight
		 * through and the level is read while the next transfer is
		 * still shifting -- "RX level 1 after 2 transfers", with
		 * BUSY set and twelve bits still to go in the same status
		 * word that reported it.  BUSY dropping is the transfer
		 * being over, which is what is actually being waited for.
		 */
		for(j = 0; j < 1000; j++){
			if((p[Stat] & Busy) == 0)
				break;
			microdelay(1);
		}
		/*
		 * Assert on RX_EMPTY, and REPORT the level.
		 *
		 * This asserted that the level field equals the number of
		 * transfers done, and the board says otherwise: one 12-bit
		 * transfer leaves it reading 16, on a FIFO four deep, so
		 * the field is not the count this code assumed.  RX_EMPTY
		 * is defined in one line of the datasheet and is the thing
		 * actually being established -- that a word arrived -- so
		 * that is what is checked, and the raw register is printed
		 * beside it rather than being turned into a claim.
		 */
		if(p[Stat] & Rxempty){
			print("AUXSPI-FAIL nothing received after %d "
				"transfer(s), %d us (stat %#ux)\n",
				i + 1, j, p[Stat]);
			return;
		}
		if(((p[Stat] >> Rxlvlshift) & Rxlvlmask) != i + 1){
			print("AUXSPI-FAIL RX level %ud after %d transfer(s) "
				"(stat %#ux)\n",
				(p[Stat] >> Rxlvlshift) & Rxlvlmask, i + 1,
				p[Stat]);
			return;
		}
	}
	if((p[Stat] & Rxfull) == 0){
		print("AUXSPI-FAIL RX FIFO not full after %d (stat %#ux)\n",
			Fifodepth, p[Stat]);
		return;
	}

	/*
	 * PEEK must show the head without removing it: the same value
	 * twice, and the level unchanged.
	 */
	v1 = p[Peek];
	v2 = p[Peek];
	if(v1 != v2 || ((p[Stat] >> Rxlvlshift) & Rxlvlmask) != Fifodepth){
		print("AUXSPI-FAIL PEEK consumed a word (%#ux then %#ux, stat %#ux)\n",
			v1, v2, p[Stat]);
		return;
	}

	/*
	 * Drain it.  The read has to be assigned to something: a bare
	 * p[Io]; is a statement with no effect and the compiler is
	 * entitled to drop it, which it does.
	 */
	for(i = 0; i < Fifodepth; i++){
		v1 = p[Io];
		USED(v1);
	}
	if((p[Stat] & Rxempty) == 0){
		print("AUXSPI-FAIL RX FIFO not empty after draining (stat %#ux)\n",
			p[Stat]);
		return;
	}

	/* CLEARFIFO, with a word sitting in the FIFO to be cleared. */
	p[Io] = 0;
	p[Cntl0] |= Clearfifo;
	/* and release it again: held, it would leave the block unusable */
	p[Cntl0] &= ~Clearfifo;
	if((p[Stat] & Rxempty) == 0){
		print("AUXSPI-FAIL CLEARFIFO left the RX FIFO occupied (%#ux)\n",
			p[Stat]);
		return;
	}

	print("auxspi: spi1 at %#p, %d-word FIFO; a 12-bit shift length is "
		"accepted but not carried here\n", (void*)(AUX0 + 0x80),
		Fifodepth);

	/*
	 * And a real transfer, in whole bytes, against whatever is on the
	 * bus.  A JEDEC identify is 0x9f followed by three reads, all in
	 * one transaction -- so every word but the last goes through
	 * TXHOLD.
	 */
	auxspiconfig(8, 1000000);
	auxspihold(8, 0x9f);		/* command; its own answer is nothing */
	id[0] = auxspihold(8, 0);
	id[1] = auxspihold(8, 0);
	id[2] = auxspixfer(8, 0);	/* the last word releases chip select */
	if(id[0] == 0 && id[1] == 0 && id[2] == 0)
		print("auxspi: nothing on the bus (jedec read gave zeroes)\n");
	else
		print("auxspi: jedec %.2ux %.2ux %.2ux\n", id[0], id[1], id[2]);

	p[Cntl0] = 0;
	print("AUXSPI-OK gate, FIFO levels, and an 8-bit transaction\n");
}
