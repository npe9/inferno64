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

	/*
	 * SPIN THIS LONG, THEN YIELD.  Every tag that answers answers in
	 * tens of microseconds on silicon -- GET_CLOCK_RATE 25us, an
	 * absent tag refused in 22us, SET and GET_DOMAIN_STATE 31 and
	 * 23 -- so 2 ms is about sixty times the observed latency and
	 * covers the fast path without a sleep in it.
	 *
	 * THE SLEEP WAS UNEXERCISED CODE until it was forced.  Every tag
	 * that answers does so in tens of microseconds, so el >= Fastus
	 * had never once been true in any boot -- the yield, the
	 * up->sleep wakeup and sleeping while holding mboxlock were all
	 * paths described as safe and never run.  Forced with Fastus = 0,
	 * so every mailbox wait takes the sleep: boots through the whole
	 * init sequence to RCMD-OFF, including RCMD's 180-second network
	 * wait, with THERM-OK and DRAW-OK and TK-OK on the way and no
	 * panic.  THERM-OK comes from a Dis process, so up was non-nil
	 * and the sleep really ran.
	 *
	 * Past Fastus the wait sleeps a millisecond a go instead of
	 * spinning.  A non-yielding spin for the whole bound starves the
	 * machine, and on a JTAG boot it starves it completely: a JTAG
	 * boot holds cores 1-3, so the board is single-cpu and a long
	 * kernel spin takes the network poller with it.  Measured the
	 * expensive way by the session that owns the board -- a 30-second
	 * request wedged it, recovered only by hardreset.
	 */
	Fastus	= 2000,
	Maxwaitus = 2*1000*1000,	/* the most any caller may ask for */
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
static int lastwait;	/* 0 ok, -1 out of time, -2 counter not advancing */

static int
mboxreadto(int chan, u32 *val, uvlong usec)
{
	u32 *r = mbox();
	u32 v;
	uvlong t0, el;
	int i, yield;

	t0 = systmrusec();
	/*
	 * Yieldable only in process context with interrupts on.  At boot
	 * there is no process to sleep and nothing else to run anyway,
	 * and the fast path never reaches the sleep.
	 */
	yield = up != nil && islo();
	for(i = 0; i < Spins; i++){
		/*
		 * THE DEADLINE IS CHECKED EVERY ITERATION, not only when
		 * the FIFO is empty.  It used to sit inside the Empty
		 * branch, so a read FIFO holding a word for another channel
		 * took the r[Read] path below and went round again WITHOUT
		 * EVER CONSULTING THE CLOCK: the request's own bound was
		 * ignored and Spins decided.  Measured on silicon by asking
		 * for 30 s and getting 4.174742 s -- 200e6 iterations at
		 * about 21 ns -- and then being told COUNTER NOT ADVANCING,
		 * which is the one fact a caller cannot obtain any other
		 * way and which was false.  A bound that only applies when
		 * nothing is happening is not a bound.
		 *
		 * This keeps the reason both bounds exist: if the counter is
		 * dead, systmrusec() - t0 is always zero, the deadline can
		 * never expire, and Spins remains the only thing that gets
		 * you out.  A later tidy that deletes "the redundant one"
		 * would delete the only bound that survives a stopped clock.
		 */
		el = systmrusec() - t0;
		if(el >= usec){
			lastwait = -1;
			return -1;
		}
		if(r[Status] & Empty){
			/*
			 * If the counter is dead el is always zero, so this
			 * never fires and Spins is still the only way out --
			 * which is the property that must survive any tidy
			 * of these two bounds.
			 */
			if(yield && el >= Fastus)
				tsleep(&up->sleep, return0, 0, 1);
			continue;
		}
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
	return mboxreadto(chan, val, Waitus);
}

/*
 * Exchange one property-channel message.  buf must be 16-byte aligned,
 * buf[0] its total byte length, and formatted as the tag list described
 * above.  Returns 0 on success (message code == Respok), -1 otherwise.
 * The response is written back into buf in place.
 */
/*
 * ONE EXCHANGE AT A TIME.  The property channel is a request and a
 * reply with nothing tying them together: two callers that interleave
 * each take the other's answer, and because the reply is written back
 * INTO THE REQUEST BUFFER the loser gets a well-formed message with the
 * success code set and somebody else's value in it -- a GPIO read
 * returning a clock rate, not a detectable error.
 *
 * THREE CALLERS IN THIS KERNEL, not one.  I first wrote here that
 * devv3d.c was the only one, from a grep for mboxprop -- and btbcm.c
 * and thermbcm.c reach the same channel through mboxtag(), which calls
 * mboxprop() four lines in.  So a /dev read of the temperature and a
 * BT_ON cycle and a #Q exec all share this, and the race is reachable
 * between drivers here exactly as it is on a branch with more of them.
 * Grep for the function the drivers call, not the one they end up in.
 *
 * A QLOCK AND NOT A LOCK, the same choice dmabcm.c made for the same
 * reason: the wait is long by kernel standards and the caller is always
 * process context, so other processes must keep running while one of
 * them is at the mailbox.  A Lock here was worse than no lock -- it
 * added every other mailbox user to the set of things a long wait
 * starves -- and a Lock could not be held across the sleep in
 * mboxreadto() at all.
 *
 * A caller from interrupt context would need an ilock and would then be
 * holding interrupts off for the whole exchange, which is a reason not
 * to add such a caller rather than a reason to change this.
 */
static QLock mboxlock;

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
	 * Clean the request to the point of coherency so the GPU, which
	 * reads the buffer uncached through the bus alias, sees the bytes
	 * we wrote.  cacheflush ends in a DSB, so the write-register poke
	 * below is ordered after the clean.
	 */
	/*
	 * CAPPED, because the bound comes from a caller and #Q lets a
	 * user program choose it.  Without this a write of `exec ...
	 * 30000' asks the kernel to wait thirty seconds holding the
	 * mailbox, which is how the board was wedged.  2 s is already
	 * eighty thousand times the latency of every tag that answers,
	 * so a request that misses it is not being slow.
	 */
	if(usec > Maxwaitus)
		usec = Maxwaitus;
	cacheflush(buf, reqlen);
	/*
	 * At boot there is no process to qlock with, and nothing else is
	 * running to race against.
	 */
	if(up != nil)
		qlock(&mboxlock);
	if(mboxwrite(Chanprop, (u32)(pa | Busalias)) < 0){
		if(up != nil)
			qunlock(&mboxlock);
		return -1;
	}
	r = mboxreadto(Chanprop, &resp, usec);
	if(up != nil)
		qunlock(&mboxlock);
	if(r < 0)
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
 * The ceiling mboxpropto() will silently apply, so a caller that took
 * its bound from somebody else can SAY what it actually got.  #Q lets a
 * user write `exec ... 30000' and the clamp made that 2 s with nothing
 * in the status admitting the request had been reduced -- a bound
 * reported as 30 s and enforced at 2 is the same class of lie as a spin
 * count reported as a timeout, which is the defect this cap exists
 * because of.
 */
uvlong
mboxwaitcap(void)
{
	return Maxwaitus;
}

/*
 * Which bound ended the last wait, for a caller that needs to tell
 * "the GPU has not answered yet" from "this board's counter is dead".
 * mboxpropto returns -1 for both because its contract is older than
 * the distinction.
 */
int
mboxlastwait(void)
{
	return lastwait;
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

/*
 * SET_ENABLE_QPU (tag 0x00030012), for one specific experiment.
 *
 * This is not a GPU driver and must not grow into one -- rio-pi-tk owns
 * devv3d and the QPU work.  It exists because that branch's decisive
 * question needs a mailbox call and a JTAG register read IN THE SAME
 * BOOT, and only this tree's board rig can do the second half.  The
 * question is whether SET_ENABLE_QPU ungates the V3D register block:
 * a read of 0x3fc00000 currently stalls the core and the recovery is a
 * power cycle, so the enable has to be sent first, from the board, with
 * nothing else intervening.
 *
 * Shape is the plain property-interface one: a 4-byte request (the
 * enable flag) and a 4-byte reply, so the value buffer is 4 and not the
 * 8 that mboxclockraw() uses for its id/rate pair.
 *
 * Returns 0 if the firmware ANSWERED, with its reply word, and -1 if
 * the round trip or the response bit failed.  Answered-and-refused is
 * not a failure here: it is the result.
 */
int
mboxqpuenable(int on, u32 *reply)
{
	static u32 raw[8+4];
	u32 *buf;

	buf = (u32*)(((uintptr)raw + 0xf) & ~(uintptr)0xf);
	buf[0] = 7 * 4;
	buf[1] = 0;
	buf[2] = 0x00030012;		/* tag: SET_ENABLE_QPU */
	buf[3] = 4;			/* value buffer: the flag */
	buf[4] = 4;			/* request length */
	buf[5] = on != 0;
	buf[6] = 0;			/* end tag */
	if(mboxprop(buf) < 0)
		return -1;
	if((buf[4] & 0x80000000) == 0)
		return -1;
	if(reply != nil)
		*reply = buf[5];
	return 0;
}

/*
 * The board half of devcons's QPU experiment commands.
 *
 * Installed as archqpucmd from main.c, so that os/inferno/port/devcons.c
 * holds no raspi3b addresses or symbols -- it is shared by twelve boards
 * and the first version of this broke all but one of them.
 *
 *	echo qpuenable > /dev/sysctl	SET_ENABLE_QPU, and the reply word
 *	echo qpuident  > /dev/sysctl	ONE read of V3D_IDENT0
 *
 * ident is the second independent reader of 0x3fc00000.  openocd over
 * JTAG is the first, and it reports 0xdeadbeef there; nobody can say yet
 * whether that is the bus or the debugger's filler, and two readers of
 * one address is the only discriminator available that does not risk the
 * board.  If both say deadbeef it IS the bus; if this one differs, the
 * deadbeef belongs to openocd.
 *
 * ONE WORD, NOT THREE.  Reading IDENT0, 1 and 2 in sequence would leave
 * a stall unattributable to any particular read -- the mistake made in
 * both trees today, in a peer's ident command and in this session's own
 * JTAG harness.
 *
 * iprint and a marker BEFORE the access, because this can hang the core
 * and then there is no ring to read: TRY with no READ is the signature
 * of dying in the read, and it is all this side can offer.  A JTAG read
 * at least leaves a halted target; this does not.
 */
static void
qpucmd(int ident)
{
	u32 v, rep;
	int ok;

	if(!ident){
		rep = 0;
		ok = mboxqpuenable(1, &rep);
		if(ok < 0)
			print("QPU-ENABLE unanswered"
				" (mailbox or response bit)\n");
		else
			print("QPU-ENABLE answered, reply %#ux"
				" (0 = accepted)\n", rep);
		return;
	}
	iprint("QPU-IDENT-TRY %#p\n", (void*)(BCMPERIPH + 0xc00000));
	v = *(u32*)(BCMPERIPH + 0xc00000);
	iprint("QPU-IDENT-READ %#ux (0x02443356 = \"V3D\")\n", v);
}

void
qpucmdinit(void)
{
	extern void (*archqpucmd)(int);

	archqpucmd = qpucmd;
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
