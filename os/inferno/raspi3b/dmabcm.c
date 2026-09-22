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

extern int mboxgetdmachans(u32*);	/* mailbox.c: channels the ARM may use */

enum {
	Chansize	= 0x100,	/* per-channel register block */
	Nlite		= 7,		/* channels 7 and up are cut-down */

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
	Permapshift	= 16,		/* which peripheral paces the transfer */

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
 * The channel dmainit() claimed and proved, or -1.  Drivers take it
 * from here rather than picking their own: the firmware owns some of
 * the sixteen, and two drivers choosing independently would eventually
 * choose the same one.
 */
int dmachannel = -1;

/*
 * Where the last failed transfer stopped.  Kept rather than printed
 * here, so the driver that owns the peripheral can print its own
 * registers beside these before anything is reset.
 */
Dmafail dmafail;

/*
 * Move len bytes between memory and a peripheral's data register,
 * paced by that peripheral's DREQ line.
 *
 * This is the other half of what this engine is for, and the half the
 * SD controller needs.  dmacopy() above is memory to memory and runs
 * flat out; a peripheral has a FIFO, and the engine has to be told to
 * wait for it.  That is the DREQ: the peripheral raises it when its
 * FIFO can take (or supply) more, the engine transfers only while it
 * is raised, and PERMAP in the transfer-info word says which of the
 * SoC's peripherals is doing the raising.
 *
 * Two asymmetries matter and both are in the transfer-info word.  The
 * peripheral side does not increment -- every word goes to or comes
 * from the same register -- so only the memory side gets Sinc or Dinc.
 * And the DREQ flag goes on the peripheral's side: Ddreq when writing
 * to it, Sdreq when reading from it.  Getting either the wrong way
 * round gives a transfer that completes and moved the wrong bytes.
 *
 * pbus is the peripheral register's address as a bus master sees it
 * (0x7e......), not the ARM's 0x3f...... mapping.
 */
int
dmaperiph(int c, Cb *cb, void *mem, u32 pbus, ulong len, int dreq, int tomem)
{
	u32 *r = dmachan(c);
	u32 *g = (u32*)DMA0;
	int i;

	if(((uintptr)cb & 31) != 0)
		return -1;

	cb->ti = Waitresp | (u32)dreq<<Permapshift;
	if(tomem){
		cb->ti |= Sdreq | Dinc;
		cb->source = pbus;
		cb->dest = busaddr(mem);
	}else{
		cb->ti |= Ddreq | Sinc;
		cb->source = busaddr(mem);
		cb->dest = pbus;
	}
	cb->len = len;
	cb->stride = 0;
	cb->next = 0;

	/*
	 * The engine reads the control block and one side of the data
	 * through the uncached alias, so both have to be in memory
	 * before it starts.  On a read the destination is cleaned as
	 * well as invalidated, so no dirty line can be written back
	 * over what the engine puts there.
	 */
	cacheflush(cb, sizeof *cb);
	if(tomem)
		cacheflushinv(mem, len);
	else
		cacheflush(mem, len);

	g[Enablereg] |= 1 << c;
	r[Cs] = Reset;
	for(i = 0; i < Timeout; i++)
		if((r[Cs] & Reset) == 0)
			break;
	if(i == Timeout){
		print("dma: channel %d will not come out of reset (cs %#lux)\n",
			c, (ulong)r[Cs]);
		return -1;
	}

	r[Cs] = Endflag | Interrupt | Error;	/* clear stale status, w1c */
	r[Conblkad] = busaddr(cb);
	r[Cs] = Active;

	for(i = 0; i < Timeout; i++){
		if(r[Cs] & Error)
			break;
		if((r[Cs] & Active) == 0)
			break;
	}
	/*
	 * Say which of the ways it can fail actually happened, and what
	 * the engine had in hand when it did.  One -1 covering a reset
	 * that would not take, an error flag and a transfer that never
	 * finished is three different bugs wearing the same face, and
	 * the difference is the whole diagnosis: still Active with the
	 * length unmoved means the peripheral never raised its DREQ,
	 * while Error means the engine tried and the bus refused.
	 */
	if(i == Timeout || (r[Cs] & Error)){
		/*
		 * Record and do not touch.  The channel is left exactly as
		 * it stopped -- not reset, not aborted -- because the
		 * caller's first job is to read the peripheral this engine
		 * was waiting on, and a reset here would take the DREQ
		 * state with it.  dmaxferstate() hands these back.
		 *
		 * Txfrlen counts DOWN as the transfer proceeds, so
		 * len-left is what actually moved, and that number is the
		 * diagnosis: an engine that moved nothing never saw a
		 * DREQ at all, while one that moved part of the transfer
		 * and stopped was being paced and then stopped being fed.
		 */
		dmafail.cs = r[Cs];
		dmafail.debug = r[Debug];
		dmafail.ti = r[Ti];
		dmafail.src = r[Sourcead];
		dmafail.dst = r[Destad];
		dmafail.len = len;
		dmafail.left = r[Txfrlen];
		dmafail.err = (r[Cs] & Error) != 0;
		return -1;
	}

	if(tomem)
		cacheinval(mem, len);
	return 0;
}

/*
 * What a driver calls: the channel and the control block are ours, the
 * caller supplies only its buffer and which peripheral paces it.
 *
 * One static control block, so one transfer at a time.  Every caller so
 * far holds its own qlock across the transfer, which is what makes that
 * safe; a second user would have to either take the same lock or bring
 * its own block to dmaperiph() above.
 */
/*
 * The channel's status word, for a caller that wants to know what
 * state the engine was in BEFORE it armed a transfer.  Every capture
 * so far has been of the wreck; this is for the moments before.
 */
/*
 * Put the channel back to rest before it is armed again.  A question,
 * not a fix: if resetting between transfers cures the stall, the state
 * that survives one is the engine's own.
 */
void
dmachanreset(void)
{
	u32 *r;
	int i;

	if(dmachannel < 0)
		return;
	r = dmachan(dmachannel);
	r[Cs] = Reset;
	for(i = 0; i < Timeout; i++)
		if((r[Cs] & Reset) == 0)
			break;
	r[Cs] = Endflag | Interrupt | Error;
}

ulong
dmachanstate(void)
{
	if(dmachannel < 0)
		return ~0UL;
	return dmachan(dmachannel)[Cs];
}

/*
 * Bytes the channel still has to move, read live from TXFR_LEN.
 *
 * dmafail.left is a snapshot taken when the wait gave up; this is the
 * engine's own counter now, which is what says whether a stalled
 * transfer has started moving again.
 */
ulong
dmachanleft(void)
{
	if(dmachannel < 0)
		return 0;
	return dmachan(dmachannel)[Txfrlen];
}

/*
 * One channel and one control block, so one caller at a time.
 *
 * Both SD drivers call this, each holding its own controller's qlock,
 * which serialises neither against the other.  For most of this port
 * that was theoretical -- sdhostbcm.c was not even compiled in -- but
 * SDHOST has a DMA path now, and two transfers sharing the static
 * control block below would each rewrite it while the engine was
 * reading the other's, with no error from anything.  The engine is
 * the shared resource; the lock belongs here and not in the drivers.
 *
 * A QLock and not a Lock: dmaperiph() spins waiting for the transfer,
 * and it is always called from process context.
 */
static QLock dmalock;

int
dmaxfer(void *mem, u32 pbus, ulong len, int dreq, int tomem)
{
	static uchar raw[sizeof(Cb) + 32];
	Cb *cb;
	int rv;

	if(dmachannel < 0)
		return -1;
	cb = (Cb*)(((uintptr)raw + 31) & ~(uintptr)31);
	qlock(&dmalock);
	rv = dmaperiph(dmachannel, cb, mem, pbus, len, dreq, tomem);
	qunlock(&dmalock);
	return rv;
}

/*
 * Choose a channel the firmware says is ours.
 *
 * This used to be channel 0, on the reasoning that it always exists.
 * It does exist, and it is not ours.  The sixteen channels are shared
 * with the VideoCore, which keeps some for itself, and which ones is a
 * firmware decision rather than a property of the SoC -- so the only
 * way to know is to ask, tag 0x00060001.  On this machine the answer
 * is 0x003c: channels 2 to 5, and channel 0 is not among them.  QEMU
 * lets every channel run regardless, so driving channel 0 works
 * perfectly here and shares an engine with the firmware on the board,
 * where the loser gets a corrupted transfer and nobody reports an
 * error.  Linux asks the same question, through the
 * brcm,dma-channel-mask the firmware writes into the device tree.
 *
 * Of the channels that are ours, take the lowest below Nlite: 7 and up
 * are cut-down engines on this SoC and cannot do everything a general
 * copy may want.  If the firmware will not answer, or answers with
 * nothing usable, decline rather than fall back -- falling back means
 * picking a channel that belongs to somebody else, which is the whole
 * bug.
 */
static int
dmachanpick(u32 *maskp)
{
	u32 mask;
	int c;

	if(mboxgetdmachans(&mask) < 0)
		return -1;
	*maskp = mask;
	for(c = 0; c < Nlite; c++)
		if(mask & (1 << c))
			return c;
	return -1;
}

/*
 * Prove the engine runs a control block, and prove it moved the data
 * rather than merely reporting that it had.
 *
 * The buffers are deliberately given a recognisable pattern with a
 * distinct destination fill, so a transfer that silently does nothing
 * shows up as the fill rather than as a plausible-looking zero.
 */
void
dmainit(void)
{
	static uchar raw[sizeof(Cb) + 32];
	static uchar src[256], dst[256];
	Cb *cb;
	u32 mask;
	int i, c;

	cb = (Cb*)(((uintptr)raw + 31) & ~(uintptr)31);

	mask = 0;
	if((c = dmachanpick(&mask)) < 0){
		if(mask == 0)
			print("DMA-NONE the firmware would not say which channels "
				"are ours; declining to guess\n");
		else
			print("DMA-NONE the firmware offers channels %#ux, none of "
				"them a full engine below %d\n", mask, Nlite);
		return;
	}

	for(i = 0; i < sizeof src; i++){
		src[i] = 0x40 + (i & 0x3f);
		dst[i] = 0xa5;			/* not zero, and not the source */
	}

	if(dmacopy(c, cb, dst, src, sizeof src) < 0){
		print("DMA-NONE channel %d at %#p did not run a control block\n",
			c, dmachan(c));
		return;
	}
	for(i = 0; i < sizeof src; i++)
		if(dst[i] != src[i]){
			print("DMA-FAIL byte %d is %#2.2ux, expected %#2.2ux\n",
				i, dst[i], src[i]);
			return;
		}
	print("dma: channel %d at %#p copied %d bytes by control block "
		"(firmware offers %#ux)\n", c, dmachan(c), (int)sizeof src, mask);
	dmachannel = c;
	print("DMA-OK control block fetched on a channel the firmware gave us, "
		"transfer completed and verified\n");
}
