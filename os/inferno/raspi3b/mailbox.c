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

/*
 * Declared, not left implicit: systmrusec() returns a uvlong and 7c
 * assumes int for an undeclared function, which would truncate the
 * timestamps the mailbox wait below is computed from.
 */
extern	uvlong	systmrusec(void);

enum {
	Read	= 0x00/4,		/* MBOX0 read (GPU -> ARM) */
	Status	= 0x18/4,		/* MBOX0 status */
	Write	= 0x20/4,		/* MBOX0 write (ARM -> GPU) */

	Full	= 0x80000000,		/* status: mailbox full, cannot write */
	Empty	= 0x40000000,		/* status: mailbox empty, nothing to read */

	Chanprop = 8,			/* property tags, ARM to VideoCore */
	Busalias = 0xC0000000,		/* GPU-uncached view of ARM RAM */

	Respok	= 0x80000000,		/* message code: request succeeded */
	/*
	 * A SPIN COUNT CANNOT DISTINGUISH "BUSY" FROM "NEVER GOING TO
	 * REPLY", and that cost a wrong conclusion. This was the only
	 * bound, ten million uncached reads, and the comment said "about
	 * a second" -- so a request the GPU never answered took 1.0509s
	 * to give up, reproducibly to four decimal places, and that
	 * duration was read as the firmware DOING something for a
	 * second. It was this loop, measured. Sweeping a request argument
	 * 500x moved it 43us because nothing about it depends on the
	 * request at all.
	 *
	 * So the bound is a TIME now, and the spin count stays only as a
	 * backstop for a dead counter: systmrread() reads the hardware
	 * counter with no init, but if that counter is not running
	 * (SYSTMR-NONE) a purely time-based loop would never exit and
	 * would hang the boot. Which bound fired is reported, because
	 * "the GPU did not answer in time" and "this board has no usable
	 * clock" are different facts.
	 */
	Waitus	= 1000*1000,	/* default: a second, as the spin count was */
	Spins	= 200*1000*1000,	/* backstop only: far beyond Waitus */
};

static u32*
mbox(void)
{
	return (u32*)MBOX0;
}

/*
 * Post one message (already carrying its channel-free bus address in the
 * top 28 bits) on a channel.  Returns 0, or -1 if the mailbox never
 * made room for it.
 */
static int
mboxwrite(int chan, u32 data)
{
	u32 *r = mbox();
	int i;

	for(i = 0; i < Spins; i++)
		if((r[Status] & Full) == 0)
			break;
	if(i >= Spins)
		return -1;
	coherence();
	r[Write] = data | chan;
	return 0;
}

/*
 * Bounded, because every one of these runs during boot and a wait
 * without a bound is a board that says nothing at all.
 *
 * THIS COMMENT USED TO SAY the firmware answers every message on the
 * property channel, including one whose tag it does not know, so a
 * timeout here could only mean a mailbox that is not working. That is
 * FALSE on this board. EXECUTE_QPU (0x00030011) gets no reply at all
 * -- buf[1] and buf[4] both come back as the driver left them and
 * buf[5..8] as the request verbatim -- seconds after GET_CLOCK_RATE and
 * SET_ENABLE_QPU were both answered on the same channel. So a timeout
 * here means "this tag was not answered", and that is a thing one tag
 * can do while its neighbours do not.
 *
 * Returns 0 and the value, -1 if the time ran out, -2 if the spin
 * backstop ran out first, which means the counter is not advancing.
 */
static int
mboxreadto(int chan, u32 *val, uvlong usec)
{
	u32 *r = mbox();
	u32 v;
	uvlong t0;
	int i;

	t0 = systmrusec();
	for(i = 0; i < Spins; i++){
		if(r[Status] & Empty){
			if(systmrusec() - t0 >= usec)
				return -1;
			continue;
		}
		v = r[Read];
		if((int)(v & 0xf) == chan){
			*val = v & ~0xfU;
			return 0;
		}
	}
	return -2;
}

static int
mboxread(int chan, u32 *val)
{
	return mboxreadto(chan, val, Waitus);
}

/*
 * Exchange one property-channel message.  buf must be 16-byte aligned,
 * buf[0] its total byte length, and formatted as the tag list described
 * above.  Returns 0 on success (message code == Respok), -1 otherwise.
 * The response is written back into buf in place.
 */
int
mboxpropto(u32 *buf, uvlong usec)
{
	uintptr pa = (uintptr)buf;	/* RAM is identity-mapped */
	usize reqlen;
	u32 resp;

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
	if(mboxwrite(Chanprop, (u32)(pa | Busalias)) < 0)
		return -1;
	if(mboxreadto(Chanprop, &resp, usec) < 0)
		return -1;
	USED(resp);
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

int
mboxprop(u32 *buf)
{
	return mboxpropto(buf, Waitus);
}

/*
 * Can anything on this board be asked to do 3D?
 *
 * devdraw implements the draw3d letters in software and leaves its
 * gpudraw* hooks nil, so the question a GPU backend has to answer first
 * is what the VideoCore will accept. Only the firmware knows, so this
 * asks it, at boot, in the style of every other subsystem here: a
 * verdict line rather than an assumption.
 *
 * Two questions, both cheap and neither of which changes anything:
 *
 * V3D CLOCK (GET_CLOCK_RATE, clock id 5). A rate of zero means the
 * firmware does not have the block running; non-zero means it does and
 * says how fast, which is also the number any later throughput claim
 * has to be reconciled against.
 *
 * SET_ENABLE_QPU (tag 0x00030012). This is the documented bare-metal
 * route to the twelve QPUs -- enable them, then hand EXECUTE_QPU
 * (0x00030011) a block of QPU machine code. There is no GL here and no
 * V3D register driver, so that interface is the seam, and whether the
 * firmware answers it at all is the thing worth knowing before anyone
 * writes QPU code.
 *
 * QEMU emulates neither, and worse than not emulating them: it accepts
 * the tags and makes up the values. Under emulation this prints
 * V3D-BLIND because of the control below. On silicon (2026-10-08) the
 * control is refused and the verdict is V3D-OK with the clock at
 * 250 MHz -- where QEMU claimed 700. The control catches a tag that is
 * not implemented; nothing catches a VALUE that is invented, which is
 * why the number is written down here from the board and not from the
 * emulator.
 */
void
v3dprobe(void)
{
	static u32 raw[32+4];
	u32 *buf;
	u32 rate;
	int clockok, qpuok;

	buf = (u32*)(((uintptr)raw + 0xf) & ~(uintptr)0xf);

	/* GET_CLOCK_RATE, clock id 5 == V3D */
	buf[0] = 8*4;
	buf[1] = 0;
	buf[2] = 0x00030002;
	buf[3] = 8;
	buf[4] = 0;
	buf[5] = 5;			/* clock id: V3D */
	buf[6] = 0;			/* <- rate in Hz */
	buf[7] = 0;
	rate = 0;
	clockok = mboxprop(buf) >= 0;
	if(clockok)
		rate = buf[6];

	/* SET_ENABLE_QPU: 1 to turn the QPUs on */
	buf[0] = 7*4;
	buf[1] = 0;
	buf[2] = 0x00030012;
	buf[3] = 4;
	buf[4] = 0;
	buf[5] = 1;			/* enable */
	buf[6] = 0;
	qpuok = mboxprop(buf) >= 0;

	/*
	 * THE CONTROL, and it is not optional. A property mailbox can
	 * accept a tag without implementing it -- QEMU's bcm2835 does
	 * exactly that for much of the interface -- so "SET_ENABLE_QPU
	 * accepted" on its own does not distinguish real firmware from a
	 * stub. Ask for a tag that cannot exist and see whether that is
	 * accepted too. If it is, every answer above is worthless and this
	 * says so rather than reporting a capability nobody has.
	 */
	buf[0] = 7*4;
	buf[1] = 0;
	buf[2] = 0x000f0f0f;		/* no such tag, and never will be */
	buf[3] = 4;
	buf[4] = 0;
	buf[5] = 0;
	buf[6] = 0;
	if(mboxprop(buf) >= 0){
		print("V3D-BLIND the firmware `accepted' tag 0x000f0f0f, which does not exist,\n");
		print("  so SET_ENABLE_QPU accepted (clock %ud Hz) means nothing here\n", rate);
		return;
	}

	if(!clockok && !qpuok){
		print("V3D-NONE the firmware answered neither the V3D clock nor SET_ENABLE_QPU\n");
		return;
	}
	print("v3d: clock %s %ud Hz, SET_ENABLE_QPU %s\n",
		clockok ? "reported" : "refused", rate,
		qpuok ? "accepted" : "refused");
	if(rate != 0 && qpuok)
		print("V3D-OK the QPUs can be enabled and the block is clocked; EXECUTE_QPU is the seam\n");
	else if(qpuok)
		print("V3D-PART SET_ENABLE_QPU accepted but the V3D clock reads 0\n");
	else
		print("V3D-PART the clock answers but SET_ENABLE_QPU does not\n");
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
 * The board's ethernet MAC from the firmware (GET_BOARD_MAC_ADDRESS, tag
 * 0x00010003; 6-byte value in an 8-byte buffer).  On a real Pi this is
 * the b8:27:eb address derived from the board serial, which the onboard
 * LAN9514 does not carry in an EEPROM -- the USB ethernet driver has no
 * other source for it.  QEMU's property channel answers with the NIC's
 * configured MAC.  Returns 0 and fills mac on success, -1 otherwise.
 */
int
mboxgetmac(uchar *mac)
{
	static u32 raw[8+4];
	u32 *buf;
	int i;

	buf = (u32*)(((uintptr)raw + 0xf) & ~(uintptr)0xf);
	buf[0] = 8*4;			/* total bytes */
	buf[1] = 0;			/* request */
	buf[2] = 0x00010003;		/* tag: get board MAC address */
	buf[3] = 8;			/* value buffer size */
	buf[4] = 0;			/* request code */
	buf[5] = 0;			/* <- mac[0..3] */
	buf[6] = 0;			/* <- mac[4..5] */
	buf[7] = 0;			/* end tag */
	if(mboxprop(buf) < 0)
		return -1;
	if((buf[4] & 0x80000000) == 0 || (buf[4] & 0x7fffffff) < 6)
		return -1;
	for(i = 0; i < 6; i++)
		mac[i] = ((uchar*)&buf[5])[i];
	for(i = 0; i < 6; i++)
		if(mac[i] != 0)
			return 0;
	return -1;			/* all zero: no address */
}

/*
 * Board identity, from the firmware: the revision code says which Pi
 * this is, and the serial is the SoC's unique number.  Both come out
 * of OTP on real hardware and both are what a board reports about
 * itself, so they are worth having.
 */
int
mboxgetrevserial(u32 *rev, uvlong *serial)
{
	static u32 raw[10+4];
	u32 *buf;

	buf = (u32*)(((uintptr)raw + 0xf) & ~(uintptr)0xf);
	buf[0] = 10*4;
	buf[1] = 0;
	buf[2] = 0x00010002;		/* tag: get board revision */
	buf[3] = 4;
	buf[4] = 0;
	buf[5] = 0;			/* <- revision */
	buf[6] = 0;			/* end tag (rewritten below) */
	buf[7] = 0;
	buf[8] = 0;
	buf[9] = 0;
	if(mboxprop(buf) < 0)
		return -1;
	if((buf[4] & 0x80000000) == 0)
		return -1;
	*rev = buf[5];

	buf[0] = 10*4;
	buf[1] = 0;
	buf[2] = 0x00010004;		/* tag: get board serial */
	buf[3] = 8;
	buf[4] = 0;
	buf[5] = 0;			/* <- serial low */
	buf[6] = 0;			/* <- serial high */
	buf[7] = 0;			/* end tag */
	if(mboxprop(buf) < 0)
		return -1;
	if((buf[4] & 0x80000000) == 0)
		return -1;
	*serial = (uvlong)buf[6]<<32 | buf[5];
	return 0;
}

/*
 * Read the customer OTP rows -- eight 32-bit fuses the board owner may
 * program once, and only once.
 *
 * READ ONLY, deliberately.  There is a SET_CUSTOMER_OTP (0x00038021)
 * on the other side of this same interface, and it does exactly what
 * one-time-programmable means: a fuse blown on a real Pi is blown
 * forever, and the rows can additionally be locked against any further
 * write.  A boot-time self-test that wrote here would quietly consume
 * a board's fuses the first time it ran on hardware, so this reads and
 * nothing else.
 */
int
mboxgetotp(u32 *rows, int n)
{
	static u32 raw[16+4];
	u32 *buf;
	int i;

	if(n <= 0 || n > 8)
		return -1;
	buf = (u32*)(((uintptr)raw + 0xf) & ~(uintptr)0xf);
	buf[0] = (6 + 2 + n) * 4;
	buf[1] = 0;
	buf[2] = 0x00030021;		/* tag: get customer OTP */
	buf[3] = (2 + n) * 4;		/* value buffer: start, count, rows */
	buf[4] = 8;			/* request length */
	buf[5] = 0;			/* start row */
	buf[6] = n;			/* how many */
	for(i = 0; i < n; i++)
		buf[7+i] = 0;
	buf[7+n] = 0;			/* end tag */
	if(mboxprop(buf) < 0)
		return -1;
	if((buf[4] & 0x80000000) == 0)
		return -1;
	for(i = 0; i < n; i++)
		rows[i] = buf[7+i];
	return 0;
}

/*
 * Ask the firmware what a clock is actually running at (tag 0x00030002).
 * Clock ids are the firmware's own: 1 EMMC, 2 UART, 3 ARM, 4 core.
 *
 * A PL011 driver needs this and cannot get it any other way.  The baud
 * divisors are UARTCLK/(16*baud), and UARTCLK is whatever the firmware
 * left the clock at -- it is not fixed by the part, it differs between
 * Pi models, and a driver that assumes a number is programming the
 * wrong baud rate on every board that disagrees with it.  Linux asks
 * the same way, through clk-raspberrypi.
 *
 * Returns 0 and the rate in Hz, or -1.  A rate of zero is reported as
 * a failure: the firmware says so for a clock that does not exist, and
 * dividing by it would be worse.
 */
int
mboxgetclock(int clkid, u32 *rate)
{
	static u32 raw[8+4];
	u32 *buf;

	buf = (u32*)(((uintptr)raw + 0xf) & ~(uintptr)0xf);
	buf[0] = 8 * 4;
	buf[1] = 0;
	buf[2] = 0x00030002;		/* tag: get clock rate */
	buf[3] = 8;			/* value buffer: id, rate */
	buf[4] = 4;			/* request length */
	buf[5] = clkid;
	buf[6] = 0;
	buf[7] = 0;			/* end tag */
	if(mboxprop(buf) < 0)
		return -1;
	if((buf[4] & 0x80000000) == 0)
		return -1;
	if(buf[6] == 0)
		return -1;
	*rate = buf[6];
	return 0;
}

/*
 * Ask the firmware to set a clock's rate (tag 0x00038002), and report
 * what it actually set.
 *
 * This is the interface to use for a clock the firmware owns, which on
 * this SoC is most of them: the clock manager is behind CPRMAN and the
 * ARM writing it is writing over whatever the firmware is doing with
 * the same PLL.  Taking the PCM clock that way hung the board (see
 * i2sbcm.c); PWM drives the analogue audio jack and is no safer.
 *
 * Returns 0 and the rate the firmware settled on, or -1.  A rate of
 * zero back is a failure: it is what the firmware says for a clock it
 * does not have.
 */
int
mboxsetclock(int clkid, u32 hz, u32 *rate)
{
	static u32 raw[10+4];
	u32 *buf;

	buf = (u32*)(((uintptr)raw + 0xf) & ~(uintptr)0xf);
	buf[0] = 9 * 4;
	buf[1] = 0;
	buf[2] = 0x00038002;		/* tag: set clock rate */
	buf[3] = 12;			/* value buffer: id, rate, turbo */
	buf[4] = 12;			/* request length */
	buf[5] = clkid;
	buf[6] = hz;
	buf[7] = 0;			/* do not skip setting turbo */
	buf[8] = 0;			/* end tag */
	if(mboxprop(buf) < 0)
		return -1;
	if((buf[4] & 0x80000000) == 0)
		return -1;
	if(buf[6] == 0)
		return -1;
	*rate = buf[6];
	return 0;
}

/*
 * Ask which DMA channels the ARM side may use (tag 0x00060001).  The
 * answer is a bitmap, one bit per channel.
 *
 * This matters on hardware and cannot be guessed.  The BCM2835 has
 * sixteen DMA channels and the VideoCore firmware keeps some of them
 * for itself; which ones is a firmware decision, not a property of the
 * SoC.  A driver that picks a channel without asking is sharing an
 * engine with the firmware, and the failure is a corrupted transfer on
 * whichever side loses, not an error anybody reports.  Linux asks the
 * same question through the brcm,dma-channel-mask the firmware writes
 * into the device tree.
 *
 * Returns 0 and the mask, or -1.  An empty mask is a failure: it means
 * no channel is ours, and picking one anyway is the bug this exists to
 * prevent.
 */
int
mboxgetdmachans(u32 *mask)
{
	static u32 raw[8+4];
	u32 *buf;

	buf = (u32*)(((uintptr)raw + 0xf) & ~(uintptr)0xf);
	buf[0] = 7 * 4;
	buf[1] = 0;
	buf[2] = 0x00060001;		/* tag: get DMA channels */
	buf[3] = 4;			/* value buffer: the mask */
	buf[4] = 0;			/* request length */
	buf[5] = 0;
	buf[6] = 0;			/* end tag */
	if(mboxprop(buf) < 0)
		return -1;
	if((buf[4] & 0x80000000) == 0)
		return -1;
	if(buf[5] == 0)
		return -1;
	*mask = buf[5];
	return 0;
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

/*
 * Report what the board says about itself, and the customer OTP rows.
 * Read-only: see mboxgetotp.
 */
void
otpinit(void)
{
	u32 rev, rows[8];
	uvlong serial;
	int i, n;

	if(mboxgetrevserial(&rev, &serial) < 0){
		print("OTP-NONE firmware did not answer board revision/serial\n");
		return;
	}
	print("board: revision %#8.8ux serial %.16llux\n", rev, serial);

	if(mboxgetotp(rows, 8) < 0){
		print("OTP-FAIL firmware did not answer GET_CUSTOMER_OTP\n");
		return;
	}
	n = 0;
	for(i = 0; i < 8; i++)
		if(rows[i] != 0)
			n++;
	print("otp: customer rows %.8ux %.8ux %.8ux %.8ux %.8ux %.8ux %.8ux %.8ux (%d set)\n",
		rows[0], rows[1], rows[2], rows[3],
		rows[4], rows[5], rows[6], rows[7], n);
	print("OTP-OK board identity and customer OTP read (never written)\n");
}

/*
 * One property tag with a value buffer of nwords, of which the first
 * reqwords are the request.  The answer is written back over vals, and
 * the tag's own response word -- the one whose top bit says the
 * firmware understood it, and whose low bits say how much it wrote --
 * is handed back through resp.
 *
 * Every wrapper below could be written this way; this one exists
 * because the Bluetooth radio's enable is reached by a tag the
 * firmware may or may not implement, and "it said no" is not a useful
 * thing for a driver to report when what is wanted is what it actually
 * said.
 *
 * Returns 0 if the firmware processed the message at all, -1 if not.
 * A refused tag is a 0 return with the top bit of resp clear.
 */
int
mboxtag(u32 tag, u32 *vals, int nwords, int reqwords, u32 *resp)
{
	static u32 raw[24+4];
	u32 *buf;
	int i;

	if(nwords > 16)
		return -1;
	buf = (u32*)(((uintptr)raw + 0xf) & ~(uintptr)0xf);
	buf[0] = (6 + nwords) * 4;
	buf[1] = 0;
	buf[2] = tag;
	buf[3] = nwords * 4;		/* value buffer size */
	buf[4] = reqwords * 4;		/* request length */
	for(i = 0; i < nwords; i++)
		buf[5+i] = vals[i];
	buf[5+nwords] = 0;		/* end tag */
	if(mboxprop(buf) < 0)
		return -1;
	if(resp != nil)
		*resp = buf[4];
	for(i = 0; i < nwords; i++)
		vals[i] = buf[5+i];
	return 0;
}

/*
 * Set and read one of the firmware's own GPIO lines (tags 0x00038041
 * and 0x00030041).
 *
 * These are not the SoC's GPIO pins, which this kernel drives itself
 * through gpiobcm.c.  A Pi 3B carries eight more lines on an expander
 * the ARM cannot reach at all: they hang off the VideoCore, and the
 * only way to either of them is to ask the firmware.  Linux calls the
 * same thing raspberrypi,firmware-gpio.  Their numbers start at 128,
 * and on this board line 0 -- pin 128 -- is BT_ON, the Bluetooth
 * radio's enable.  The rest, in order, are WL_ON, PWR_LED_OFF,
 * GLOBAL_RESET, VDD_SD_IO_SEL, CAM_GPIO, SD_PWR_ON and SD_OC_N.
 *
 * Returns 0 or -1.  The firmware answers a line it does not have with
 * a cleared response, which is a failure here rather than a silent
 * nothing: a radio that is never powered looks exactly like a radio
 * that is not answering.
 */
int
mboxsetgpio(int pin, int on)
{
	static u32 raw[9+4];
	u32 *buf;

	buf = (u32*)(((uintptr)raw + 0xf) & ~(uintptr)0xf);
	buf[0] = 8 * 4;
	buf[1] = 0;
	buf[2] = 0x00038041;		/* tag: set gpio state */
	buf[3] = 8;			/* value buffer: pin, state */
	buf[4] = 8;			/* request length */
	buf[5] = pin;
	buf[6] = on != 0;
	buf[7] = 0;			/* end tag */
	if(mboxprop(buf) < 0){
		print("mboxsetgpio: pin %d: the mailbox call itself failed\n", pin);
		return -1;
	}
	if((buf[4] & 0x80000000) == 0){
		/*
		 * Say what the firmware said.
		 *
		 * "not set" on its own cannot be acted on: a firmware that
		 * does not carry this tag, one that carries it and refuses
		 * this line, and a malformed request all look the same from
		 * outside.  buf[1] is the overall response code
		 * (0x80000000 success, 0x80000001 partial) and buf[4] is
		 * the tag's own, so printing both separates them.
		 */
		print("mboxsetgpio: pin %d rejected: response %#lux tag %#lux\n",
			pin, (ulong)buf[1], (ulong)buf[4]);
		return -1;
	}
	return 0;
}

int
mboxgetgpio(int pin, int *on)
{
	static u32 raw[9+4];
	u32 *buf;

	buf = (u32*)(((uintptr)raw + 0xf) & ~(uintptr)0xf);
	buf[0] = 8 * 4;
	buf[1] = 0;
	buf[2] = 0x00030041;		/* tag: get gpio state */
	buf[3] = 8;			/* value buffer: pin, state */
	buf[4] = 4;			/* request length */
	buf[5] = pin;
	buf[6] = 0;
	buf[7] = 0;			/* end tag */
	if(mboxprop(buf) < 0)
		return -1;
	if((buf[4] & 0x80000000) == 0)
		return -1;
	*on = buf[6] != 0;
	return 0;
}

/*
 * Which firmware is this?
 *
 * Tag 0x00000001, the oldest tag in the property interface, and the
 * right thing to quote when reporting that some later tag is missing:
 * "the expander GPIO tags are not in this firmware" is only actionable
 * with a version beside it.
 */
int
mboxgetfwrev(u32 *rev)
{
	static u32 raw[8+4];
	u32 *buf;

	buf = (u32*)(((uintptr)raw + 0xf) & ~(uintptr)0xf);
	buf[0] = 7 * 4;
	buf[1] = 0;
	buf[2] = 0x00000001;		/* tag: get firmware revision */
	buf[3] = 4;			/* value buffer: revision */
	buf[4] = 0;			/* request length */
	buf[5] = 0;
	buf[6] = 0;			/* end tag */
	if(mboxprop(buf) < 0)
		return -1;
	if((buf[4] & 0x80000000) == 0)
		return -1;
	*rev = buf[5];
	return 0;
}

/*
 * SET_GPIO_STATE with the request-length field under control.
 *
 * mboxsetgpio sends buf[4] = 8 and the firmware leaves the tag
 * unhandled.  That was read as "this firmware has no SET_GPIO_STATE",
 * on the strength of mboxsetclock -- which works -- being built the
 * same way.  But mboxsetclock has a 12-byte value buffer, and the call
 * that DOES work on these lines, mboxgetgpio, sends a value-buffer size
 * of 8 with a request length of 4.  So the working GET and the failing
 * SET differ in exactly the field whose meaning is "how many bytes of
 * the value buffer are request data", and mboxsetclock cannot arbitrate
 * that because its two numbers are equal.
 *
 * This lets the caller choose, so the two can be compared on the board
 * instead of argued about.  It matters: replacing the firmware on the
 * boot partition is the one change here that kinstall.sh cannot
 * pre-flight and kernel8.bak does not protect.
 */
int
mboxsetgpioreq(int pin, int on, int reqbytes, u32 *tagresp)
{
	static u32 raw[9+4];
	u32 *buf;

	buf = (u32*)(((uintptr)raw + 0xf) & ~(uintptr)0xf);
	buf[0] = 8 * 4;
	buf[1] = 0;
	buf[2] = 0x00038041;		/* tag: set gpio state */
	buf[3] = 8;			/* value buffer: pin, state */
	buf[4] = reqbytes;
	buf[5] = pin;
	buf[6] = on != 0;
	buf[7] = 0;			/* end tag */
	if(mboxprop(buf) < 0)
		return -1;
	if(tagresp != nil)
		*tagresp = buf[4];
	if((buf[4] & 0x80000000) == 0)
		return -1;
	return 0;
}
