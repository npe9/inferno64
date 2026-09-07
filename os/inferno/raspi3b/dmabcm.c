/*
 * BCM2835 DMA (0x3f007000): sixteen channels driven by control blocks
 * in memory rather than by registers.  This is how the SoC moves bulk
 * data without the CPU -- the SD controller, the PWM and PCM
 * serialisers and the framebuffer all use it on a real Pi.
 *
 * THREE THINGS THAT MAKE THIS DIFFERENT FROM A REGISTER-POKING DRIVER.
 *
 * 1.  The engine reads its instructions from memory.  A control block
 *     is 32 bytes -- transfer info, source, destination, length,
 *     stride, and the address of the next block or zero to stop -- and
 *     the driver hands the engine an address, not a command.  Chaining
 *     via NEXTCONBK is the point of the design: a whole scatter-gather
 *     list runs without the CPU waking up once.
 *
 * 2.  Every address in a control block, and the address of the block
 *     itself, is a *bus* address, not an ARM physical address.  The
 *     engine is a bus master and sees RAM through the 0xC0000000
 *     uncached alias, exactly as the VideoCore and the USB core do
 *     (mailbox.c, usbdwc.c).  Handing it an ARM address gets a
 *     transfer that either does nothing or corrupts something a
 *     gigabyte away.
 *
 * 3.  The control block must be 32-byte aligned, and both it and the
 *     data have to be visible to a bus master that is not reading
 *     through the CPU's caches.  So the block is aligned here, and
 *     everything the engine will read is flushed before it starts and
 *     everything it wrote is invalidated before the CPU looks -- which
 *     is why this file uses cachebcm.c rather than assuming coherency.
 *     The emulator is coherent and would forgive all of it; the board
 *     would not.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

enum {
	Chansize	= 0x100,	/* per-channel register block */

	/* per-channel registers, word offsets */
	Cs		= 0x00/4,
	Conblkad	= 0x04/4,
	Ti		= 0x08/4,
	Sourcead	= 0x0c/4,
	Destad		= 0x10/4,
	Txfrlen		= 0x14/4,
	Stride		= 0x18/4,
	Nextconbk	= 0x1c/4,
	Debug		= 0x20/4,

	/* Cs */
	Active		= 1<<0,
	Endflag		= 1<<1,
	Interrupt	= 1<<2,
	Ispaused	= 1<<4,
	Isheld		= 1<<5,
	Error		= 1<<8,
	Abort		= 1<<30,
	Reset		= 1<<31,

	/* Ti, the transfer-info word of a control block */
	Inten		= 1<<0,
	Tdmode		= 1<<1,
	Waitresp	= 1<<3,
	Dinc		= 1<<4,
	Dwidth128	= 1<<5,
	Ddreq		= 1<<6,
	Sinc		= 1<<8,
	Swidth128	= 1<<9,
	Sdreq		= 1<<10,

	Enablereg	= 0xff0/4,	/* global per-channel enable bits */

	Busalias	= 0xC0000000,	/* bus-master view of ARM RAM */

	Timeout		= 1000000,
};

/*
 * A control block, in the layout the engine reads.  Nothing here may
 * be reordered: this is a hardware structure, not a convenience.
 */
typedef struct Cb Cb;
struct Cb {
	u32	ti;
	u32	source;
	u32	dest;
	u32	len;
	u32	stride;
	u32	next;
	u32	pad[2];			/* to a full 32 bytes */
};

static u32*
dmachan(int c)
{
	return (u32*)(DMA0 + c*Chansize);
}

static u32
busaddr(void *a)
{
	return (u32)((uintptr)a | Busalias);
}

/*
 * Copy len bytes with channel c.  The caller owns cb, which must be
 * 32-byte aligned and must not be freed until this returns.  Returns 0,
 * or -1 if the engine reported an error or never finished.
 */
int
dmacopy(int c, Cb *cb, void *dst, void *src, ulong len)
{
	u32 *r = dmachan(c);
	u32 *g = (u32*)DMA0;
	int i;

	if(((uintptr)cb & 31) != 0)
		return -1;

	cb->ti = Sinc | Dinc | Waitresp;
	cb->source = busaddr(src);
	cb->dest = busaddr(dst);
	cb->len = len;
	cb->stride = 0;
	cb->next = 0;

	/*
	 * Everything the engine is about to read must be in memory, not
	 * sitting in a dirty cache line: the control block, and the
	 * source data.  And the destination has to be cleaned too, so a
	 * later writeback of a stale dirty line cannot land on top of
	 * what the engine put there.
	 */
	cacheflush(cb, sizeof *cb);
	cacheflush(src, len);
	cacheflush(dst, len);

	g[Enablereg] |= 1 << c;			/* the channel must be enabled */
	r[Cs] = Reset;
	for(i = 0; i < Timeout; i++)
		if((r[Cs] & Reset) == 0)
			break;
	if(i == Timeout)
		return -1;

	r[Cs] = Endflag | Interrupt | Error;	/* clear stale status, w1c */
	r[Conblkad] = busaddr(cb);
	r[Cs] = Active;

	for(i = 0; i < Timeout; i++){
		if(r[Cs] & Error)
			return -1;
		if((r[Cs] & Active) == 0)
			break;
	}
	if(i == Timeout)
		return -1;
	if(r[Cs] & Error)
		return -1;

	/* The engine wrote dst behind the CPU's back. */
	cacheinval(dst, len);
	return 0;
}

/*
 * Prove the engine runs a control block, and prove it moved the data
 * rather than merely reporting that it had.
 *
 * Channel 0 is used because it always exists; the higher channels are
 * "lite" on this SoC and cannot do everything.  The buffers are
 * deliberately given a recognisable pattern with a distinct
 * destination fill, so a transfer that silently does nothing shows up
 * as the fill rather than as a plausible-looking zero.
 */
void
dmainit(void)
{
	static uchar raw[sizeof(Cb) + 32];
	static uchar src[256], dst[256];
	Cb *cb;
	int i;

	cb = (Cb*)(((uintptr)raw + 31) & ~(uintptr)31);

	for(i = 0; i < sizeof src; i++){
		src[i] = 0x40 + (i & 0x3f);
		dst[i] = 0xa5;			/* not zero, and not the source */
	}

	if(dmacopy(0, cb, dst, src, sizeof src) < 0){
		print("DMA-NONE channel 0 at %#p did not run a control block\n",
			(void*)DMA0);
		return;
	}
	for(i = 0; i < sizeof src; i++)
		if(dst[i] != src[i]){
			print("DMA-FAIL byte %d is %#2.2ux, expected %#2.2ux\n",
				i, dst[i], src[i]);
			return;
		}
	print("dma: channel 0 at %#p copied %d bytes by control block\n",
		(void*)DMA0, (int)sizeof src);
	print("DMA-OK control block fetched, transfer completed and verified\n");
}
