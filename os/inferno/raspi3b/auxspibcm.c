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
	Rxlvlshift = 16,
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
	r[Cntl0] = (speed << Speedshift) | (6 << Csshift) | Enable |
		Clearfifo | Shiftms | (nbits & Shiftlen);
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

	r[reg] = data << (32 - nbits);	/* transmit is left justified */
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
	int i;

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
	 * the thing SPI0 cannot express at all, so it is the thing worth
	 * checking survives.
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
	if((p[Stat] & Bitcount) != 12){
		print("AUXSPI-FAIL STAT reports %ud bits, CNTL0 holds 12\n",
			p[Stat] & Bitcount);
		return;
	}
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
		if(((p[Stat] >> Rxlvlshift) & 0xff) != i + 1){
			print("AUXSPI-FAIL RX level %ud after %d transfers\n",
				(p[Stat] >> Rxlvlshift) & 0xff, i + 1);
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
	if(v1 != v2 || ((p[Stat] >> Rxlvlshift) & 0xff) != Fifodepth){
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
	if((p[Stat] & Rxempty) == 0){
		print("AUXSPI-FAIL CLEARFIFO left the RX FIFO occupied (%#ux)\n",
			p[Stat]);
		return;
	}

	print("auxspi: spi1 at %#p, 12-bit shifts, %d-word FIFO\n",
		(void*)(AUX0 + 0x80), Fifodepth);

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
	print("AUXSPI-OK gate, 12-bit shift length, FIFO levels and a transfer\n");
}
