/*
 * BCM2835 SPI/BSC slave (0x3f214000): the one peripheral on this SoC
 * that makes the Pi the *slave* rather than the master.  Some other
 * chip on the I2C bus addresses it, and the Pi answers -- which is how
 * you make a Pi look like a peripheral to a microcontroller, and how
 * the VideoCore boots a host over I2C.
 *
 * There is a second master on this board: the Pi's own.  BSC0
 * (i2cbcm.c) is on the same wires, so this file drives both ends of a
 * transfer, which is the only way to exercise a slave without a second
 * chip.  On a real board that is a jumper between GPIO 0/1 and 18/19;
 * here it is the arrangement the emulator is wired in.
 *
 * FOUR THINGS TO GET RIGHT, three of them peculiar to this block.
 *
 * 1.  RSR's two error bits are cleared by writing ZERO to them.  Every
 *     other error bit on this SoC -- the PWM's, the I2S's, the SMI's,
 *     the AUX SPI's -- is write-one-to-clear, and a driver that
 *     reaches for the usual idiom here leaves the error set forever
 *     while believing it cleared it.  The datasheet is explicit; this
 *     file checks it both ways round.
 *
 * 2.  The slave address is programmable at run time through SLV, and
 *     the block does not answer at all until CR's EN and I2C bits are
 *     both set.  A master addressing a disabled slave sees no device,
 *     not a device that refuses -- which is the difference between
 *     "nothing is plugged in" and "it is plugged in and broken".
 *
 * 3.  Transmission and reception are separately enabled, by CR's TXE
 *     and RXE.  A slave with RXE clear NAKs a write rather than
 *     dropping it, so a master finds out.
 *
 * 4.  DR carries the FIFO levels, the busy flags and both error bits
 *     alongside the data byte, so one read is enough to drive a
 *     receive loop.  FR reports the same flags in different bit
 *     positions -- which is a fine trap if you use the wrong set.
 *
 * Register layout and bit meanings are from the BCM2835 ARM
 * Peripherals datasheet section 11.  Linux has no driver for this
 * block, upstream or in the Raspberry Pi tree.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"

extern int bcmi2cwrite(u32*, int, uchar*, int);	/* i2cbcm.c */
extern int bcmi2cread(u32*, int, uchar*, int);

enum {
	/* slave registers, word offsets */
	Dr	= 0x00/4,
	Rsr	= 0x04/4,
	Slv	= 0x08/4,
	Cr	= 0x0c/4,
	Fr	= 0x10/4,
	Ifls	= 0x14/4,
	Imsc	= 0x18/4,
	Ris	= 0x1c/4,
	Mis	= 0x20/4,
	Icr	= 0x24/4,

	/* Cr */
	Cen	= 1<<0,		/* enable the device */
	Cspi	= 1<<1,
	Ci2c	= 1<<2,
	Cbrk	= 1<<7,		/* stop and clear both FIFOs */
	Ctxe	= 1<<8,		/* transmit enable */
	Crxe	= 1<<9,		/* receive enable */

	/* Fr */
	Ftxbusy	= 1<<0,
	Frxfe	= 1<<1,		/* RX FIFO empty */
	Ftxff	= 1<<2,		/* TX FIFO full */
	Frxff	= 1<<3,		/* RX FIFO full */
	Ftxfe	= 1<<4,		/* TX FIFO empty */
	Frxbusy	= 1<<5,
	Ftxlvlshift = 6,
	Frxlvlshift = 11,
	Flvlmask = 0x1f,

	/* Dr: the same flags, in different places */
	Drxfe	= 1<<17,
	Drxff	= 1<<19,
	Dtxfe	= 1<<20,
	Doe	= 1<<8,
	Due	= 1<<9,
	Ddata	= 0xff,

	/* Rsr: cleared by writing ZERO */
	Roe	= 1<<0,		/* RX overrun */
	Rue	= 1<<1,		/* TX underrun */

	Slvaddr	= 0x30,		/* our address; clear of the DS1338 at 0x68 */

	Maxfifo	= 64,		/* upper bound for the depth probe */
};

static u32*
bsc(void)
{
	return (u32*)BSCSL;
}

static u32*
mst(void)
{
	return (u32*)I2C0;
}

/*
 * Bring the slave up at addr, receiving and transmitting, and clear
 * both FIFOs.  Returns with the block answering on the bus.
 */
void
bscslenable(int addr)
{
	u32 *r = bsc();

	r[Cr] = 0;			/* off while reconfiguring */
	r[Slv] = addr & 0x7f;
	r[Cr] = Cen | Ci2c | Ctxe | Crxe | Cbrk;
	r[Cr] = Cen | Ci2c | Ctxe | Crxe;
	r[Rsr] = 0;			/* clear errors: zero, not one */
}

void
bscsloff(void)
{
	bsc()[Cr] = 0;
}

/*
 * Bring the block up and prove it, from both ends.
 *
 * Every check here goes through QEMU's own BSC master model rather
 * than through anything in this series, so a byte that arrives has
 * been through code this port did not write.  That is worth more than
 * the register-level checks around it.
 */
void
bscslinit(void)
{
	u32 *r = bsc();
	u32 *m = mst();
	uchar out[8], in[8];
	u32 v;
	int i, depth;

	/*
	 * Is the block there?  SLV is plain storage, so a value that
	 * does not read back means nothing is mapped here.
	 */
	r[Slv] = 0x55;
	if((r[Slv] & 0x7f) != 0x55){
		print("BSCSL-NONE no BSC slave at %#p\n", (void*)BSCSL);
		return;
	}

	/*
	 * A disabled slave must not answer at all.  Check that before
	 * enabling it, so a later success cannot be confused with a
	 * block that answers regardless of its enable bit.
	 */
	r[Cr] = 0;
	r[Slv] = Slvaddr;
	out[0] = 0x5a;
	if(bcmi2cwrite(m, Slvaddr, out, 1) == 0){
		print("BSCSL-FAIL a disabled slave acknowledged its address\n");
		return;
	}

	bscslenable(Slvaddr);
	if((r[Fr] & Ftxfe) == 0 || (r[Fr] & Frxfe) == 0){
		print("BSCSL-FAIL FIFOs not empty after a break (fr %#ux)\n",
			r[Fr]);
		return;
	}

	/*
	 * Master to slave.  The Pi's own BSC0 writes; the bytes must
	 * turn up in this block's receive FIFO, in order.
	 */
	for(i = 0; i < 4; i++)
		out[i] = 0xa0 + i;
	if(bcmi2cwrite(m, Slvaddr, out, 4) < 0){
		print("BSCSL-FAIL the slave did not acknowledge its address\n");
		return;
	}
	if(((r[Fr] >> Frxlvlshift) & Flvlmask) != 4){
		print("BSCSL-FAIL RX level is %ud after a 4-byte write (fr %#ux)\n",
			(r[Fr] >> Frxlvlshift) & Flvlmask, r[Fr]);
		return;
	}
	for(i = 0; i < 4; i++){
		v = r[Dr];
		if((v & Ddata) != out[i]){
			print("BSCSL-FAIL byte %d arrived as %#ux, sent %#ux\n",
				i, v & Ddata, out[i]);
			return;
		}
	}
	if((r[Fr] & Frxfe) == 0){
		print("BSCSL-FAIL RX FIFO not empty after draining (fr %#ux)\n",
			r[Fr]);
		return;
	}

	/*
	 * Slave to master.  Fill this block's transmit FIFO, then have
	 * BSC0 read it back.
	 */
	for(i = 0; i < 4; i++)
		r[Dr] = 0x50 + i;
	if(((r[Fr] >> Ftxlvlshift) & Flvlmask) != 4){
		print("BSCSL-FAIL TX level is %ud after 4 writes (fr %#ux)\n",
			(r[Fr] >> Ftxlvlshift) & Flvlmask, r[Fr]);
		return;
	}
	if(bcmi2cread(m, Slvaddr, in, 4) < 0){
		print("BSCSL-FAIL the slave did not acknowledge a read\n");
		return;
	}
	for(i = 0; i < 4; i++)
		if(in[i] != 0x50 + i){
			print("BSCSL-FAIL master read byte %d as %#ux, "
				"expected %#ux\n", i, in[i], 0x50 + i);
			return;
		}

	/*
	 * Underrun: the master reads with nothing in the transmit FIFO.
	 * That is a real condition on a bus -- the master cannot know --
	 * and the block records it.
	 */
	if(r[Rsr] & Rue){
		print("BSCSL-FAIL UE already set before underrunning\n");
		return;
	}
	bcmi2cread(m, Slvaddr, in, 1);
	if((r[Rsr] & Rue) == 0){
		print("BSCSL-FAIL an empty TX FIFO read did not set UE "
			"(rsr %#ux)\n", r[Rsr]);
		return;
	}

	/*
	 * And the clearing rule, both ways round.  Writing the bit back
	 * -- the idiom every other block on this SoC wants -- must NOT
	 * clear it; writing zero must.
	 */
	r[Rsr] = Rue;
	if((r[Rsr] & Rue) == 0){
		print("BSCSL-FAIL write-one cleared UE; this register is "
			"write-zero-to-clear\n");
		return;
	}
	r[Rsr] = 0;
	if(r[Rsr] & Rue){
		print("BSCSL-FAIL writing zero did not clear UE (rsr %#ux)\n",
			r[Rsr]);
		return;
	}

	/*
	 * Measure the receive FIFO depth by overrunning it from the
	 * master, rather than assuming a number the datasheet does not
	 * give.  The overrun sets OE, which is the other error path.
	 */
	r[Cr] = Cen | Ci2c | Ctxe | Crxe | Cbrk;
	r[Cr] = Cen | Ci2c | Ctxe | Crxe;
	r[Rsr] = 0;
	for(i = 0; i < Maxfifo; i++)
		out[0] = 0;
	for(depth = 0; depth < Maxfifo; depth++){
		uchar b = depth;
		if(bcmi2cwrite(m, Slvaddr, &b, 1) < 0)
			break;
		if(r[Fr] & Frxff)
			break;
	}
	depth = (r[Fr] >> Frxlvlshift) & Flvlmask;
	if(depth == 0){
		print("BSCSL-FAIL RX FIFO depth probe found nothing (fr %#ux)\n",
			r[Fr]);
		return;
	}
	{
		uchar b = 0xff;
		bcmi2cwrite(m, Slvaddr, &b, 1);	/* one too many */
	}
	if((r[Rsr] & Roe) == 0){
		print("BSCSL-FAIL overrunning the RX FIFO did not set OE "
			"(rsr %#ux fr %#ux)\n", r[Rsr], r[Fr]);
		return;
	}
	r[Rsr] = 0;

	/* Put it back. */
	r[Cr] = Cen | Ci2c | Ctxe | Crxe | Cbrk;
	bscsloff();

	print("bscsl: bsc slave at %#p, address %#ux, RX FIFO %d deep\n",
		(void*)BSCSL, Slvaddr, depth);
	print("BSCSL-OK addressed by the Pi's own master, both directions, "
		"and both error paths\n");
}
