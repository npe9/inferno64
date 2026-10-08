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
 * AND EXECUTE_QPU DOES SOMETHING REAL. Nine bytes of garbage:
 *
 *	QEMU     elapsed      16 us
 *	silicon  elapsed 1050951 us
 *
 * 65000x. THAT IS THE ONLY PART OF THE ORIGINAL READING THAT SURVIVED,
 * and it survived because it is a clock: everything else in the first
 * version of this block was wrong, in three different ways, and all
 * three were found by the raspi3b-port session running it on silicon.
 *
 * ONE: `resp' WAS THIS DRIVER'S OWN INPUT, ECHOED. lastresp was
 * buf[5] read unconditionally, while the control-list address is
 * written to buf[5+ctlidx] -- so at ctlidx 0 the "response" was the
 * address written one line earlier and otherwise it was w0. Every
 * `resp 0x1' printed here, in the QEMU table and the silicon table
 * alike, was w0 == 1 coming back. The control: send 0xdeadbeef, read
 * 0xdeadbeef; send 0x5a5a5a5a, read 0x5a5a5a5a. So a reading rule this
 * file used to state -- "elapsed ~= 0, resp 0 -> the firmware did
 * nothing" -- could never have fired, because resp is never 0 unless
 * w0 is.
 *
 * The firmware's verdict was in two words this driver discarded, and
 * the status now prints them. buf[1] is the mailbox code; buf[4] is
 * the TAG's response -- bit 31 set means the tag was processed, the low
 * bits are the byte count written. **buf[4] == 0 means EXECUTE_QPU was
 * never touched**, which is the single question this instrument exists
 * to answer and was the one thing it was not reading.
 *
 * And the byte count is as important as the bit, which the first fix
 * nearly missed. QEMU now reads:
 *
 *	exec accepted code 0x80000000 tag 0x80000000 PROCESSED
 *	     wrote 0 bytes 17 us
 *	value 0x1 0xc0310970 0x3e8 0x0
 *
 * Processed, and wrote NOTHING, with the value buffer still holding
 * exactly what was sent. That is the stub's signature stated properly,
 * where before it was hidden behind an echoed `resp 0x1' that looked
 * like an answer. On silicon a real EXECUTE_QPU should set the bit AND
 * a nonzero length, and value[0] should then be the firmware's own
 * return rather than w0.
 *
 * TWO: ~1.05s IS NOT A FIXED COST. This block asserted it was. Three
 * levels have now been seen for the same command shape across kernel
 * builds: 1.0509s, ~0.83s and ~1.14s (n=13). The level moves between
 * builds, so "a fixed cost in the firmware's EXECUTE_QPU path" is not
 * supported, and the 0.83s is unattributed -- not ctlidx, not w3, not
 * thermal.
 *
 * THREE: the four-word sweep that appeared here is WITHDRAWN. Its
 * driver built the command with an Inferno sh list subscript, which
 * does not exist, so every row ran at ctlidx 0 and three of the four
 * words were never varied at all. Done properly and interleaved,
 * ctlidx does not move the elapsed time either: 1127699..1163585 us
 * across all four indices, ranges overlapping, 3.1% spread.
 *
 * SO THE LAYOUT IS STILL UNKNOWN, and the honest state is narrower
 * than this file once claimed: a garbage program takes ~1s of
 * something on silicon and microseconds under emulation, and nothing
 * yet identifies which argument word is which. The next run should
 * read buf[4] first -- if the tag was never processed, every elapsed
 * time measured so far is the cost of a rejected request and not of
 * anything executing.
 *
 * (Silicon numbers measured by the raspi3b-port session on the board,
 * against this device as of b54afb448, which was on the card after the
 * tree copy had been reverted -- reverting a tree and reverting a card
 * are two acts.)
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
	uvlong	lastus;		/* how long it took */
	u32	clock;
	int	clockok;
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
v3dexecraw(int ctlidx, u32 w0, u32 w1, u32 w2, u32 w3)
{
	u32 *buf;
	uvlong t0;
	int i, nj;

	if(v3d.ncode <= 0)
		error("no code loaded");
	if(ctlidx < 0 || ctlidx > 3)
		error("ctlidx must be 0..3");
	nj = 1;

	/* one job: uniforms then code, both bus addresses */
	for(i = 0; i < nj && i < nelem(v3d.ctrl)/2; i++){
		v3d.ctrl[2*i]   = (u32)((uintptr)v3d.unif | Busalias);
		v3d.ctrl[2*i+1] = (u32)((uintptr)v3d.code | Busalias);
	}
	cacheflush(v3d.code, v3d.ncode);
	cacheflush(v3d.unif, sizeof v3d.unif);
	cacheflush(v3d.ctrl, sizeof v3d.ctrl);

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
	buf[5+ctlidx] = (u32)((uintptr)v3d.ctrl | Busalias);
	buf[9] = 0;
	for(i = 0; i < 4; i++)
		v3d.lastargs[i] = buf[5+i];
	v3d.lastctlidx = ctlidx;
	t0 = systmrusec();
	v3d.lastok = mboxprop(buf) >= 0;
	v3d.lastus = systmrusec() - t0;
	v3d.lastcode = buf[1];
	v3d.lasttag = buf[4];
	for(i = 0; i < 4; i++)
		v3d.lastval[i] = buf[5+i];
	return 0;
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
	char buf[256];

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
		snprint(buf, sizeof buf,
			"clock %s %ud\nenabled %d\nenable %s\n"
			"code %d bytes (appended; `reset' clears)\n"
			"args %#ux %#ux %#ux %#ux ctlidx %d\n"
			"exec %s code %#ux tag %#ux %s wrote %ud bytes %llud us\n"
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
			v3d.lastval[0], v3d.lastval[1],
			v3d.lastval[2], v3d.lastval[3]);
		return readstr((ulong)offset, a, n, buf);
	}
	error(Eperm);
	return 0;
}

static int
v3dwrite(Chan *c, void *a, int n, vlong offset)
{
	Cmdbuf *cb;

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
			/* exec ctlidx w0 w1 w2 w3 -- all four words raw */
			if(cb->nf < 6)
				error("usage: exec ctlidx w0 w1 w2 w3");
			v3dexecraw(strtol(cb->f[1], nil, 0),
				strtoul(cb->f[2], nil, 0),
				strtoul(cb->f[3], nil, 0),
				strtoul(cb->f[4], nil, 0),
				strtoul(cb->f[5], nil, 0));
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
