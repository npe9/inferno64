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
	Spins	= 10*1000*1000,	/* bound on a mailbox wait: uncached reads, so about a second */
	/*
	 * A TIME bound for the callers that need to tell "did not answer in
	 * time" from "answered with an error", which a spin count cannot:
	 * ~1.05s of spinning here was read as a fixed cost in the firmware's
	 * EXECUTE_QPU path and written into #Q's comment block in capitals,
	 * when it was only this loop giving up.  A figure immune to a 500x
	 * change in its own argument is not measuring the argument.
	 *
	 * Spins above stays as a BACKSTOP: systmrusec() needs no init and so
	 * is usable this early, but on a board whose counter is not running a
	 * purely time-based loop would never exit and would hang the boot.
	 * Which bound fired is reported, because "the GPU did not answer in
	 * time" and "this board has no usable clock" are different facts.
	 *
	 * Ported from inferno-rio's f8350b014 onto THIS branch's locked
	 * mailbox: that branch predates 586a77181 ("serialise the mailbox --
	 * it had no lock at all") and its mboxpropto takes no lock, so the
	 * two had to be merged rather than copied.
	 */
	Waitus	= 1000*1000,	/* default: a second, as the spin count was */
	/*
	 * BOTH BOUNDS ARE LOAD-BEARING AND THEY CATCH DIFFERENT FAULTS.
	 * This is not belt and braces and the "redundant" one must not be
	 * tidied away (inferno-rio-71's point, and worth more than the fix):
	 *
	 *	Waitus  a firmware that will never answer
	 *	Spins   a DEAD COUNTER
	 *
	 * If systmrusec() ever returns a constant -- SYSTMR-NONE, a board
	 * whose counter is not running -- then systmrusec() - t0 is always
	 * zero, the deadline can never expire, and the spin count is the
	 * only thing that gets you out.  Delete it and that board hangs in
	 * here before it has printed anything.
	 *
	 * Which is why mboxlastwait() distinguishes -1 from -2 rather than
	 * just failing: "the GPU did not answer in time" and "this board
	 * has no usable clock" need different responses from the caller,
	 * and the caller cannot tell them apart any other way.
	 */
};

/*
 * Serialises every property-channel exchange; see mboxprop below.
 */
static Lock mboxlock;

extern uvlong systmrusec(void);

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
 * without a bound is a board that says nothing at all.  The firmware
 * answers every message on the property channel, including one whose
 * tag it does not know, so a timeout here is not an unsupported tag:
 * it is a mailbox that is not working, and the caller reporting that
 * is worth more than a kernel stopped in a while loop before it has
 * printed anything.  Returns 0 and the value, or -1.
 */
/* 0 answered, -1 out of time, -2 the counter is not advancing */
static int lastwait;

int
mboxlastwait(void)
{
	return lastwait;
}

static int
mboxreadto(int chan, u32 *val, uvlong usec)
{
	u32 *r = mbox();
	u32 v;
	uvlong t0;
	int i;

	t0 = systmrusec();
	for(i = 0; i < Spins; i++){
		/*
		 * THE DEADLINE IS CHECKED EVERY ITERATION, not only when the
		 * FIFO is empty, and that placement is the whole point.
		 *
		 * With the check inside the Empty branch, a read FIFO holding
		 * a word for ANOTHER channel takes the r[Read] path and loops
		 * without ever consulting the clock -- so the request's own
		 * bound is ignored and the Spins backstop decides.  Measured
		 * on silicon asking for 30 s: it gave up at 4174742 us, which
		 * is 200e6 iterations at about 21 ns, and reported
		 * "COUNTER NOT ADVANCING" when the counter was perfectly fine.
		 * A bound that cannot be honoured is bad; a bound that then
		 * misnames which bound fired is worse, because that is the one
		 * fact the caller cannot get any other way.
		 */
		if(systmrusec() - t0 >= usec){
			lastwait = -1;
			return -1;
		}
		if(r[Status] & Empty)
			continue;
		v = r[Read];
		if((int)(v & 0xf) == chan){
			*val = v & ~0xfU;
			lastwait = 0;
			return 0;
		}
	}
	lastwait = -2;
	return -2;
}

static int
mboxread(int chan, u32 *val)
{
	u32 *r = mbox();
	u32 v;
	int i;

	for(i = 0; i < Spins; i++){
		if(r[Status] & Empty)
			continue;
		v = r[Read];
		if((int)(v & 0xf) == chan){
			*val = v & ~0xfU;
			return 0;
		}
	}
	return -1;
}

/*
 * Exchange one property-channel message.  buf must be 16-byte aligned,
 * buf[0] its total byte length, and formatted as the tag list described
 * above.  Returns 0 on success (message code == Respok), -1 otherwise.
 * The response is written back into buf in place.
 */
int	mboxpropto(u32*, uvlong);	/* defined below; mboxprop delegates to it */

int
mboxprop(u32 *buf)
{
	return mboxpropto(buf, Waitus);
}

/*
 * As mboxprop, with an explicit deadline for the reply.  It keeps
 * mboxlock: this branch serialises the property channel (586a77181) and
 * the timeout does not change why -- two callers interleaving can still
 * each take the other's reply, and a GPIO read returning a clock rate is
 * a wrong answer with the success code set rather than a detectable
 * error.  mboxlastwait() says which bound fired.
 */
int
mboxpropto(u32 *buf, uvlong usec)
{
	uintptr pa = (uintptr)buf;	/* RAM is identity-mapped */
	usize reqlen;
	u32 resp;
	int r;

	if(pa & 0xf)
		panic("mboxprop: buf %#p not 16-byte aligned", buf);
	reqlen = buf[0];		/* total length, read before the exchange overwrites it */

	/*
	 * ONE EXCHANGE AT A TIME, and nothing here used to say so.
	 *
	 * An exchange is a write of a buffer address followed by a read of
	 * the reply, with the reply landing in the caller's own buffer.  Two
	 * callers interleaving can each take the other's reply: a GPIO read
	 * returning a clock rate is not a detectable error, it is a wrong
	 * answer with the success code set.
	 *
	 * It is reachable.  Boot-time callers run one at a time, but several
	 * drivers come back at runtime -- btbcm reads a firmware GPIO to
	 * power Bluetooth, sdhostbcm and sdhcibcm ask for clock rates on a
	 * card reset, pwmbcm asks on open, and screenbcm's vsync probe waits
	 * on the display.  Any two of those can overlap.
	 *
	 * A Lock and not a QLock: mboxprop runs during boot, from
	 * mailboxinit and screeninit, where there is no process to sleep.
	 * The cost is that a waiter spins -- and a vsync wait holds this for
	 * a whole frame, up to 16.7ms -- which is why NOTHING may call the
	 * mailbox from an interrupt handler, and why a periodic vsync kproc
	 * is not an option: at 60 waits a second it would hold the mailbox
	 * essentially all the time and starve every other user.
	 */
	lock(&mboxlock);

	/*
	 * Clean the request to the point of coherency so the GPU, which
	 * reads the buffer uncached through the bus alias, sees the bytes
	 * we wrote.  cacheflush ends in a DSB, so the write-register poke
	 * below is ordered after the clean.
	 */
	cacheflush(buf, reqlen);
	if(mboxwrite(Chanprop, (u32)(pa | Busalias)) < 0){
		unlock(&mboxlock);
		return -1;
	}
	if(mboxreadto(Chanprop, &resp, usec) < 0){
		unlock(&mboxlock);
		return -1;
	}
	USED(resp);
	/*
	 * The GPU filled the response in place.  Invalidate our now-stale
	 * D-lines so the reads below fetch what the GPU wrote.  IVAC
	 * discards rather than cleans -- safe here only because the whole
	 * buffer was cleaned before the write, so no ARM-dirty line remains
	 * in it to lose.
	 */
	cacheinval(buf, reqlen);
	r = buf[1] == Respok ? 0 : -1;
	unlock(&mboxlock);
	return r;
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
 * Wait for the next vertical sync (tag 0x0004800e, SET_VSYNC).
 *
 * WHY: doc/open-issues-plan.ms item H1a.  Drawing straight into the
 * scanout buffer tears, and the cure is to flip between two buffers --
 * but a flip that does not land in vertical blank MOVES the tear instead
 * of removing it, so double buffering without this is not a fix.  The
 * mailbox already does everything else the flip needs: virtual height is
 * pinned to physical with 0x00048004 and the virtual offset 0x00048009
 * is sent as 0,0, and asking for twice the height returns twice the
 * allocation with y=h moving the scanout.
 *
 * WHETHER THE FIRMWARE IMPLEMENTS IT IS AN OPEN QUESTION, which is why
 * this returns rather than being wired into the flush.  The tag is
 * documented and present in Linux's firmware driver; a Pi 3B's blob may
 * answer it, may return immediately, or may not know it.  Those three
 * are told apart by TIMING, not by the return code: a real vsync gives a
 * stable frame period and an unimplemented one returns at once.
 *
 * IT BLOCKS THE CALLING CORE for up to a frame, so nothing in a draw
 * path may call it until that has been measured.
 */
int
mboxvsync(void)
{
	static u32 raw[8+4];
	u32 *buf;

	buf = (u32*)(((uintptr)raw + 0xf) & ~(uintptr)0xf);
	buf[0] = 7*4;			/* total bytes */
	buf[1] = 0;			/* request */
	buf[2] = 0x0004800e;		/* tag: set vsync */
	buf[3] = 4;			/* value buffer size */
	buf[4] = 0;			/* request code */
	buf[5] = 0;			/* value: in/out */
	buf[6] = 0;			/* end tag */
	if(mboxprop(buf) < 0)
		return -1;
	return 0;
}

/*
 * Ask the firmware to allocate a linear framebuffer of w x h at 32bpp.
 * One property message carries the whole setup: physical and virtual
 * size, depth, a zero virtual offset, then ALLOCATE_BUFFER (whose value
 * buffer returns the framebuffer's bus base and byte size) and GET_PITCH
 * (the scanline stride in bytes).  Returns 0 and fills *fbpa (the ARM
 * physical address, the bus alias stripped), *pitch and *fbsize on
 * success, -1 otherwise.
 *
 * vh is the VIRTUAL height.  Passing h gives the single buffer this has
 * always allocated; passing 2*h allocates two stacked buffers in one
 * allocation, which is what a page flip needs -- the flip is then a virtual
 * offset of 0 or h through mboxvirtoffset() and no copy at all.
 *
 * It is one allocation rather than two because the firmware scans out from a
 * virtual window into a single buffer; two separate ALLOCATE_BUFFER calls
 * would give two framebuffers the GPU cannot switch between.  doc/open-
 * issues-plan.ms H1a.
 */
int
mboxfballoc(int w, int h, int vh, uintptr *fbpa, u32 *pitch, u32 *fbsize)
{
	static u32 raw[40+4];
	u32 *buf, *tag, *pitchslot;
	int i;

	buf = (u32*)(((uintptr)raw + 0xf) & ~(uintptr)0xf);
	i = 2;					/* leave [0]=size, [1]=code */
	buf[i++] = 0x00048003; buf[i++] = 8; buf[i++] = 0;	/* set phys w,h */
		buf[i++] = w; buf[i++] = h;
	buf[i++] = 0x00048004; buf[i++] = 8; buf[i++] = 0;	/* set virt w,h */
		buf[i++] = w; buf[i++] = vh;
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
 * Move the scanout window within a framebuffer allocated with a virtual
 * height larger than its physical height.  THIS IS THE PAGE FLIP: with
 * vh == 2*h, an offset of y=0 shows the first buffer and y=h the second,
 * and nothing is copied.
 *
 * Tag 0x00048009 is SET_VIRTUAL_OFFSET, the same tag mboxfballoc sends once
 * with (0,0) during setup, so this is a re-send and not a new capability.
 * The firmware answers with the offset it actually took, which is checked --
 * it clamps rather than failing if the offset would scan past the allocation,
 * and a silently clamped flip would show the WRONG buffer with a success
 * code, which is the shape of bug mboxprop()'s missing lock used to have.
 *
 * Returns 0 on success, -1 if the exchange failed or the firmware took a
 * different offset than asked.  doc/open-issues-plan.ms H1a.
 */
int
mboxvirtoffset(int x, int y)
{
	static u32 raw[8+4];
	u32 *buf, *val;

	buf = (u32*)(((uintptr)raw + 0xf) & ~(uintptr)0xf);
	buf[2] = 0x00048009;		/* tag: set virtual offset */
	buf[3] = 8;			/* value buffer bytes */
	buf[4] = 0;			/* request */
	val = &buf[5];
	buf[5] = x;
	buf[6] = y;
	buf[7] = 0;			/* end tag */
	buf[0] = 8 * 4;
	buf[1] = 0;
	if(mboxprop(buf) < 0)
		return -1;
	if((int)val[0] != x || (int)val[1] != y)
		return -1;		/* clamped: NOT the buffer we asked for */
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

/*
 * Ask the firmware for an EDID block (tag 0x00030020).
 *
 * WHY: doc/open-issues-plan.ms H1a establishes that the paced page flip
 * lands inside the vertical blanking interval for any vertical total at
 * or above about 512, and 525 is the standard figure for 640x480 at
 * 60Hz -- but the ARM side cannot read the vertical total, so 525 is an
 * assumption and the item says so.  screenbcm.c:310 names the remedy:
 * "a mailbox query for the timings would settle it; nothing on the ARM
 * side can."  This is that query.  EDID's first detailed timing
 * descriptor carries vertical active and vertical blanking, and their
 * sum IS the vertical total.
 *
 * The response is 136 bytes: the block number, a status word, then 128
 * bytes of EDID.  So the value buffer is the largest of this file's
 * messages and the word count is spelled out rather than reused:
 *
 *	2 header + 3 tag + 34 value + 1 end = 40 words = 160 bytes
 *
 * TWO RESULTS, NOT ONE, and the distinction is the point.  A board with
 * no monitor attached runs a firmware default mode and has no EDID to
 * report; that is a legitimate answer and not a failure of the query.
 * So the return value says whether the MAILBOX worked, and *fwstatus
 * carries the firmware's own verdict (0 = a block was returned).
 * Collapsing the two would make "no monitor" indistinguishable from "the
 * mailbox is broken", and this tree has already been bitten by a
 * firmware that answers a tag it does not implement
 * (doc/open-issues-plan.ms, QEMU fabricating values).
 */
int
mboxedid(int block, uchar *out, u32 *fwstatus)
{
	static u32 raw[40+4];
	u32 *buf;
	int i;

	buf = (u32*)(((uintptr)raw + 0xf) & ~(uintptr)0xf);
	for(i = 0; i < 40; i++)
		buf[i] = 0;
	buf[0] = 40 * 4;
	buf[1] = 0;
	buf[2] = 0x00030020;		/* tag: get EDID block */
	buf[3] = 136;			/* value buffer: block, status, 128 */
	buf[4] = 4;			/* request length: the block number */
	buf[5] = block;
	buf[39] = 0;			/* end tag */
	if(mboxprop(buf) < 0)
		return -1;
	if((buf[4] & 0x80000000) == 0)
		return -1;
	if(fwstatus != nil)
		*fwstatus = buf[6];
	/*
	 * Copy even when the status is nonzero: a caller that wants to
	 * dump what the firmware put there can, and an untouched buffer
	 * and a zero-filled one are different pieces of evidence.
	 */
	if(out != nil)
		for(i = 0; i < 128; i++)
			out[i] = ((uchar*)&buf[7])[i];
	return 0;
}

/*
 * A clock rate WITHOUT collapsing "answered zero" into "failed".
 *
 * mboxgetclock() returns -1 both when the firmware does not answer and
 * when it answers with a rate of zero, which is right for its callers
 * -- a UART divisor cannot be computed from either -- and wrong for
 * asking a diagnostic question.  Reading "pixel clock UNREADABLE" tells
 * you nothing about which of the two happened, and the two mean
 * opposite things: an unanswered tag is a firmware that does not
 * implement it, a zero is a firmware saying that clock is not running.
 *
 * tag is the caller's: 0x00030002 GET_CLOCK_RATE, 0x00030047
 * GET_CLOCK_RATE_MEASURED, 0x00030004 GET_MAX_CLOCK_RATE.  Returns 0 if
 * the firmware answered at all, with the rate it gave (which may be 0),
 * and -1 only if the mailbox round trip or the response bit failed.
 */
int
mboxclockraw(u32 tag, int clkid, u32 *rate)
{
	static u32 raw[8+4];
	u32 *buf;

	buf = (u32*)(((uintptr)raw + 0xf) & ~(uintptr)0xf);
	buf[0] = 8 * 4;
	buf[1] = 0;
	buf[2] = tag;
	buf[3] = 8;
	buf[4] = 4;
	buf[5] = clkid;
	buf[6] = 0;
	buf[7] = 0;
	if(mboxprop(buf) < 0)
		return -1;
	if((buf[4] & 0x80000000) == 0)
		return -1;
	if(rate != nil)
		*rate = buf[6];
	return 0;
}
