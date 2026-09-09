/*
 * Broadcom RNG200 hardware random number generator, feeding
 * /dev/random on a BCM2711 (0xfe104000).
 *
 * This is not the block rngbcm.c drives.  A BCM2711 does not have the
 * BCM2835 RNG; it has an RNG200 at the same offset, with a different
 * register map, and pointing the BCM2835 driver at it is not a
 * near-miss that reads zeroes -- it is a synchronous external abort at
 * the first status read.  So this board gets its own driver, and
 * rngbcm.c stays with the board it was written for.
 *
 * The register map and the bring-up sequence come from the driver
 * Linux uses for this block, drivers/char/hw_random/iproc-rng200.c,
 * which is the published programming interface for it:
 *
 *	0x00 Ctrl	bit 0 enables the generator
 *	0x04 Rngreset	bit 0, pulsed high then low
 *	0x08 Rbgreset	bit 0, pulsed high then low
 *	0x18 Intstatus	write ones to clear; bit 31 master fail lockout,
 *			bit 5 NIST failure
 *	0x20 Data	one random word per read
 *	0x24 Count	bits 7:0, words available to read
 *
 * The block's window is 0x28 bytes, which is exactly those registers:
 * bcm2711.dtsi has rng@7e104000 with reg = <0x7e104000 0x28>, and the
 * model in tools/qemu-patches 0023 claims the same, so a read past the
 * count register is an abort here and on the part rather than a zero.
 *
 * The difference that matters to a driver, against the BCM2835 block:
 * there is a FIFO with a count, and a word must not be read unless the
 * count says one is there.  rngbcm.c polls a "words ready" field in the
 * status register for the same reason, but the BCM2835 model in QEMU
 * hands out a word on any read of the data register regardless, so a
 * driver that skipped the check would still have passed there.  The
 * RNG200 model written for this port (tools/qemu-patches 0023) does
 * not: an empty FIFO reads back zero and says so in the QEMU log, and
 * the FIFO is empty until the generator is enabled.  rng200check()
 * below turns that into a test rather than an assumption.
 *
 * The interrupt (GIC SPI 125) is not used.  The published interface
 * has status bits but no enable or mask register, so there is nothing
 * to say when the line asserts; the driver polls, as Linux's does.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

enum {
	Ctrl		= 0x00/4,
	Rngreset	= 0x04/4,
	Rbgreset	= 0x08/4,
	Intstatus	= 0x18/4,
	Data		= 0x20/4,
	Count		= 0x24/4,

	Rbgen		= 1<<0,		/* Ctrl: enable the generator */
	Resetbit	= 1<<0,		/* both reset registers */

	Countmask	= 0xff,		/* Count: bits 7:0 */

	Failmask	= 1<<31 | 1<<5,	/* master fail lockout, NIST failure */

	Spin		= 100000,	/* bounded wait for a word */
	Nproof		= 8,		/* words rng200check() reads */
};

extern void (*hwrandbuf)(void*, u32);

static u32 *rngr;
static Lock rnglk;

/*
 * The restart sequence, verbatim from the published one: disable, clear
 * every interrupt status bit, pulse both soft resets, enable.  Linux
 * runs this at probe and again whenever the block reports a failure,
 * and it is the only documented way to get the generator producing.
 */
static void
rng200restart(u32 *r)
{
	r[Ctrl] &= ~Rbgen;
	r[Intstatus] = ~0;
	r[Rbgreset] |= Resetbit;
	r[Rngreset] |= Resetbit;
	r[Rngreset] &= ~Resetbit;
	r[Rbgreset] &= ~Resetbit;
	r[Ctrl] |= Rbgen;
}

/*
 * Fill n bytes.  As in rngbcm.c a short read cannot be signalled
 * through hwrandbuf's interface, so a stall tops up from what was
 * delivered rather than handing back zeroes.  Unlike rngbcm.c this one
 * has a documented recovery: if the block reports a hard failure, the
 * restart sequence is what the interface says to do about it, once.
 */
static void
rng200buf(void *p, u32 n)
{
	uchar *a = p;
	u32 w, st;
	int i, got, restarts;

	restarts = 0;
	ilock(&rnglk);
	while(n > 0){
		st = rngr[Intstatus];
		if(st & Failmask){
			if(restarts++ > 0)
				break;
			rng200restart(rngr);
			continue;
		}
		for(i = 0; i < Spin; i++)
			if((rngr[Count] & Countmask) != 0)
				break;
		if(i >= Spin)
			break;
		w = rngr[Data];
		got = n < 4? n: 4;
		for(i = 0; i < got; i++)
			*a++ = w >> (8*i);
		n -= got;
	}
	iunlock(&rnglk);
	if(n > 0){
		static int warned;

		if(!warned){
			warned = 1;
			print("rng200: generator stalled with %ud bytes to go\n", n);
		}
		while(n-- > 0)
			*a++ ^= (uchar)(m->ticks >> (n & 7));
	}
}

/*
 * Bring the block up and prove it, in that order, with the negative
 * half first: before anything is written, the FIFO must be empty.
 * That is the half that distinguishes a model which implements the
 * documented interface from one that hands out random words on any
 * read -- reading distinct words after enabling proves neither, since
 * a block that ignored Ctrl entirely would pass it too.
 *
 * The count register is the gate because it is the documented one.
 * The data read before enabling is out of spec and reported rather
 * than gated on: a real RNG200 asked for a word it has not made may
 * do anything, so what it returns is evidence, not a verdict.
 */
void
rng200init(void)
{
	u32 pre, predata, st;
	u32 w[Nproof];
	int i, j, n;

	rngr = (u32*)RNG0;

	pre = rngr[Count] & Countmask;
	predata = rngr[Data];
	if(pre != 0){
		print("RNG-PREENABLE-FAIL %ud words in the FIFO before the "
			"generator was enabled\n", pre);
		return;
	}
	print("rng200: fifo empty before enable, data read %8.8ux "
		"(out of spec, reported not trusted)\n", predata);

	rng200restart(rngr);

	st = rngr[Intstatus];
	if(st & Failmask){
		print("RNG-FAIL int status %8.8ux after the restart sequence\n", st);
		return;
	}
	n = rngr[Count] & Countmask;
	if(n == 0){
		print("RNG-FAIL fifo still empty after the restart sequence\n");
		return;
	}

	/*
	 * Nproof words, all distinct and not all zero.  A stuck-at
	 * generator would otherwise silently replace the software
	 * fallback with a constant.
	 */
	for(i = 0; i < Nproof; i++){
		w[i] = 0;
		rng200buf(&w[i], sizeof w[i]);
	}
	for(i = 0; i < Nproof; i++)
		for(j = i+1; j < Nproof; j++)
			if(w[i] == w[j]){
				print("RNG-FAIL words %d and %d both %8.8ux\n",
					i, j, w[i]);
				return;
			}

	/*
	 * A soft reset empties the FIFO.  That is inference rather than
	 * something the published interface states, so it is printed and
	 * not gated on; it is here because a driver that resets a block
	 * should know what it did to the words in flight.
	 */
	rngr[Rngreset] |= Resetbit;
	i = rngr[Count] & Countmask;
	rngr[Rngreset] &= ~Resetbit;

	hwrandbuf = rng200buf;
	print("rng200: rng200 at %#p up, fifo %d words, %8.8ux %8.8ux, "
		"%d after reset, int status %8.8ux RNG-OK\n",
		(void*)RNG0, n, w[0], w[1], i, rngr[Intstatus]);
}
