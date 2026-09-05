/*
 * BCM2835 VideoCore mailbox 0 (0x3f00b880), the ARM<->GPU property
 * channel.  The ARM writes a 16-byte-aligned message buffer's bus
 * address (low nibble = channel) to the WRITE register and reads the
 * same word back from READ when the GPU has filled the buffer in place.
 * Channel 8 is the property interface: a length-prefixed list of tags,
 * each a (id, value-buffer-size, request/response code, value) tuple,
 * terminated by a zero tag.  The GPU sets the message code to
 * 0x80000000 on success and, in each tag's code word, bit 31 plus the
 * response length.  This is the interface that answers board/clock
 * queries and, above all, allocates the firmware framebuffer.
 *
 * The buffer is handed to the GPU by its bus address: on a BCM2835 the
 * VideoCore sees ARM RAM through the 0xC0000000 uncached alias, and
 * QEMU's bcm2835 models the same alias, so ORing 0xC0000000 onto the
 * ARM physical address is correct on both.  RAM here is identity-mapped,
 * so a kernel pointer is its own physical address.
 *
 * RAM is mapped cacheable (mmu.c, Pnormal) and the GPU reads the buffer
 * uncached through the alias above, so on real silicon the buffer must
 * be cleaned to the point of coherency before the WRITE and invalidated
 * after the READ, or the GPU would see a stale request and the ARM a
 * stale response.  mboxprop() does exactly that (cacheflush/cacheinval,
 * cache.c); QEMU models no data cache so those loops are no-ops there.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"

enum {
	Read	= 0x00/4,		/* MBOX0 read (GPU -> ARM) */
	Status	= 0x18/4,		/* MBOX0 status */
	Write	= 0x20/4,		/* MBOX0 write (ARM -> GPU) */

	Full	= 0x80000000,		/* status: mailbox full, cannot write */
	Empty	= 0x40000000,		/* status: mailbox empty, nothing to read */

	Chanprop = 8,			/* property tags, ARM to VideoCore */
	Busalias = 0xC0000000,		/* GPU-uncached view of ARM RAM */

	Respok	= 0x80000000,		/* message code: request succeeded */
};

static u32*
mbox(void)
{
	return (u32*)MBOX0;
}

/*
 * Post one message (already carrying its channel-free bus address in the
 * top 28 bits) on a channel and wait for the reply on the same channel.
 * Returns the bus address the GPU handed back (== what we sent).
 */
static void
mboxwrite(int chan, u32 data)
{
	u32 *r = mbox();

	while(r[Status] & Full)
		;
	coherence();
	r[Write] = data | chan;
}

static u32
mboxread(int chan)
{
	u32 *r = mbox();
	u32 v;

	for(;;){
		while(r[Status] & Empty)
			;
		v = r[Read];
		if((int)(v & 0xf) == chan)
			return v & ~0xfU;
	}
}

/*
 * Exchange one property-channel message.  buf must be 16-byte aligned,
 * buf[0] its total byte length, and formatted as the tag list described
 * above.  Returns 0 on success (message code == Respok), -1 otherwise.
 * The response is written back into buf in place.
 */
int
mboxprop(u32 *buf)
{
	uintptr pa = (uintptr)buf;	/* RAM is identity-mapped */
	usize reqlen;

	if(pa & 0xf)
		panic("mboxprop: buf %#p not 16-byte aligned", buf);
	reqlen = buf[0];		/* total length, read before the exchange overwrites it */

	/*
	 * Clean the request to the point of coherency so the GPU, which
	 * reads the buffer uncached through the bus alias, sees the bytes
	 * we wrote.  cacheflush ends in a DSB, so the write-register poke
	 * below is ordered after the clean.
	 */
	cacheflush(buf, reqlen);
	mboxwrite(Chanprop, (u32)(pa | Busalias));
	mboxread(Chanprop);
	/*
	 * The GPU filled the response in place.  Invalidate our now-stale
	 * D-lines so the reads below fetch what the GPU wrote.  IVAC
	 * discards rather than cleans -- safe here only because the whole
	 * buffer was cleaned before the write, so no ARM-dirty line remains
	 * in it to lose.
	 */
	cacheinval(buf, reqlen);
	return buf[1] == Respok ? 0 : -1;
}

/*
 * Boot probe: ask the firmware two things whose answers are fixed so the
 * round trip is verifiable, not merely non-empty -- the firmware
 * revision (a constant) and the ARM memory split (base must be 0).  This
 * proves the property channel end to end before anything is built on it.
 */
void
mailboxinit(void)
{
	static u32 raw[32+4];
	u32 *buf;
	u32 rev, base, size;

	buf = (u32*)(((uintptr)raw + 0xf) & ~(uintptr)0xf);

	/* GET_FIRMWARE_REVISION: one tag, 4-byte value buffer */
	buf[0] = 7*4;			/* total bytes */
	buf[1] = 0;			/* request */
	buf[2] = 0x00000001;		/* tag: get firmware revision */
	buf[3] = 4;			/* value buffer size */
	buf[4] = 0;			/* request code */
	buf[5] = 0;			/* <- revision */
	buf[6] = 0;			/* end tag */
	if(mboxprop(buf) < 0){
		print("MBOX-FAIL firmware-rev code %#ux\n", buf[1]);
		return;
	}
	rev = buf[5];

	/* GET_ARM_MEMORY: one tag, 8-byte value buffer (base, size) */
	buf[0] = 8*4;
	buf[1] = 0;
	buf[2] = 0x00010005;		/* tag: get ARM memory */
	buf[3] = 8;
	buf[4] = 0;
	buf[5] = 0;			/* <- base */
	buf[6] = 0;			/* <- size */
	buf[7] = 0;			/* end tag */
	if(mboxprop(buf) < 0){
		print("MBOX-FAIL arm-memory code %#ux\n", buf[1]);
		return;
	}
	base = buf[5];
	size = buf[6];

	print("MBOX firmware-rev %ud arm-mem base %#ux size %#ux %s\n",
		rev, base, size,
		base == 0 && size != 0 ? "(MBOX-OK)" : "(MBOX-BAD)");
}

/*
 * Switch a firmware-managed power domain (USB HCD, SD, etc.) on or off
 * through SET_POWER_STATE (tag 0x00028001).  The value is the device id
 * plus a state word: bit0 = on, bit1 = wait for the domain to settle.
 * On real hardware the DWC2 USB core does not respond until its domain
 * is powered here; QEMU powers everything unconditionally, so this is a
 * verification-only round trip there.  Returns 0 if the firmware reports
 * the requested power state, -1 otherwise.
 */
int
mboxsetpower(int devid, int on)
{
	static u32 raw[8+4];
	u32 *buf;

	buf = (u32*)(((uintptr)raw + 0xf) & ~(uintptr)0xf);
	buf[0] = 8*4;			/* total bytes */
	buf[1] = 0;			/* request */
	buf[2] = 0x00028001;		/* tag: set power state */
	buf[3] = 8;			/* value buffer size */
	buf[4] = 0;			/* request code */
	buf[5] = devid;			/* device id */
	buf[6] = on ? 3 : 2;		/* bit0 on, bit1 wait */
	buf[7] = 0;			/* end tag */
	if(mboxprop(buf) < 0)
		return -1;
	/* buf[6] response: bit1 set with bit0 clear means "no such device" */
	if((buf[6] & 2) != 0)
		return -1;
	return ((buf[6] & 1) != 0) == (on != 0) ? 0 : -1;
}

/*
 * Ask the firmware to allocate a linear framebuffer of w x h at 32bpp.
 * One property message carries the whole setup: physical and virtual
 * size, depth, a zero virtual offset, then ALLOCATE_BUFFER (whose value
 * buffer returns the framebuffer's bus base and byte size) and GET_PITCH
 * (the scanline stride in bytes).  Returns 0 and fills *fbpa (the ARM
 * physical address, the bus alias stripped), *pitch and *fbsize on
 * success, -1 otherwise.
 */
int
mboxfballoc(int w, int h, uintptr *fbpa, u32 *pitch, u32 *fbsize)
{
	static u32 raw[40+4];
	u32 *buf, *tag, *pitchslot;
	int i;

	buf = (u32*)(((uintptr)raw + 0xf) & ~(uintptr)0xf);
	i = 2;					/* leave [0]=size, [1]=code */
	buf[i++] = 0x00048003; buf[i++] = 8; buf[i++] = 0;	/* set phys w,h */
		buf[i++] = w; buf[i++] = h;
	buf[i++] = 0x00048004; buf[i++] = 8; buf[i++] = 0;	/* set virt w,h */
		buf[i++] = w; buf[i++] = h;
	buf[i++] = 0x00048005; buf[i++] = 4; buf[i++] = 0;	/* set depth */
		buf[i++] = 32;
	buf[i++] = 0x00048006; buf[i++] = 4; buf[i++] = 0;	/* set pixel order */
		buf[i++] = 0;			/* 0 = BGR: matches memdraw XRGB32 byte order so red reads red (real Pi default is BGR too) */
	buf[i++] = 0x00048009; buf[i++] = 8; buf[i++] = 0;	/* set virt offset */
		buf[i++] = 0; buf[i++] = 0;
	buf[i++] = 0x00040001; buf[i++] = 8; buf[i++] = 0;	/* allocate buffer */
		tag = &buf[i];			/* value: [0]=base(bus) [1]=size */
		buf[i++] = 16;			/* in: alignment; out: base */
		buf[i++] = 0;
	buf[i++] = 0x00040008; buf[i++] = 4; buf[i++] = 0;	/* get pitch */
		pitchslot = &buf[i];
		buf[i++] = 0;			/* out: pitch */
	buf[i++] = 0;				/* end tag */
	buf[0] = i * 4;
	buf[1] = 0;

	if(mboxprop(buf) < 0)
		return -1;
	if(tag[0] == 0)				/* no buffer handed back */
		return -1;
	*fbpa = (uintptr)(tag[0] & ~Busalias);	/* bus alias -> ARM physical */
	*fbsize = tag[1];
	*pitch = *pitchslot;
	return 0;
}
