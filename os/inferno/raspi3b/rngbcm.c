/*
 * BCM2835 hardware random number generator (0x3f104000) feeding
 * /dev/random.  Without it this board's entropy is randomvirtarm64.c's
 * tick-seeded LCG, which its own comment calls smoke/dev only: a
 * deterministic sequence off a boot-time seed is not entropy, and
 * anything on this machine that wants unpredictable bytes -- keyring,
 * TLS nonces -- is only as good as what feeds it.
 *
 * The block is trivial: enable it, let it warm up, and read whole words
 * out of RNG_DATA whenever RNG_STATUS's top byte says a word is ready.
 * ../port/random.c and randomvirtarm64.c both prefer hwrandbuf when a
 * board sets it, so wiring this in is a single assignment.
 *
 * QEMU models this block (hw/misc/bcm2835_rng.c), so the register
 * sequence and the byte path are exercised under emulation -- but an
 * emulator's "randomness" is its host PRNG, so a passing test here says
 * the plumbing is right, not that the entropy is good.  That judgement
 * belongs to the real silicon.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

enum {
	Ctrl	= 0x00/4,
	Status	= 0x04/4,
	Data	= 0x08/4,
	Intmask	= 0x10/4,

	Rbgen	= 1<<0,		/* Ctrl: enable the generator */
	Intoff	= 1<<0,		/* Intmask: no interrupt, we poll */

	Warmup	= 0x40000,	/* discard this many clocks before trusting it */
	Availsh	= 24,		/* Status bits 31:24: words ready to read */

	Spin	= 100000,	/* bounded wait for a word */
};

extern void (*hwrandbuf)(void*, u32);

static u32 *rngr;
static Lock rnglk;

static u32*
rng(void)
{
	return (u32*)RNG0;
}

/*
 * Fill n bytes.  A short read cannot be signalled through hwrandbuf's
 * interface, so if the generator stops producing we top up from what it
 * did give us rather than hand back zeroes: returning a buffer of
 * zeroes to something asking for randomness is worse than useless.
 * The caller of last resort is randomread(), whose LCG fallback covers
 * the case where rnginit() never ran at all.
 */
static void
rngbuf(void *p, u32 n)
{
	uchar *a = p;
	u32 w;
	int i, got;

	ilock(&rnglk);
	while(n > 0){
		for(i = 0; i < Spin; i++)
			if((rngr[Status] >> Availsh) != 0)
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
		/*
		 * The generator went quiet mid-fill.  Stir what is left from
		 * the words already delivered rather than leaving it zero,
		 * and say so once -- a silent degradation here is exactly the
		 * kind of thing that should not pass unremarked.
		 */
		static int warned;

		if(!warned){
			warned = 1;
			print("rng: generator stalled with %ud bytes to go\n", n);
		}
		while(n-- > 0)
			*a++ ^= (uchar)(m->ticks >> (n & 7));
	}
}

void
rnginit(void)
{
	u32 a, b;

	rngr = rng();
	rngr[Status] = Warmup;
	rngr[Intmask] |= Intoff;
	rngr[Ctrl] |= Rbgen;

	/*
	 * Prove it produces before claiming it: two words that are not
	 * equal and not both zero.  A stuck-at generator would otherwise
	 * silently replace the LCG with a constant.
	 */
	a = 0;
	b = 0;
	rngbuf(&a, sizeof a);
	rngbuf(&b, sizeof b);
	if((a == 0 && b == 0) || a == b){
		print("RNG-FAIL %8.8ux %8.8ux (leaving the software fallback)\n", a, b);
		return;
	}
	hwrandbuf = rngbuf;
	print("rng: bcm2835 hwrng at %#p up (%8.8ux %8.8ux) RNG-OK\n", (void*)RNG0, a, b);
}
