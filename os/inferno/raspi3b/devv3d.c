#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

/*
 * #Q: the VideoCore IV QPUs, as far as the firmware will expose them.
 *
 * WHY THIS IS AN INSTRUMENT AND NOT YET A DRIVER.
 *
 * devdraw implements the draw3d protocol letters in software and leaves
 * its gpudraw* hooks nil.  Filling them on this board means driving the
 * V3D, and there is no OpenGL here, no V3D register driver and -- the
 * part that decides the approach -- no VideoCore documentation anywhere
 * on the machine this was written on.  So the QPU instruction encoding
 * cannot be looked up.  It has to be established from the hardware.
 *
 * That is possible, and the reason it is possible is worth stating:
 * EXECUTE_QPU reports whether the program it was handed reached a
 * thread-end within a timeout.  So
 *
 *	- hand it GARBAGE.  If the firmware is really running it, the QPU
 *	  will not reach a thread-end and the call TIMES OUT.  If the
 *	  firmware is ignoring the code, the call returns promptly.  That
 *	  distinguishes "executing" from "accepting" without knowing one
 *	  valid instruction.
 *
 *	- then vary a candidate end-of-program encoding until the call
 *	  returns promptly instead of timing out.  That identifies the
 *	  encoding by its effect.
 *
 * Neither step needs a document, and both need a BOARD: QEMU's property
 * mailbox accepts tags it does not implement (it accepts 0x000f0f0f,
 * which does not exist), so every answer here is meaningless under
 * emulation and v3dprobe() in mailbox.c says so.
 *
 * Which is why the interface below reports RAW results and lets the
 * caller choose the request words, rather than encoding what I believe
 * the EXECUTE_QPU argument layout to be.  What I believe is: four words,
 * (num_qpus, control_list_bus_address, noflush, timeout_ms), and a
 * response of 0 for success.  If that is wrong, `exec' takes the
 * numbers as arguments so the layout can be varied from Limbo without
 * rebuilding a kernel -- and a kernel rebuild plus a card swap is the
 * reason an experiment like this otherwise costs ten minutes a try.
 *
 *	echo reset >/dev/v3dctl
 *	cp prog.qpu /dev/v3dcode
 *	echo enable >/dev/v3dctl
 *	echo exec 1 1 1000 >/dev/v3dctl
 *	cat /dev/v3dctl
 *
 * The status line reports the response word and the ELAPSED
 * MICROSECONDS, because elapsed time is the signal: a timeout and a
 * refusal both look like failure in a response code, and only the clock
 * tells them apart.
 *
 * THE QEMU BASELINE, measured, so a real board's answer is not read
 * against an expectation but against a number:
 *
 *	clock hz 700000000	<- FALSE. Silicon says 250000000.
 *	enabled 1
 *	code 15
 *	exec accepted resp 0x1 22 us
 *
 * Fifteen bytes of garbage for a program, a 200ms timeout, and it came
 * back in 22 microseconds with a nonzero response. Too fast to have run
 * anything and far too fast to have timed out: that is the signature of
 * a mailbox that accepts the tag and does nothing, which is what
 * v3dprobe()'s nonsense-tag control already says of this emulator.
 *
 * AND THE CLOCK IS THE HARDER LESSON. The real board reports 250 MHz
 * where QEMU reported 700. So the emulator does not only accept tags it
 * does not implement -- it FABRICATES PLAUSIBLE VALUES for tags it does
 * accept, and the nonsense-tag control cannot catch that: there is no
 * nonsense VALUE. Anything sized against a firmware number read under
 * emulation is wrong by whatever the emulator felt like, here 2.8x.
 * On QEMU the only safe reading of a firmware number is that it is a
 * number. (Found by the raspi3b-port session running this on silicon.)
 *
 * SILICON, 2026-10-08: the nonsense tag is REFUSED, SET_ENABLE_QPU is
 * accepted and the block is clocked at 250 MHz.
 *
 * AND EXECUTE_QPU IS NOT ANSWERED ON THIS BOARD AT ALL. Nine bytes of
 * garbage, JTAG-booted so the card kept its own kernel:
 *
 *	exec refused code 0x0 tag 0x0 UNTOUCHED wrote 0 bytes 1050949 us
 *	value 0xdeadbeef 0xc0332240 0x1 0x3e8
 *
 * buf[1] and buf[4] are what this driver initialised them to and
 * buf[5..8] are the request verbatim. The GPU did not write the
 * response buffer. There was no reply to read -- seconds after
 * GET_CLOCK_RATE and SET_ENABLE_QPU were both answered on the same
 * channel.
 *
 * AND THE 1.0509s WAS THIS KERNEL'S OWN SPIN LOOP. mailbox.c bounded a
 * mailbox wait with a COUNT of ten million uncached reads, whose own
 * comment said "about a second". So 1.0509s is how long it takes to
 * give up, which is why it was reproducible to four decimal places,
 * why sweeping a request word 500x moved it 43us, and why no argument
 * moves it: nothing about that duration depends on the request. It was
 * never the firmware doing something for a second. mboxread is bounded
 * by TIME now, with the spin count demoted to a backstop for a dead
 * counter, so "not answered yet" and "never going to answer" are at
 * least separable.
 *
 * WHICH INVERTS THE 65000x THIS FILE WAS BUILT ON.
 *
 *	QEMU     code 0x80000000 tag 0x80000000 PROCESSED, 15 us
 *	silicon  code 0x0        tag 0x0        UNTOUCHED, spin-out
 *
 * The emulator is the one that PROCESSES the tag and answers at once;
 * the board is the one that does not answer. Earlier versions of this
 * comment said the opposite in capitals, and what they were reading
 * was the spin-out duration.
 *
 * So the open question is no longer what the argument layout is. It is
 * why this one tag is not answered when its neighbours are. A layout
 * search would have been fitting parameters to a request nobody
 * replies to.
 *
 * Three elapsed levels have been seen for the same command shape
 * across builds -- 1.0509s, ~1.14s (n=13), ~0.83s -- and no mechanism
 * is offered for why a device-code change would move a fixed spin
 * count. On the record, unexplained, and a further reason to read
 * nothing into the absolute number.
 *
 * (Measured by the raspi3b-port session on the board, against this
 * device at 47931de65, JTAG-booted. Reverting a tree and reverting a
 * card are two acts and earlier numbers came from a card still running
 * a device the tree no longer had.)
 *
 * So on silicon, with garbage code:
 *	elapsed ~= the timeout	the QPUs really ran it and never ended
 *	elapsed ~= 0, resp 0	the firmware did nothing (or refused)
 * and the first of those is the thing that makes the rest possible.
 */

enum {
	Qdir,
	Qctl,
	Qcode,

	Codemax	= 4096,		/* QPU instructions are 8 bytes; this is 512 */
	Busalias = 0xc0000000,	/* uncached alias the VideoCore reads through */

	/*
	 * The V3D register block itself, at the peripheral base plus
	 * 0xc00000. Reading IDENT0 answers a question the mailbox cannot:
	 * is the hardware THERE, independent of whether the firmware will
	 * talk about it. On a Pi it should read 0x02443356 -- "V3D" with a
	 * version nibble.
	 *
	 * READING THIS MIGHT HANG THE SOC, and `might' is the whole of
	 * what is known.  A peripheral whose power domain is off is not
	 * guaranteed to politely return zero on this chip and the access
	 * may stall the bus.  THIS HAS NOT BEEN DEMONSTRATED: the one
	 * silicon reading that reached 0x3fc00000 over JTAG returned
	 * 0xdeadbeef three times with the debugger exiting 0 and the
	 * board still running, and an earlier report that it stalled was
	 * retracted (the wedge came from a peripheral-hole read in the
	 * same script, which also left cpu0 unable to execute debug
	 * opcodes).  So the caution stands on the asymmetry -- a wedge
	 * costs a power cycle and a success buys little -- and not on
	 * evidence.  It is a separate command needing an explicit force
	 * and never part of a status read.
	 *
	 * SET_ENABLE_QPU UNGATES THIS BLOCK, measured on silicon in one
	 * firmware session: IDENT0 reads 0xdeadbeef through a debugger
	 * before it and 0x02443356 after, and the kernel's own read
	 * agrees -- so that deadbeef was the debugger's filler for a
	 * GATED block, not a bus value.  Reading a gated block therefore
	 * answers "absent" about hardware that is there, which is why
	 * `enable' has to come first.
	 *
	 * This comment used to say the battery asked for the domain
	 * before reading, and NO question in it did; fixed there too.
	 * The ungated state survives a JTAG boot and does NOT survive
	 * hardreset, so a JTAG boot is not a clean slate for this.
	 */
	V3dbase	= 0x3fc00000,
	V3dident0 = 0,		/* word offsets */
	V3dident1 = 1,
	V3dident2 = 2,

	/*
	 * THE USER SHADER REQUEST QUEUE, which is how a QPU program is
	 * started WITHOUT the firmware -- and which this plan had never
	 * considered: a grep for SRQ in doc/qpu-plan.ms and in this file
	 * found nothing before these lines.
	 *
	 * EXECUTE_QPU is the firmware doing this on the ARM's behalf, and
	 * the plan has eliminated everything reachable through it: the
	 * message is accepted, a four-byte reply header is written, and
	 * the job never completes.  Its own last section says the
	 * remaining space is "between the submission and the QPU" and
	 * names the V3D registers as the way in.  These four are that
	 * way in.
	 *
	 * Offsets taken from Linux's drivers/gpu/drm/vc4/vc4_regs.h,
	 * which is the only copy of them on this disk.  Note that vc4
	 * only DUMPS these registers -- its DRM driver submits through
	 * the binning and rendering pipeline instead -- so Linux is an
	 * authority on the addresses and not on the protocol.
	 *
	 * SRQCS's FIELD LAYOUT IS NOT IN THAT HEADER and is not assumed
	 * here.  The whole word is reported before and after a
	 * submission and nothing decodes it, because a decoded field is
	 * exactly the thing that would look right while being wrong.
	 */
	V3dsrqpc = 0x430/4,	/* program counter: writing it QUEUES */
	V3dsrqua = 0x434/4,	/* uniforms address */
	V3dsrqul = 0x438/4,	/* uniforms length */
	V3dsrqcs = 0x43c/4,	/* control and status */

	/*
	 * Cache control, used exactly as Linux's vc4_flush_caches() does
	 * before a job: clear L2, then flush all four slice caches.
	 *
	 * L2CENA IS DELIBERATELY NOT WRITTEN.  Linux enables L2
	 * somewhere this reading did not locate, and a program fetched
	 * through a disabled L2 goes straight to memory -- which for a
	 * 24-byte test is what is wanted, because there is then no cache
	 * state to have got wrong.  If the program runs with L2 off, L2
	 * is a later optimisation; if it does not, L2 was not the
	 * reason.
	 */
	V3dl2cactl = 0x20/4,
	V3dslcactl = 0x24/4,
	L2cclr	= 1<<2,
	Slcflushall = 0x0f0f0f0f,	/* T1CC|T0CC|UCC|ICC, 4 bits each */

	Identv3d = 0x02443356,	/* what IDENT0 reads when ungated */

	Tagalloc = 0x0003000c,	/* ALLOCATE_MEMORY: size, align, flags */
	Taglock	= 0x0003000d,	/* LOCK_MEMORY: handle -> bus address */
	Tagunlock = 0x0003000e,	/* UNLOCK_MEMORY: handle */
	Tagfree	= 0x0003000f,	/* RELEASE_MEMORY: handle */
	Memflags = 0xc,		/* COHERENT|DIRECT, as a QPU program wants */

	Tagclock = 0x00030002,	/* GET_CLOCK_RATE */
	Tagqpuen = 0x00030012,	/* SET_ENABLE_QPU */
	Tagqpuex = 0x00030011,	/* EXECUTE_QPU */
	Clkv3d	= 5,		/* clock id */
};

static Dirtab v3ddir[] =
{
	".",		{Qdir, 0, QTDIR},	0,	DMDIR|0555,
	"v3dctl",	{Qctl, 0},		0,	0664,
	"v3dcode",	{Qcode, 0},		0,	0222,
};

/*
 * The code and the control list have to be where the VideoCore can read
 * them.  RAM is identity-mapped here and the GPU reads through the bus
 * alias, which is what mboxprop() already relies on, so a static buffer
 * plus cacheflush() is the whole of it.  Aligned to 16 because the
 * property buffer must be and it costs nothing to match.
 */
static struct {
	u32	code[Codemax/4];
	u32	ctrl[4];	/* one job: uniforms, code */
	u32	unif[4];
	int	ncode;		/* bytes of code loaded */
	int	enabled;	/* last enable we believe SUCCEEDED */
	int	enabletried;	/* whether an enable has been attempted */
	int	enableok;	/* ...and whether the last attempt worked */
	u32	lastargs[4];	/* the four words the last exec actually sent */
	int	lastctlidx;	/* which of them carried the control address */
	/*
	 * WHAT THE FIRMWARE WROTE, which is not what we sent. This used to
	 * be a single `lastresp = buf[5]', read unconditionally -- so at
	 * ctlidx 0 it reported the control-list address this driver had
	 * written one line earlier, and otherwise it reported w0. Every
	 * `resp 0x1' this device ever printed was w0 == 1 echoed back. The
	 * control that proved it: send w0 = 0xdeadbeef, read resp
	 * 0xdeadbeef; send 0x5a5a5a5a, read 0x5a5a5a5a. Verbatim, twice,
	 * on silicon.
	 *
	 * The firmware's actual verdict is in the two words below.
	 * lastcode is the mailbox response (0x80000000 ok,
	 * 0x80000001 error parsing the request) and lasttag is the TAG's
	 * response word: bit 31 set means the tag was processed, the low
	 * bits are how many bytes it wrote. lasttag == 0 means
	 * EXECUTE_QPU was never touched -- which is the one thing this
	 * whole instrument exists to find out, and it was not being read.
	 * (Found by the raspi3b-port session.)
	 */
	u32	lastcode;	/* buf[1]: the mailbox response code */
	u32	lasttag;	/* buf[4]: processed bit | bytes written */
	u32	lastval[4];	/* buf[5..8] AFTER the call */
	int	lastok;		/* whether mboxprop reported success */
	int	lastwait;	/* 0 answered, -1 out of time, -2 counter dead */
	uvlong	lastwaitus;	/* the bound the CALLER asked for */
	uvlong	lastwaitused;	/* ...and the one that was enforced */
	uvlong	lastus;		/* how long it took */
	u32	clock;
	int	clockok;
	u32	memhandle;	/* firmware memory handle, 0 = none */
	u32	membus;		/* ...its bus address once locked */
	int	memsize;
	/*
	 * WHERE membus CAME FROM, because `gpualloc' and `gpufake' set
	 * the same three fields and the status line read identically for
	 * both.  H2 asks whether EXECUTE_QPU answers from FIRMWARE
	 * memory when it never answers from our own alias, and that
	 * question is only answerable if a second silence can be
	 * attributed to the exec rather than to an allocation that
	 * quietly did not happen.  The allocating path has never
	 * succeeded anywhere -- QEMU refuses it for want of alias bits
	 * in the returned address -- which is exactly the shape of code
	 * that is wrong in a way no run has shown.
	 */
	int	memsrc;		/* Memnone, Memfirmware, Memfake */
	/*
	 * HOW FAR THE ALLOCATION GOT, kept even when it failed, because
	 * "the firmware refused to give us memory" and "we never asked"
	 * are different answers to h2 and the status could not tell them
	 * apart: every failure path calls v3dgpufree(), which reset
	 * memsrc to Memnone, so a refusal read exactly like an untried
	 * driver.  And `lock answered' is not `lock gave a usable
	 * address': ALLOCATE_MEMORY and LOCK_MEMORY each either got a
	 * reply or did not, which is the fact that says the firmware was
	 * listening, and the address is a separate fact on top.
	 */
	int	memtried;	/* a gpualloc was attempted at all */
	int	memallocack;	/* ALLOCATE_MEMORY was answered */
	int	memlockack;	/* LOCK_MEMORY was answered */
	u32	ctlbus;		/* the control-list address actually sent */
	u32	blk[6];		/* first words of the block exec wrote */
	u32	ident[3];	/* V3D_IDENT0..2, if ever read */
	int	identread;
	/*
	 * How far v3dident() got, set BEFORE each read.  A V3D read that
	 * stalls never returns, so nothing after it runs and the status
	 * file cannot be asked -- but this word is in the kernel's data
	 * and a halted target can be read over JTAG.  It is the only way
	 * to learn WHICH read died, which is why the reads are one at a
	 * time and default to one.
	 */
	int	identtried;
	/*
	 * The user shader request queue, before and after a submission.
	 * Three reads and not two: srqcs2 is taken after the loop ended
	 * for ANY reason, so a timeout still records what the register
	 * finally said rather than only what it said while equal.
	 */
	int	srqtried;
	int	srqtimeout;
	u32	srqcs0, srqcs1, srqcs2;
	u32	srqpc0;
	uvlong	srqus;
	u32	srqblk[6];
} v3d;

static Lock v3dlk;

/*
 * FILE SCOPE, not a function-local static: 7l emits no symbol for a
 * function-local `static u32 raw[]', so there is nothing for ksyms to
 * resolve and the request/response buffer cannot be read from a halted
 * target over JTAG. That is where the firmware's verdict lives, so it
 * has to be reachable. 16-byte aligned by hand below.
 */
static u32	v3draw[32+4];

extern int mboxprop(u32*);
/*
 * DECLARED, not left implicit. systmrusec() returns a uvlong and 7c
 * assumes int for an undeclared function, so without this the elapsed
 * microseconds -- the one number this instrument exists to report --
 * would be silently truncated. It linked either way.
 */
extern uvlong systmrusec(void);
extern int mboxpropto(u32*, uvlong);
extern uvlong mboxwaitcap(void);	/* the bound mboxpropto will clamp to */
extern int mboxlastwait(void);

static int
v3dclock(void)
{
	u32 *buf;

	buf = (u32*)(((uintptr)v3draw + 0xf) & ~(uintptr)0xf);
	buf[0] = 8*4;
	buf[1] = 0;
	buf[2] = Tagclock;
	buf[3] = 8;
	buf[4] = 0;
	buf[5] = Clkv3d;
	buf[6] = 0;
	buf[7] = 0;
	if(mboxprop(buf) < 0)
		return -1;
	v3d.clock = buf[6];
	v3d.clockok = 1;
	return 0;
}

static int
v3denable(int on)
{
	u32 *buf;

	buf = (u32*)(((uintptr)v3draw + 0xf) & ~(uintptr)0xf);
	buf[0] = 7*4;
	buf[1] = 0;
	buf[2] = Tagqpuen;
	buf[3] = 4;
	buf[4] = 0;
	buf[5] = on != 0;
	buf[6] = 0;
	v3d.enabletried = 1;
	if(mboxprop(buf) < 0){
		v3d.enableok = 0;
		return -1;
	}
	v3d.enableok = 1;
	v3d.enabled = on != 0;
	return 0;
}

/*
 * Run the loaded code on nqpus QPUs.  noflush and timeout are the
 * caller's, not this file's opinion, for the reason in the header: the
 * argument layout is what is being established, so it is not buried
 * here.
 *
 * The control list is one (uniforms, code) pair per job, and both
 * addresses are bus addresses.  Everything written here is cleaned to
 * the point of coherency before the call, because the GPU reads it
 * uncached.
 */
/*
 * THE ARGUMENT LAYOUT IS WHAT IS BEING ESTABLISHED, so the four words
 * are the caller's and ctlidx says which of them gets the control
 * list's bus address -- that address has to be real or nothing can
 * run, but WHICH word carries it is a guess like the rest.
 *
 * This replaced an `exec nqpus noflush timeout' that baked in a
 * layout I had only reasoned my way to, and reasoning was not enough:
 * see the header for the 500x timeout sweep that moved nothing.
 */
static int
v3dexecraw(int ctlidx, u32 w0, u32 w1, u32 w2, u32 w3, uvlong waitus)
{
	u32 *buf;
	uvlong t0;
	int i, nj;

	if(v3d.ncode <= 0)
		error("no code loaded");
	if(ctlidx < 0 || ctlidx > 3)
		error("ctlidx must be 0..3");
	nj = 1;

	/*
	 * If firmware memory has been allocated, the code and the control
	 * list go THERE and the control list carries the firmware's own
	 * bus addresses. That is plan item 3, and without this the
	 * allocation would be plumbing nothing uses.
	 *
	 * Layout inside the block: the control list first (two words),
	 * then the uniforms (four), then the code. Everything the QPU
	 * fetches is then inside one locked allocation, which is the
	 * arrangement the firmware's own examples use.
	 */
	if(v3d.membus != 0 && (v3d.membus & 0xc0000000) != 0){
		u32 *m;
		u32 cbus, ubus, kbus;
		uintptr pa;

		if(2*4 + sizeof v3d.unif + v3d.ncode > v3d.memsize)
			error("gpu memory too small for code and control");
		/*
		 * THE ARM POINTER IS THE PHYSICAL ADDRESS, which is the bus
		 * address with the alias bits CLEARED -- this kernel has
		 * KZERO == PHYSDRAM == 0, so RAM is identity mapped at zero
		 * and nothing maps 0xc0000000 for the ARM at all.
		 *
		 * This line used to SET those bits, deriving an ARM pointer
		 * by turning a physical address into a bus address, and
		 * every write through it would have hit unmapped memory and
		 * taken the board down the first time a real allocation
		 * succeeded. The comment that stood here described clearing
		 * them while the code set them; the comment was right.
		 *
		 * Bounds-checked, because a firmware that returned an
		 * address outside RAM would fault just as surely as the bug
		 * did, and this driver cannot assume the firmware's answer
		 * is sane -- the emulator's was not.
		 *
		 * THE BOUND IS BCMPERIPH AND NOT DRAMSIZE, and getting that
		 * wrong is what stopped the one h2 attempt on silicon.  The
		 * firmware allocated 4096 bytes at bus 0xbeaccf60, which is
		 * physical 0x3eaccf60, about 1002 MB -- above arm-mem's
		 * 960 MB, because allocating above the ARM/VideoCore split
		 * is what the firmware is SUPPOSED to do.  This test used
		 * DRAMSIZE, which is 256 MB here, so it refused an
		 * allocation the kernel can perfectly well reach and the
		 * question could not be asked.
		 *
		 * What the kernel can reach is what mmuinit() maps:
		 * os/inferno/raspi3b/mmu.c fills 512 2 MB L2 entries over
		 * 0..1GB, Pdevice from BCMPERIPH up and Pnormal below it,
		 * so every address under BCMPERIPH is mapped cached RAM --
		 * the GPU window at 0x3c000000..0x3f000000 included.  That
		 * mapping is incidental rather than written for this, which
		 * is why it is cited here: if mmuinit stops covering it,
		 * this breaks and the comment says where to look.
		 *
		 * The mapping is CACHED, which is why v3dexecraw
		 * cacheflush()es the code, uniforms and control list below
		 * before the exchange.  That was already necessary for
		 * Memflags 0xc and is necessary for this too.
		 */
		pa = v3d.membus & ~0xc0000000U;
		if(pa == 0 || pa + v3d.memsize > BCMPERIPH)
			error("gpu memory is not in RAM this kernel maps");
		m = (u32*)(uintptr)pa;
		cbus = v3d.membus;
		ubus = v3d.membus + 2*4;
		kbus = v3d.membus + 2*4 + sizeof v3d.unif;
		for(i = 0; i < 4; i++)
			m[2 + i] = v3d.unif[i];
		memmove((uchar*)m + 2*4 + sizeof v3d.unif, v3d.code, v3d.ncode);
		m[0] = ubus;
		m[1] = kbus;
		cacheflush(m, 2*4 + sizeof v3d.unif + v3d.ncode);
		for(i = 0; i < nelem(v3d.blk); i++)
			v3d.blk[i] = m[i];
		v3d.ctlbus = cbus;
	}else{
		/* one job: uniforms then code, both bus addresses */
		for(i = 0; i < nj && i < nelem(v3d.ctrl)/2; i++){
			v3d.ctrl[2*i]   = (u32)((uintptr)v3d.unif | Busalias);
			v3d.ctrl[2*i+1] = (u32)((uintptr)v3d.code | Busalias);
		}
		cacheflush(v3d.code, v3d.ncode);
		cacheflush(v3d.unif, sizeof v3d.unif);
		cacheflush(v3d.ctrl, sizeof v3d.ctrl);
		v3d.ctlbus = (u32)((uintptr)v3d.ctrl | Busalias);
	}

	buf = (u32*)(((uintptr)v3draw + 0xf) & ~(uintptr)0xf);
	buf[0] = 10*4;
	buf[1] = 0;
	buf[2] = Tagqpuex;
	buf[3] = 16;
	buf[4] = 0;
	buf[5] = w0;
	buf[6] = w1;
	buf[7] = w2;
	buf[8] = w3;
	buf[5+ctlidx] = v3d.ctlbus;
	buf[9] = 0;
	for(i = 0; i < 4; i++)
		v3d.lastargs[i] = buf[5+i];
	v3d.lastctlidx = ctlidx;
	t0 = systmrusec();
	v3d.lastok = mboxpropto(buf, waitus) >= 0;
	v3d.lastus = systmrusec() - t0;
	v3d.lastwait = mboxlastwait();
	v3d.lastwaitus = waitus;
	v3d.lastwaitused = waitus > mboxwaitcap()? mboxwaitcap() : waitus;
	v3d.lastcode = buf[1];
	v3d.lasttag = buf[4];
	for(i = 0; i < 4; i++)
		v3d.lastval[i] = buf[5+i];
	return 0;
}

/*
 * PLAN ITEM 2: any property tag, from Limbo.
 *
 *	echo tag TAG VALBYTES [w0 [w1 [w2 [w3]]]] >/dev/v3dctl
 *
 * The highest-leverage thing in doc/qpu-plan.ms by a wide margin: it
 * makes the power-domain and unimplemented-tag hypotheses testable, and
 * every firmware question after them, without a kernel rebuild. The
 * alternative was a C function per tag, which is how this file started
 * and why it had three.
 *
 * Nothing is interpreted. The tag, the value-buffer size and up to four
 * words go out as given and the whole response comes back, because what
 * a given tag expects is exactly what is not known.
 */
static int
v3dtag(u32 tag, int valbytes, u32 w0, u32 w1, u32 w2, u32 w3, uvlong waitus)
{
	u32 *buf;
	uvlong t0;
	int i, nw;

	if(valbytes < 0 || valbytes > 16)
		error("value size must be 0..16 bytes");
	nw = (valbytes + 3)/4;
	buf = (u32*)(((uintptr)v3draw + 0xf) & ~(uintptr)0xf);
	buf[0] = (5 + nw + 1)*4;
	buf[1] = 0;
	buf[2] = tag;
	buf[3] = valbytes;
	buf[4] = 0;
	if(nw > 0) buf[5] = w0;
	if(nw > 1) buf[6] = w1;
	if(nw > 2) buf[7] = w2;
	if(nw > 3) buf[8] = w3;
	buf[5+nw] = 0;			/* end tag */
	for(i = 0; i < 4; i++)
		v3d.lastargs[i] = i < nw? buf[5+i] : 0;
	v3d.lastctlidx = -1;		/* not an exec */
	t0 = systmrusec();
	v3d.lastok = mboxpropto(buf, waitus) >= 0;
	v3d.lastus = systmrusec() - t0;
	v3d.lastwait = mboxlastwait();
	v3d.lastcode = buf[1];
	v3d.lasttag = buf[4];
	for(i = 0; i < 4; i++)
		v3d.lastval[i] = i < nw? buf[5+i] : 0;
	return 0;
}

/*
 * PLAN ITEM 3, and the leading hypothesis in doc/qpu-plan.ms.
 *
 * The code and the control list have been static kernel memory passed
 * as `pa | 0xc0000000', the uncached alias the VPU reads property
 * messages through -- and that is the thing that works for a property
 * message precisely because the VPU reads it. The QPUs fetch through
 * the V3D, which is not the VPU, and the documented way to get memory
 * a QPU can run from is to ask the firmware: ALLOCATE_MEMORY then
 * LOCK_MEMORY, which returns a bus address.
 *
 * So this allocates, locks, and copies the loaded code and a control
 * list into it. If EXECUTE_QPU then answers, the alias was the fault
 * and nothing else here was wrong. If it still does not answer, H2 is
 * dead and the mailbox has nothing further to offer -- which is a
 * result, and the plan says to write it down rather than drift into a
 * V3D register driver.
 *
 * The handle is kept so the memory can be unlocked and released; a
 * second `gpualloc' releases the first, because leaking GPU memory
 * across experiments on a 1GB board would eventually look like a
 * firmware fault.
 */
enum {
	Memnone = 0,
	Memfirmware,
	Memfake,
};

static int
v3dgpufree(void)
{
	u32 *buf;

	if(v3d.memhandle == 0)
		return 0;
	buf = (u32*)(((uintptr)v3draw + 0xf) & ~(uintptr)0xf);
	buf[0] = 7*4; buf[1] = 0; buf[2] = Tagunlock; buf[3] = 4;
	buf[4] = 0; buf[5] = v3d.memhandle; buf[6] = 0;
	mboxprop(buf);
	buf[0] = 7*4; buf[1] = 0; buf[2] = Tagfree; buf[3] = 4;
	buf[4] = 0; buf[5] = v3d.memhandle; buf[6] = 0;
	mboxprop(buf);
	v3d.memhandle = 0;
	v3d.membus = 0;
	v3d.memsrc = Memnone;
	/* memtried/memallocack/memlockack deliberately survive: they are
	 * the record of what was attempted, and every failure path here
	 * runs through this function. */
	return 0;
}

static int
v3dgpualloc(int size)
{
	u32 *buf;

	if(size <= 0 || size > 1024*1024)
		error("size must be 1..1048576");
	v3dgpufree();
	v3d.memtried = 1;
	v3d.memallocack = 0;
	v3d.memlockack = 0;
	buf = (u32*)(((uintptr)v3draw + 0xf) & ~(uintptr)0xf);
	buf[0] = 9*4; buf[1] = 0; buf[2] = Tagalloc; buf[3] = 12;
	buf[4] = 0; buf[5] = size; buf[6] = 16; buf[7] = Memflags; buf[8] = 0;
	if(mboxpropto(buf, (uvlong)1000*1000) < 0)
		error("ALLOCATE_MEMORY was not answered");
	v3d.memallocack = 1;
	v3d.memhandle = buf[5];
	if(v3d.memhandle == 0)
		error("ALLOCATE_MEMORY returned handle 0");
	buf[0] = 7*4; buf[1] = 0; buf[2] = Taglock; buf[3] = 4;
	buf[4] = 0; buf[5] = v3d.memhandle; buf[6] = 0;
	if(mboxpropto(buf, (uvlong)1000*1000) < 0){
		v3dgpufree();
		error("LOCK_MEMORY was not answered");
	}
	v3d.memlockack = 1;
	v3d.membus = buf[5];
	v3d.memsize = size;
	v3d.memsrc = Memfirmware;
	if(v3d.membus == 0){
		v3dgpufree();
		error("LOCK_MEMORY returned bus address 0");
	}
	/*
	 * A BUS ADDRESS WITH NO ALIAS BITS IS NOT ONE, and believing a
	 * stub would fault the kernel rather than merely mislead it: the
	 * write path below derives an ARM address from this, so a
	 * returned 0x1000 -- which is what QEMU answers -- becomes
	 * 0xc0001000, unmapped, and the copy into it takes the board
	 * down. The emulator's own answer is the reason this check
	 * exists, found before the image went near hardware.
	 */
	if((v3d.membus & 0xc0000000) == 0){
		u32 bad = v3d.membus;

		v3dgpufree();
		v3d.membus = 0;
		error("LOCK_MEMORY returned an address with no alias bits");
		USED(bad);
	}
	return 0;
}

/*
 * FORCE THE GPU PATH TO RUN WITHOUT A GPU ALLOCATION.
 *
 * The block above only executes when LOCK_MEMORY returns an address
 * with alias bits, and QEMU returns 0x1000, which the guard refuses.
 * So on an emulator that path never runs -- and its first execution
 * would otherwise be on somebody else's board, where a mistake in the
 * offset arithmetic is an unmapped write and a dead kernel rather than
 * a wrong number.
 *
 * `gpufake' points membus at a static block of this driver's own,
 * through the same alias, which is a mapped address because the
 * non-GPU path already writes through it. The arithmetic, the offsets
 * and the control-list contents are then exercised exactly as they
 * will be on hardware; only the provenance of the address differs.
 * `dump' reads the block back so the layout can be checked rather than
 * assumed.
 *
 * It is not a substitute for the real thing. What it tests is this
 * file's arithmetic, not whether a QPU can fetch from there.
 */
static u32 v3dfake[1024];

static int
v3dgpufake(void)
{
	v3dgpufree();
	v3d.memhandle = 0;
	v3d.membus = (u32)((uintptr)v3dfake | Busalias);
	v3d.memsize = sizeof v3dfake;
	v3d.memsrc = Memfake;
	v3d.memtried = 0;	/* no firmware was asked anything */
	v3d.memallocack = 0;
	v3d.memlockack = 0;
	return 0;
}

/*
 * Read the V3D's own identity. See the hazard note at V3dbase: this is
 * deliberately not reachable by accident.
 */
static int
v3dident(int nwords)
{
	u32 *r = (u32*)(uintptr)V3dbase;
	int i;

	if(nwords < 1)
		nwords = 1;
	if(nwords > 3)
		nwords = 3;
	/*
	 * One read per iteration with the marker set first.  If the
	 * access stalls, identtried names the word that did it and
	 * everything below here never runs.
	 */
	for(i = 0; i < nwords; i++){
		v3d.identtried = i + 1;
		v3d.ident[i] = r[V3dident0 + i];
		v3d.identread = i + 1;
	}
	return 0;
}

/*
 * Submit a QPU program through the V3D user shader request queue,
 * bypassing the firmware's EXECUTE_QPU entirely.
 *
 * WHAT EACH OUTCOME MEANS, written before the first run so that the
 * reading is not chosen after seeing the number:
 *
 *   completed count rises by one, queued stays 0   the QPU RAN IT
 *   queued stuck nonzero                           dispatched and never
 *                                                  finished -- the same
 *                                                  shape as the mailbox
 *                                                  failure, one layer down
 *   errored field nonzero                          the hardware rejected
 *                                                  the request
 *   the whole word unchanged                       the write did not reach
 *                                                  the block, or SRQ is not
 *                                                  the dispatch path
 *   the board stops answering                      a wedge; hardreset, and
 *                                                  that is a result too
 *
 * SRQCS IS NOT WRITTEN BY THIS FUNCTION.  If it is write-to-clear, as
 * the architecture guide is remembered to say, then writing it between
 * the two reads would destroy the comparison this is built on.  Read,
 * submit, read.
 */
static void
v3dsrq(uvlong waitus)
{
	u32 *r = (u32*)(uintptr)V3dbase;
	u32 *m, pa, ubus, kbus;
	uvlong t0;
	int i;

	/*
	 * REFUSE UNLESS THE BLOCK WAS SEEN UNGATED IN THIS BOOT.  A
	 * stale `enable' from an earlier session cannot be trusted: the
	 * ungated state survives a JTAG boot and does not survive
	 * hardreset, so the only safe evidence is an IDENT0 read that
	 * returned the right word since this kernel started.  Writing a
	 * program counter into a gated block is how the mailbox path is
	 * believed to have wedged.
	 */
	if(v3d.ident[0] != Identv3d)
		error("srq: IDENT0 has not read 0x02443356 in this boot -- `enable' then `ident force' first");
	if(v3d.memhandle == 0 || v3d.membus == 0 || (v3d.membus & Busalias) == 0)
		error("srq: no firmware GPU memory -- `gpualloc' first");
	if(v3d.ncode == 0)
		error("srq: no code loaded -- `code ...' first");
	if(2*4 + sizeof v3d.unif + v3d.ncode > v3d.memsize)
		error("srq: code and uniforms do not fit the allocation");

	pa = v3d.membus & ~Busalias;
	if(pa == 0 || pa + v3d.memsize > BCMPERIPH)
		error("srq: gpu memory is not in RAM this kernel maps");
	m = (u32*)(uintptr)pa;

	/*
	 * The same layout v3dexecraw writes, and duplicated rather than
	 * factored out on purpose: that function is the one path with
	 * measurements attached to it in doc/qpu-plan.ms, and a
	 * refactor shared with it would put those measurements in doubt
	 * for the sake of eight lines.
	 */
	ubus = v3d.membus + 2*4;
	kbus = v3d.membus + 2*4 + sizeof v3d.unif;
	for(i = 0; i < 4; i++)
		m[2 + i] = v3d.unif[i];
	memmove((uchar*)m + 2*4 + sizeof v3d.unif, v3d.code, v3d.ncode);
	m[0] = ubus;
	m[1] = kbus;
	cacheflush(m, 2*4 + sizeof v3d.unif + v3d.ncode);

	v3d.srqcs0 = r[V3dsrqcs];
	v3d.srqpc0 = r[V3dsrqpc];

	/*
	 * Flush the GPU's caches between the write and the dispatch,
	 * exactly as Linux does before a job.  The ARM's own cacheflush
	 * above does not touch these.
	 */
	r[V3dl2cactl] = L2cclr;
	r[V3dslcactl] = Slcflushall;

	/*
	 * Uniforms first, then the program counter LAST, because writing
	 * SRQPC is what queues the request -- the other two have to be
	 * in place before it.  SRQUL is nonzero even though `thrend plus
	 * two nops' reads no uniforms, because the scheduler reads these
	 * when it dispatches and a null uniform pointer is one of the
	 * two plausible reasons the firmware path hangs.  Its UNITS ARE
	 * NOT VERIFIED: 4 is a small nonzero value and is recorded as a
	 * guess, not a fact.
	 */
	r[V3dsrqua] = ubus;
	r[V3dsrqul] = 4;
	r[V3dsrqpc] = kbus;
	v3d.srqtried = 1;

	t0 = todget(nil);
	for(;;){
		v3d.srqcs1 = r[V3dsrqcs];
		if(v3d.srqcs1 != v3d.srqcs0)
			break;
		if(todget(nil) - t0 > waitus){
			v3d.srqtimeout = 1;
			break;
		}
	}
	v3d.srqus = todget(nil) - t0;
	v3d.srqcs2 = r[V3dsrqcs];
	for(i = 0; i < nelem(v3d.srqblk); i++)
		v3d.srqblk[i] = m[i];
}

static Chan*
v3dattach(char *spec)
{
	return devattach(L'Q', spec);
}

static Walkqid*
v3dwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, v3ddir, nelem(v3ddir), devgen);
}

static int
v3dstat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, v3ddir, nelem(v3ddir), devgen);
}

static Chan*
v3dopen(Chan *c, uint omode)
{
	return devopen(c, omode, v3ddir, nelem(v3ddir), devgen);
}

static void
v3dclose(Chan *c)
{
	USED(c);
}

static int
v3dread(Chan *c, void *a, int n, vlong offset)
{
	/*
	 * 1024, not 256. The status grew to ten lines and snprint
	 * truncated it mid-word -- `gpumem ... size 4096 c' -- so the
	 * ctlbus and block fields, added to make the GPU path checkable,
	 * were silently dropped by the very read meant to check them.
	 * Second time in a day: `render types' in libtk stopped after
	 * eight of seventeen widget types for the same reason, and read
	 * as a fact about widgets.
	 *
	 * Measured rather than counted: the same format fed the widest
	 * value every conversion can take is 642 bytes, so there are 381
	 * spare.  And the check below fires rather than relying on that
	 * number staying true -- adding a field is exactly the moment the
	 * comment goes stale, and a truncated status is invisible in its
	 * own output.
	 */
	char buf[1024];
	int nb;

	switch((ulong)c->qid.path){
	case Qdir:
		return devdirread(c, a, n, v3ddir, nelem(v3ddir), devgen);
	case Qctl:
		/*
		 * `enabled' is the last enable we believe SUCCEEDED, so
		 * after a refusal it still reads 1 -- which looked like a
		 * contradiction when a refused enable was followed by
		 * `enabled 1' on the next line. The attempt is now reported
		 * separately, because a stale truth beside a fresh error is
		 * worse than either alone.
		 */
		nb = snprint(buf, sizeof buf,
			"clock %s %ud\nenabled %d\nenable %s\n"
			"code %d bytes (appended; `reset' clears)\n"
			"args %#ux %#ux %#ux %#ux ctlidx %d\n"
			"exec %s code %#ux tag %#ux %s wrote %ud bytes %llud us\n"
			"wait %s after %llud us (asked %llud)\n"
			"gpumem %s handle %#ux bus %#ux size %d ctlbus %#ux\n"
			"gpualloc %s alloc %s lock %s\n"
			"block %#ux %#ux %#ux %#ux %#ux %#ux\n"
			"srq %s cs %#ux -> %#ux (final %#ux) pc0 %#ux %llud us\n"
			"srqblk %#ux %#ux %#ux %#ux %#ux %#ux\n"
			"ident %s tried %d read %d %#ux %#ux %#ux\n"
			"value %#ux %#ux %#ux %#ux\n",
			v3d.clockok? "hz" : "unknown", v3d.clock,
			v3d.enabled,
			!v3d.enabletried? "untried" :
				v3d.enableok? "accepted" : "REFUSED",
			v3d.ncode,
			v3d.lastargs[0], v3d.lastargs[1],
			v3d.lastargs[2], v3d.lastargs[3], v3d.lastctlidx,
			v3d.lastok? "accepted" : "refused",
			v3d.lastcode, v3d.lasttag,
			(v3d.lasttag & 0x80000000)? "PROCESSED" : "UNTOUCHED",
			v3d.lasttag & 0x7fffffff,
			v3d.lastus,
			v3d.lastwait == 0? "answered" :
			  v3d.lastwait == -1? "OUT OF TIME (no reply)" :
			  "COUNTER NOT ADVANCING",
			v3d.lastwaitused, v3d.lastwaitus,
			v3d.memsrc == Memfirmware? "firmware" :
			  v3d.memsrc == Memfake? "FAKE (this driver's own block)" :
			  "none",
			v3d.memhandle, v3d.membus, v3d.memsize, v3d.ctlbus,
			v3d.memtried? "tried" : "never tried",
			v3d.memallocack? "answered" : "no reply",
			v3d.memlockack? "answered" : "no reply",
			v3d.blk[0], v3d.blk[1], v3d.blk[2],
			v3d.blk[3], v3d.blk[4], v3d.blk[5],
			/*
			 * Three states, not the two this used to offer.
			 *
			 * The one silicon reading that reached V3D read
			 * 0x3fc00000 over JTAG and got DEADBEEF THREE
			 * TIMES, with openocd exiting 0, no abort, and the
			 * board still running afterwards -- so that access
			 * did not stall, and "unknown" below is the branch
			 * it takes.  Whether those are three real reads of
			 * an undriven block or the debugger's filler for an
			 * access that silently did nothing is OPEN.  The
			 * discriminator would be an address whose failed
			 * read is already characterised; the one tried was
			 * a peripheral hole, and it damaged cpu0 rather
			 * than failing cleanly, so it is disqualified.
			 *
			 * STALLED is kept because the access is
			 * undemonstrated rather than shown safe.  If one
			 * ever does stall, nothing in this kernel runs
			 * again to print anything -- identtried is set
			 * before the read and identread after it, so a
			 * halted target read over JTAG says which word
			 * died.
			 */
			/*
			 * SRQ, and the word is reported RAW on purpose:
			 * SRQCS's field layout is not in the only copy of
			 * the register definitions on this disk, so a
			 * decoded "completed count" here would be the kind
			 * of number that looks right while being wrong.
			 * `moved' says the register changed and nothing
			 * more; what it changed to is for a reader with the
			 * architecture guide.
			 */
			!v3d.srqtried? "untried" :
			  v3d.srqtimeout? "OUT OF TIME (cs unchanged)" :
			  "moved",
			v3d.srqcs0, v3d.srqcs1, v3d.srqcs2, v3d.srqpc0,
			v3d.srqus,
			v3d.srqblk[0], v3d.srqblk[1], v3d.srqblk[2],
			v3d.srqblk[3], v3d.srqblk[4], v3d.srqblk[5],
			!v3d.identtried? "untried" :
			  v3d.identread < v3d.identtried? "STALLED" :
			  (v3d.ident[0] == 0x02443356? "V3D" :
			   v3d.ident[0] == 0? "ZERO (block off?)" : "unknown"),
			v3d.identtried, v3d.identread,
			v3d.ident[0], v3d.ident[1], v3d.ident[2],
			v3d.lastval[0], v3d.lastval[1],
			v3d.lastval[2], v3d.lastval[3]);
		/*
		 * snprint stops at the limit and says nothing, so the only
		 * sign of a cut status is this.  libkern's vsnprint returns
		 * `f.to - buf' with f.stop at buf+len-1, so a truncated call
		 * returns exactly sizeof buf - 1 and this is the precise
		 * test rather than an approximation of one.
		 *
		 * A status that came to exactly that length without being
		 * cut would warn falsely.  It cannot here -- the widest
		 * every conversion can be is 642 -- and an over-warning is
		 * the right way round: a spurious line in a diagnostic file
		 * costs a moment, and a silently halved status cost this
		 * file two of its fields and a day.
		 *
		 * It is a read of a diagnostic file in process context, so
		 * a print here is safe and reaches whoever is reading.
		 */
		if(nb >= sizeof buf - 1)
			print("devv3d: status TRUNCATED at %d bytes;"
				" grow buf[%ud]\n", nb, (u32)sizeof buf);
		return readstr((ulong)offset, a, n, buf);
	}
	error(Eperm);
	return 0;
}

static int
v3dwrite(Chan *c, void *a, int n, vlong offset)
{
	Cmdbuf *cb;
	int i;

	USED(offset);
	switch((ulong)c->qid.path){
	case Qctl:
		cb = parsecmd(a, n);
		if(waserror()){
			free(cb);
			nexterror();
		}
		if(cb->nf < 1)
			error(Ebadctl);
		if(strcmp(cb->f[0], "reset") == 0){
			lock(&v3dlk);
			v3d.ncode = 0;
			unlock(&v3dlk);
		}else if(strcmp(cb->f[0], "code") == 0){
			/*
			 * code W0 [W1 ...] -- append instruction words
			 * written as TEXT.
			 *
			 * /dev/v3dcode takes raw bytes, so only a program
			 * can load code there, and that made the hypothesis
			 * battery depend on a Limbo command being present.
			 * It was not: a run that JTAG-booted this kernel
			 * while the board served ANOTHER tree's /dis over
			 * styx got `sh: qputry: file does not exist', no
			 * exec was ever sent, and the unchanged status
			 * afterwards read exactly like the question being
			 * answered rather than never asked.  With this the
			 * battery needs nothing but this device.
			 */
			if(cb->nf < 2)
				error("usage: code W0 [W1 ...]");
			lock(&v3dlk);
			if(waserror()){
				unlock(&v3dlk);
				nexterror();
			}
			if(v3d.ncode % 4 != 0)
				error("code is not a whole number of words; `reset' first");
			if(v3d.ncode + (cb->nf - 1)*4 > Codemax)
				error("code too large");
			for(i = 1; i < cb->nf; i++)
				((u32*)v3d.code)[v3d.ncode/4 + i - 1] =
					(u32)strtoul(cb->f[i], nil, 0);
			v3d.ncode += (cb->nf - 1)*4;
			poperror();
			unlock(&v3dlk);
		}else if(strcmp(cb->f[0], "clock") == 0){
			if(v3dclock() < 0)
				error("the firmware refused GET_CLOCK_RATE");
		}else if(strcmp(cb->f[0], "enable") == 0){
			if(v3denable(1) < 0)
				error("the firmware refused SET_ENABLE_QPU");
		}else if(strcmp(cb->f[0], "disable") == 0){
			if(v3denable(0) < 0)
				error("the firmware refused SET_ENABLE_QPU");
		}else if(strcmp(cb->f[0], "exec") == 0){
			/* exec ctlidx w0 w1 w2 w3 [waitms] */
			if(cb->nf < 6)
				error("usage: exec ctlidx w0 w1 w2 w3 [waitms]");
			v3dexecraw(strtol(cb->f[1], nil, 0),
				strtoul(cb->f[2], nil, 0),
				strtoul(cb->f[3], nil, 0),
				strtoul(cb->f[4], nil, 0),
				strtoul(cb->f[5], nil, 0),
				cb->nf > 6?
				  (uvlong)strtoul(cb->f[6], nil, 0)*1000 :
				  (uvlong)1000*1000);
		}else if(strcmp(cb->f[0], "gpualloc") == 0){
			v3dgpualloc(cb->nf > 1?
				strtol(cb->f[1], nil, 0) : 4096);
		}else if(strcmp(cb->f[0], "ident") == 0){
			/*
			 * ident force [nwords]
			 *
			 * The force is PRUDENCE AND NOT A MEASUREMENT,
			 * which is the honest standing of this.  A read of
			 * a block whose clock this driver never sets is not
			 * known to be safe; the one silicon reading that
			 * reached it came back fine, and one success does
			 * not make an access safe when the failure mode
			 * under discussion costs a power cycle.
			 *
			 * An earlier report that this read STALLED THE BUS
			 * was retracted: the wedge in that run came from a
			 * different address in the same script -- a
			 * peripheral hole, which aborted, ended the script
			 * before its resume, and left cpu0 unable to
			 * execute debug opcodes.  So nothing here rests on
			 * that, and the force stays because the cost of
			 * being wrong is asymmetric, not because a stall
			 * was shown.
			 */
			if(cb->nf < 2 || strcmp(cb->f[1], "force") != 0)
				error("ident reads a block whose clock is never set; not shown safe, and a wedge costs a power cycle -- say `ident force [nwords]'");
			v3dident(cb->nf > 2? (int)strtol(cb->f[2], nil, 0) : 1);
		}else if(strcmp(cb->f[0], "srq") == 0){
			/* srq [waitms] -- dispatch through the V3D registers */
			v3dsrq(cb->nf > 1?
				(uvlong)strtoul(cb->f[1], nil, 0)*1000 :
				(uvlong)100*1000);
		}else if(strcmp(cb->f[0], "gpufake") == 0){
			v3dgpufake();
		}else if(strcmp(cb->f[0], "gpufree") == 0){
			v3dgpufree();
		}else if(strcmp(cb->f[0], "tag") == 0){
			/* tag TAG valbytes [w0 [w1 [w2 [w3]]]] [-- waitms] */
			if(cb->nf < 3)
				error("usage: tag TAG valbytes [w0..w3]");
			v3dtag(strtoul(cb->f[1], nil, 0),
				strtol(cb->f[2], nil, 0),
				cb->nf > 3? strtoul(cb->f[3], nil, 0) : 0,
				cb->nf > 4? strtoul(cb->f[4], nil, 0) : 0,
				cb->nf > 5? strtoul(cb->f[5], nil, 0) : 0,
				cb->nf > 6? strtoul(cb->f[6], nil, 0) : 0,
				(uvlong)1000*1000);
		}else
			error(Ebadctl);
		poperror();
		free(cb);
		return n;
	case Qcode:
		/*
		 * Appended at the running offset, like the wifi firmware
		 * path, so a program can be cp'd in. `reset' first.
		 */
		lock(&v3dlk);
		if(v3d.ncode + n > Codemax){
			unlock(&v3dlk);
			error("code too large");
		}
		memmove((uchar*)v3d.code + v3d.ncode, a, n);
		v3d.ncode += n;
		unlock(&v3dlk);
		return n;
	}
	error(Eperm);
	return 0;
}

Dev v3ddevtab = {
	L'Q',
	"v3d",

	devreset,
	devinit,
	devshutdown,
	v3dattach,
	v3dwalk,
	v3dstat,
	v3dopen,
	devcreate,
	v3dclose,
	v3dread,
	devbread,
	v3dwrite,
	devbwrite,
	devremove,
	devwstat
};
