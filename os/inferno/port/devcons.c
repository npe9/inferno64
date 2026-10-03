#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	<version.h>
#include	"mp.h"
#include	"libsec.h"
#include	"keyboard.h"

extern int cflag;
extern int keepbroken;
extern int rdbstarted;
extern u32 kerndate;

void	(*serwrite)(char *, int);

void	(*consdebug)(void) = nil;
void	(*screenputs)(char*, int) = nil;

Queue*	serialoq;		/* serial console output */
Queue*	kprintoq;		/* console output, for /dev/kprint */
ulong	kprintinuse;	/* test and set whether /dev/kprint is open */
int	iprintscreenputs = 1;

int	panicking;

/* below until kbdfs */
int mouseshifted;
Queue*  kbdq;                   /* unprocessed console input */
Queue*  lineq;                  /* processed console input */
Queue*	gkbdq;			/* graphics /dev/keyboard input */
static struct
{
        QLock;

        int     raw;            /* true if we shouldn't process input */
        int     ctl;            /* number of opens to the control file */
        int     kbdr;           /* number of open reads to the keyboard */
        int     scan;           /* true if reading raw scancodes */
        int     x;              /* index into line */
        char    line[1024];     /* current input line */

        char    c;
        int     count;
        int     repeat;
} kbd;
/* above until kbdfs */

char*	sysname;
char	*sysname;
vlong	fasthz;

static int	readtime(ulong, char*, int);
static int	readbintime(char*, int);
static int	writetime(char*, int);
static int	writebintime(char*, int);

extern ulong	hzschedcalls, reschedraised, reschedtaken;	/* proc.c */
extern ulong	sleepacqticks, sleepacqn, sleepacqmax;
extern ulong	sleeptsticks, sleeptsmax, sleeprelticks;
extern ulong	sleeprqticks, sleeprqmax;
extern ulong	reschedhigher, reschedquantum, lastuppri, lastrunvec, wokepri;
extern int	sleeptrace;
extern ulong	ticknoup, ticknotrun, tickrun;
extern ulong	tickhipri, tickuphi, tickanyhi;
extern ulong	gcticks, gcpasses, gcmax, idlegcticks, idlegcmax;
/*
 * Whether THIS board's code generator emits atomic reference counts,
 * declared by each libinterp/comp-*.c.  Reported beside the collector's
 * own counters because that is what it is about, and with cflag because
 * the answer only matters when the generator is actually in use.
 */
extern int	jitrefsatomic;
extern ulong	delayedscheds, skipscheds, preempts;
extern int	ioboost, coopsched, schedgate, schedclock;
extern int	gchalt, gcdepth, gcdepthmax;		/* libinterp/gc.c */
extern ulong	gcnruns, gcsweeps, gcepochs, gchalted, gcinxecseen;
extern ulong	gcbroken;
extern uvlong	gcdestroys, gcinspects;
extern ulong	gcstwstops, gcstwwaits, gcstwfails;	/* port/dis.c */
extern ulong	nrunqother, nrunqdel;			/* port/dis.c */
extern int	lockboost;

extern int	ilocktrace;		/* taslock.c */
extern ulong	nilocktraced;
extern long	maxilockcycles, cumilockcycles;
extern uintptr	maxilockpc;

enum
{
	CMreboot,
	CMhalt,
	CMpanic,
	CMbroken,
	CMnobroken,
	CMconsole,
	CMrdb,
	CMprocdump,
	CMilock,
	CMsched,
};

/*
 * Every process, one line each (procdump() would add its whole
 * namespace, which a serial console cannot carry), and for each one
 * that is not running, the kernel text addresses on
 * its kernel stack above the saved sp, innermost first.  Not a real
 * backtrace -- any word that looks like a text address is printed --
 * but on a stripped kernel it is what says where a sleeping kproc is
 * sleeping; a 7l -a listing of the same build turns the numbers into
 * names.
 */
void
kstackdump(void)
{
	extern char etext[];
	Proc *p;
	uintptr l, e, v;
	int i, n;

	for(i = 0; i < conf.nproc; i++){
		p = proctab(i);
		if(p->state == Dead)
			continue;
		dumpaproc(p);
		if(p->state == Queueing && p->qwaitq != nil)
			print("\tqlock %#p held by %ud acquired at %#p\n",
				p->qwaitq, p->qwaitq->owner != nil? p->qwaitq->owner->pid: 0,
				p->qwaitq->opc);
		if(p == up || p->kstack == nil)
			continue;
		l = p->sched.sp;
		e = (uintptr)p->kstack + KSTACK;
		if(l < (uintptr)p->kstack || l >= e)
			continue;
		print("\t");
		n = 0;
		for(; l < e && n < 16; l += sizeof(uintptr)){
			v = *(uintptr*)l;
			if(v > (uintptr)KTZERO && v < (uintptr)etext){
				print(" %#p", v);
				n++;
			}
		}
		print("\n");
	}
}

/*
 * ^\ on the console asks for that dump.
 *
 * A wedged board cannot be asked anything through a file: writing
 * /dev/sysctl needs a shell, and the shell is one of the things that
 * has stopped.  The console's own receive path still runs -- every
 * character typed is still echoed -- so that is where the question has
 * to go in.  ^\ is the file separator, which nothing here types and no
 * terminal sends by accident.
 */
static Rendez	dumpr;
static int	dumpwanted;

static int
dumpready(void*)
{
	return dumpwanted;
}

static void
consdumpproc(void*)
{
	for(;;){
		sleep(&dumpr, dumpready, nil);
		dumpwanted = 0;
		print("\n^\\ every process:\n");
		kstackdump();
	}
}

/*
 * Called from the console receive path with every character.  Returns
 * 1 if it was a debug request and should not reach the keyboard queue.
 */
int
consdebugchar(int ch)
{
	extern void consinterrupt(void);
	extern void archreboot(void);

	if(ch == 0x12){		/* ^R: reboot, from here, now */
		/*
		 * The last resort, and it exists because the other two are
		 * not enough.  ^C kills what the console is running but
		 * spares the shell, so a shell that is itself stuck -- in
		 * a mount whose server has panicked, which is what a dosfs
		 * panic leaves behind -- keeps echoing and never runs
		 * another command.  "echo reboot >/dev/sysctl" needs that
		 * same shell.  So the machine could only be recovered by
		 * pulling its power, and on this board that has twice
		 * meant pulling the card as well.
		 *
		 * This is not a clean shutdown and does not pretend to be:
		 * nothing is flushed, no server is told.  It is the reset
		 * the watchdog drives, taken directly from the console's
		 * receive path, which is the one piece of this machine
		 * still running when everything above it has stopped.
		 */
		iprint("\n^R: reboot\n");
		archreboot();
		return 1;
	}
	if(ch == 0x03){		/* ^C: kill what the console is running */
		consinterrupt();
		return 1;
	}
	if(ch != 0x1c)		/* ^\ */
		return 0;
	dumpwanted = 1;
	wakeup(&dumpr);
	return 1;
}

static Cmdtab sysctlcmd[] =
{
	CMreboot,	"reboot",	0,
	CMhalt,	"halt", 0,
	CMpanic,	"panic", 0,
	CMconsole,	"console", 1,
	CMbroken,	"broken", 0,
	CMnobroken,	"nobroken", 0,
	CMrdb,		"rdb",		0,
	CMprocdump,	"procdump",	0,
	CMilock,	"ilock",	0,
	CMsched,	"sched",	0,
};

Cmdtab rebootmsg[] =
{
	CMreboot,	"reboot",	0,
	CMpanic,	"panic",	0,
	CMrdb,		"rdb",		0,
};

void
printinit(void)
{
}

static int
consactive(void)
{
	if(serialoq)
		return qlen(serialoq) > 0;
	return 0;
}

static void
prflush(void)
{
	ulong now;

	now = m->ticks;
	while(consactive())
		if(m->ticks - now >= HZ)
			break;
}

/*
 * The ring, without the lock, for iprint() and panic().
 *
 * WHY THIS EXISTS.  iprint() writes screenputs and uartputs and nothing
 * else, so nothing it prints reaches the kmesg ring -- and panic() prints
 * through iprint().  On a board whose console is dead, and this one's has
 * been for months, a panic is therefore completely invisible: the ring
 * that tools/jtag/kmesg reads out of RAM holds every ordinary print and
 * not one word of the fault that stopped the machine.  That is exactly
 * backwards, and it cost an afternoon on a kernel that panicked three
 * times in a row while the only evidence available was which print it had
 * reached before the shutdown sequence.
 *
 * WHY WITHOUT THE LOCK.  iprint() runs at splhi and is the path a panic
 * takes, and panic() may be reached with kmesg.lk already held by this
 * same processor -- from inside kmesgputs itself, or from any print()
 * underneath it -- in which case ilock() spins for ever and the panic
 * never says anything at all.  A lock that can turn a diagnosable fault
 * into a silent hang is worse than a torn line of text.  So this is the
 * same arithmetic with no lock, and the cost is that a panic racing
 * another processor's print can interleave, which a panic may.
 */
static void
kmesgputsnl(char *str, int n)
{
	uint nn, d;

	if(n > sizeof kmesg.buf){
		d = n - sizeof kmesg.buf;
		str += d;
		n -= d;
	}
	nn = kmesg.n;
	if(nn + n >= sizeof kmesg.buf){
		d = nn + n - sizeof kmesg.buf;
		if(d)
			memmove(kmesg.buf, kmesg.buf+d, sizeof kmesg.buf-d);
		nn -= d;
	}
	memmove(kmesg.buf+nn, str, n);
	kmesg.n = nn + n;
}

static void
kmesgputs(char *str, int n)
{
	uint nn, d;

	ilock(&kmesg.lk);
	/* take the tail of huge writes */
	if(n > sizeof kmesg.buf){
		d = n - sizeof kmesg.buf;
		str += d;
		n -= d;
	}

	/* slide the buffer down to make room */
	nn = kmesg.n;
	if(nn + n >= sizeof kmesg.buf){
		d = nn + n - sizeof kmesg.buf;
		if(d)
			memmove(kmesg.buf, kmesg.buf+d, sizeof kmesg.buf-d);
		nn -= d;
	}

	/* copy the data in */
	memmove(kmesg.buf+nn, str, n);
	nn += n;
	kmesg.n = nn;
	iunlock(&kmesg.lk);
}

/*
 *   Print a string on the console.  Convert \n to \r\n for serial
 *   line consoles.  Locking of the queues is left up to the screen
 *   or uart code.  Messages from different processes may be
 *   interleaved with each other, but not within a line: putstrn0
 *   writes each line and its CRLF as a single qwrite so a second
 *   writer cannot land between a line's text and its newline.
 */
static void
putstrn0(char *str, int n, int usewrite)
{
	int m;
	char *t;
	int (*wq)(Queue*, void*, int);
	char lbuf[256];		/* one console line plus its CRLF */

	/*
	 *  how many different output devices do we need?
	 */
	kmesgputs(str, n);

	/*
	 *  if someone is reading /dev/kprint,
	 *  put the message there.
	 *  if not and there's an attached bit mapped display,
	 *  put the message there.
	 *
	 *  if there's a serial line being used as a console,
	 *  put the message there.
	 */
	wq = usewrite && islo() ? qwrite : qiwrite;
	if(kprintoq != nil && !qisclosed(kprintoq)){
		(*wq)(kprintoq, str, n);
	}else if(screenputs != nil){
		screenputs(str, n);
	}

	if(rdbstarted == 1)
		return;
	if(serialoq == nil){
		uartputs(str, n);
		return;
	}

	while(n > 0) {
		t = memchr(str, '\n', n);
		if(t != nil) {
			m = t-str;
			/*
			 * The line and its CRLF go out in one qwrite, not
			 * two.  qwrite sleeps when the queue is full, and a
			 * second writer that ran in between used to land
			 * inside the line: a boot with a USB stick and a USB
			 * NIC printed "DISK-DOS-OK /n/dos: usb.txt" and then
			 * another process's message before the newline that
			 * belonged to it.  The console line is the unit a log
			 * is read in -- and the unit the board suite's
			 * evidence lines match against -- so a line split in
			 * the middle is a real fault and not cosmetic.  A
			 * line too long for the buffer falls back to the two
			 * writes, which is no worse than it always was.
			 */
			if(m + 2 <= sizeof lbuf) {
				memmove(lbuf, str, m);
				lbuf[m] = '\r';
				lbuf[m+1] = '\n';
				(*wq)(serialoq, lbuf, m+2);
			} else {
				(*wq)(serialoq, str, m);
				(*wq)(serialoq, "\r\n", 2);
			}
			n -= m+1;
			str = t+1;
		} else {
			(*wq)(serialoq, str, n);
			break;
		}
	}
}

void
putstrn(char *str, int n)
{
	putstrn0(str, n, 0);
}

int
snprint(char *s, int n, char *fmt, ...)
{
	va_list arg;

	va_start(arg, fmt);
	n = vseprint(s, s+n, fmt, arg) - s;
	va_end(arg);

	return n;
}

int
sprint(char *s, char *fmt, ...)
{
	int n;
	va_list arg;

	va_start(arg, fmt);
	n = vseprint(s, s+PRINTSIZE, fmt, arg) - s;
	va_end(arg);

	return n;
}

int
print(char *fmt, ...)
{
	int n;
	va_list arg;
	char buf[PRINTSIZE];

	va_start(arg, fmt);
	n = vseprint(buf, buf+sizeof(buf), fmt, arg) - buf;
	va_end(arg);
	putstrn(buf, n);

	return n;
}

int
fprint(int fd, char *fmt, ...)
{
	int n;
	va_list arg;
	char buf[PRINTSIZE];

	USED(fd);
	va_start(arg, fmt);
	n = vseprint(buf, buf+sizeof(buf), fmt, arg) - buf;
	va_end(arg);
	putstrn(buf, n);

	return n;
}

/*
 * Want to interlock iprints to avoid interlaced output on 
 * multiprocessor, but don't want to deadlock if one processor
 * dies during print and another has something important to say.
 * Make a good faith effort.
 */
static Lock iprintlock;
static int
iprintcanlock(Lock *l)
{
	int i;
	
	for(i=0; i<1000; i++){
		if(canlock(l))
			return 1;
		if(l->m == MACHP(m->machno))
			return 0;
		microdelay(100);
	}
	return 0;
}

int
iprint(char *fmt, ...)
{
	int n, s, locked;
	va_list arg;
	char buf[PRINTSIZE];

	s = splhi();
	va_start(arg, fmt);
	n = vseprint(buf, buf+sizeof(buf), fmt, arg) - buf;
	va_end(arg);
	locked = iprintcanlock(&iprintlock);
	if(screenputs != nil && iprintscreenputs)
		screenputs(buf, n);
	uartputs(buf, n);
	kmesgputsnl(buf, n);	/* so a panic is visible without a console */
	if(locked)
		unlock(&iprintlock);
	splx(s);

	return n;
}

char panicmsg[256];		/* the last panic, for JTAG; see below */

void
panic(char *fmt, ...)
{
	int s;
	va_list arg;
	char buf[PRINTSIZE];

	kprintoq = nil;	/* don't try to write to /dev/kprint */

	if(panicking)
		for(;;);
	panicking = 1;

	s = splhi();
	strcpy(buf, "panic: ");
	va_start(arg, fmt);
	vseprint(buf+strlen(buf), buf+sizeof(buf), fmt, arg);
	va_end(arg);
	/*
	 * KEEP IT, as well as printing it.
	 *
	 * iprint puts this in the ring, and on this board the ring is the
	 * only post-mortem channel there is.  That is not enough: a panic
	 * does not stop the other processors, so whatever they print
	 * afterwards crowds it out.  It happened, and the irony is exact --
	 * the Dis wedge watchdog fires BECAUSE of a panic (the panicking
	 * process never releases the interpreter token) and its dump then
	 * destroys the panic message that explains why it fired.  Four
	 * floods have eaten evidence in this hunt and this is the one that
	 * cost most.
	 *
	 * A variable cannot be crowded out.  tools/jtag/vmheld reads this
	 * one, so the next panic is legible even if a thousand lines follow
	 * it.
	 */
	strncpy(panicmsg, buf, sizeof(panicmsg)-1);
	panicmsg[sizeof(panicmsg)-1] = 0;
	iprint("%s\n", buf);
	if(consdebug)
		(*consdebug)();
	splx(s);
	prflush();
	dumpstack();

	/* reboot cpu servers and headless machines when not debugging */
	if(getconf("*debug") == nil)
	if(!conf.monitor)
		exit(1);

	/* otherwise, just hang */
	while(islo()) idlehands();
	for(;;);
}

void
_assert(char *fmt)
{
	panic("assert failed at %#p: %s", getcallerpc(&fmt), fmt);
}

/*
 * mainly for libmp
 */
void
sysfatal(char *fmt, ...)
{
	char err[256];
	va_list arg;

	va_start(arg, fmt);
	vseprint(err, err + sizeof err, fmt, arg);
	va_end(arg);
	panic("sysfatal: %s", err);
}

int
pprint(char *fmt, ...)
{
	int n;
	Chan *c;
	va_list arg;
	char buf[2*PRINTSIZE];

	if(up == nil || up->fgrp == nil)
		return 0;

	c = up->fgrp->fd[2];
	if(c==nil || (c->flag&CMSG)!=0 || (c->mode!=OWRITE && c->mode!=ORDWR))
		return 0;
	n = snprint(buf, sizeof buf, "%s %ud: ", up->text, up->pid);
	va_start(arg, fmt);
	n = vseprint(buf+n, buf+sizeof(buf), fmt, arg) - buf;
	va_end(arg);

	if(waserror())
		return 0;
	devtab[c->type]->write(c, buf, n, c->offset);
	poperror();

	lock(c);
	c->offset += n;
	unlock(c);

	return n;
}

enum{
	Qdir,
	Qbintime,
	Qcons,
	Qconsctl,
	Qcputime,
	Qdrivers,
	Qhostdomain,
	Qhostowner,
	Qjit,
	Qkeyboard,
	Qkmesg,
	Qkprint,	/* tail of kprint's and cons. Why not just a tail of klog? Why is this needed? */
	Qmemory,
	Qilock,
	Qnull,
	Qosversion,
	Qpid,
	Qppid,
	Qrandom,
	Qnotquiterandom,
	Qreboot,
	Qscancode,
	Qsysctl,
	Qsysname,
	Qsysstat,
	Qtime,
	Quser,
	Qzero,
	Qconfig,
	Qmordor,
};

enum
{
	DOMLEN=		48,	/* authentication domain name length */
	VLNUMSIZE=	22,
};

static Dirtab consdir[]=
{
	".",	{Qdir, 0, QTDIR},	0,		DMDIR|0555,
	"bintime",	{Qbintime},	24,		0664,
	"cons",		{Qcons},	0,		0660,
	"consctl",	{Qconsctl},	0,		0220,
	"cputime",	{Qcputime},	6*NUMSIZE,	0444,
	"drivers",	{Qdrivers},	0,		0444,
	"hostdomain",	{Qhostdomain},	DOMLEN,		0664,
	"hostowner",	{Qhostowner},	0,	0644,
	"jit",		{Qjit},	0,	0666,					/* obsolete unless forth wants to use it */
	"keyboard",	{Qkeyboard},	0,		0666,
	"kmesg",	{Qkmesg},	0,		0440,
	"kprint",		{Qkprint},	0,		0444,
	"memory",	{Qmemory},	0,		0444,			/* not in 9front */
	"ilock",	{Qilock},	0,		0444,			/* not in 9front */
	"null",		{Qnull},	0,		0666,
	"osversion",	{Qosversion},	0,		0444,
	"pid",		{Qpid},		NUMSIZE,	0444,
	"ppid",		{Qppid},	NUMSIZE,	0444,
	"random",	{Qrandom},	0,		0444,
	"notquiterandom",	{Qnotquiterandom},	0,	0444,
	"reboot",	{Qreboot},	0,		0220,
	"scancode",	{Qscancode},	0,		0444,
	"sysctl",	{Qsysctl},	0,		0644,			/* obsoleted by reboot and osversion */
	"sysname",	{Qsysname},	0,		0664,
	"sysstat",	{Qsysstat},	0,		0664,
	"time",		{Qtime},	NUMSIZE+3*VLNUMSIZE,	0664,
	"user",		{Quser},	0,		0666,
	"zero",		{Qzero},	0,		0444,
	"config",	{Qconfig},	0,		0444,
	"mordor",	{Qmordor},	0,		0666,
};

ulong	boottime;		/* seconds since epoch at boot */

long
seconds(void)
{
	return boottime + TK2SEC(MACHP(0)->ticks);
}

/* TODO correct these. We are returning microseconds now */
vlong
mseconds(void)
{
	return ((vlong)boottime*1000)+((vlong)(TK2MS(MACHP(0)->ticks)));
}

vlong
osusectime(void)
{
	return (((vlong)boottime*1000)+((vlong)(TK2MS(MACHP(0)->ticks)))*1000);
}

vlong
nsec(void)
{
	return osusectime()*1000;	/* TO DO */
}

int
readnum(ulong off, char *buf, ulong n, ulong val, int size)
{
	char tmp[64];

	if(size > 64) size = 64;

	snprint(tmp, sizeof(tmp), "%*.0ld ", size, val);
	if(off >= size)
		return 0;
	if(off+n > size)
		n = size-off;
	memmove(buf, tmp+off, n);
	return n;
}

int
readstr(ulong off, char *buf, ulong n, char *str)
{
	int size;

	size = strlen(str);
	if(off >= size)
		return 0;
	if(off+n > size)
		n = size-off;
	memmove(buf, str+off, n);
	return n;
}

void
fddump()
{
	Proc *p;
	int i;
	Chan *c;

	p = proctab(6);
	for(i = 0; i <= p->fgrp->maxfd; i++) {
		if((c = p->fgrp->fd[i]) == nil)
			continue;
		print("%d: %s\n", i, c->path == nil? "???": c->path->s);
	}
}

static void
qpanic(Rune)
{
	panic("User requested panic.");
}

static void
rexit(Rune)
{
	exit(0);
}

static void
consinit(void)
{
	/* below until kbdfs is built */
	if(lineq == nil){
        lineq = qopen(2*1024, 0, nil, nil);
        if(lineq == nil)
                panic("consinit");
        qnoblock(lineq, 1);
	}
	if(kbdq == nil){
		kbdq = qopen(4*1024, 0, 0, 0);
		if(kbdq == nil)
			panic("consinit");
		qnoblock(kbdq, 1);
	}
	if(gkbdq == nil){
		gkbdq = qopen(4*1024, 0, 0, 0);
		if(gkbdq == nil)
			panic("consinit gkbdq");
		qnoblock(gkbdq, 1);
	}
	/* above until kbdfs is built */

	todinit();
	randominit();

	/*
	 * And a process to answer the console's debug key.  It is a
	 * kproc on purpose: when the Dis scheduler wedges -- which this
	 * board does, with the console still echoing every character and
	 * no program running again -- a kproc still runs, and it is the
	 * only thing left that can say what every process was doing.
	 * Doing it from the interrupt handler instead would take the
	 * print lock from interrupt context, which is how a debugging
	 * aid becomes the second fault.
	 */
	kproc("consdump", consdumpproc, nil, 0);
	/*
	 * And the one that does not need anybody watching.  Five wedges
	 * in two days were all found late or not at all, because ^\
	 * has to be typed by a person who notices.  dis.c says what it
	 * watches and why it only reports.
	 */
	{
		extern void diswatchproc(void*);

		kproc("diswatch", diswatchproc, nil, 0);
	}
	/*
	 * And one for ^C, for the same reason and with the same shape:
	 * killing a Dis program needs the interpreter acquired, which the
	 * console's receive path cannot do.  dis.c has it, because that
	 * is where the process groups are.
	 */
	{
		extern void consintrproc(void*);

		kproc("consintr", consintrproc, nil, 0);
	}
/*
	debugkey('f', "files/6", fddump, 0);
	debugkey('q', "panic", qpanic, 1);
	debugkey('r', "exit", rexit, 1);
*/
}

static Chan*
consattach(char *spec)
{
	return devattach('c', spec);
}

static Walkqid*
conswalk(Chan *c, Chan *nc, char **name, s32 nname)
{
	return devwalk(c, nc, name, nname, consdir, nelem(consdir), devgen);
}

static s32
consstat(Chan *c, uchar *dp, s32 n)
{
	return devstat(c, dp, n, consdir, nelem(consdir), devgen);
}

static void
flushkbdline(Queue *q)
{
	if(kbd.x){
		qwrite(q, kbd.line, kbd.x);
		kbd.x = 0;
	}
}

static Chan*
consopen(Chan *c, u32 omode)
{
	c->aux = nil;
	c = devopen(c, omode, consdir, nelem(consdir), devgen);
	switch((ulong)c->qid.path){
	case Qconsctl:
		if(!iseve()){
			print("consopen not eve\n");
			error(Eperm);
		}
		qlock(&kbd);
		kbd.ctl++;
		qunlock(&kbd);
		break;

	case Qkprint:
		if(tas(&kprintinuse) != 0){
			c->flag &= ~COPEN;
			error(Einuse);
		}
		if(kprintoq == nil){
			kprintoq = qopen(8*1024, Qcoalesce, 0, 0);
			if(kprintoq == nil){
				c->flag &= ~COPEN;
				error(Enomem);
			}
			qnoblock(kprintoq, 1);
		}else
			qreopen(kprintoq);
		c->iounit = qiomaxatomic;
		break;
	}
	return c;
}

static void
consclose(Chan *c)
{
	switch((ulong)c->qid.path){
	case Qconsctl:
		/* last close of control file turns off raw */
		qlock(&kbd);
		if(--kbd.ctl == 0)
			kbd.raw = 0;
		qunlock(&kbd);
		break;

	/* close of kprint allows other opens */
	case Qkprint:
		if(c->flag & COPEN){
			kprintinuse = 0;
			qhangup(kprintoq, nil);
		}
		break;
	}
}

static s32
consread(Chan *c, void *buf, s32 n, s64 offset)
{
	Proc *o;
	u32 l;
	Mach *mp;
	char *b, *bp;
	char tmp[256];
	int i, k, id;
	extern char configfile[];

	if(n <= 0)
		return n;
	o = up;
	switch((ulong)c->qid.path){

	case Qdir:
		return devdirread(c, buf, n, consdir, nelem(consdir), devgen);

	case Qsysctl:
		return readstr(offset, buf, n, VERSION);

	case Qkeyboard:
		return qread(gkbdq, buf, n);

	case Qcons:
		/* below belongs in kbdfs */
		qlock(&kbd);
		if(waserror()) {
			qunlock(&kbd);
			nexterror();
		}
		if(kbd.raw || kbd.kbdr) {
			if(qcanread(lineq))
				n = qread(lineq, buf, n);
			else {
				/* read as much as possible */
				char *cbuf = buf;
				do {
					i = qread(kbdq, cbuf, n);
					cbuf += i;
					n -= i;
				} while(n>0 && qcanread(kbdq));
				n = cbuf - (char*)buf;
			}
		} else {
			int ch, eol;
			while(!qcanread(lineq)) {
				qread(kbdq, &kbd.line[kbd.x], 1);
				ch = kbd.line[kbd.x];
				eol = 0;
				switch(ch){
					case '\b':
					case 0x7f:	/* what a terminal's backspace key sends */
						if(kbd.x)
						kbd.x--;
						break;
					case 0x15:
						kbd.x = 0;
						break;
					case '\n':
					case 0x04:
						eol = 1;
					default:
						kbd.line[kbd.x++] = ch;
						break;
				}
				if(kbd.x == sizeof(kbd.line) || eol) {
					if(ch == 0x04)
						kbd.x--;
					qwrite(lineq, kbd.line, kbd.x);
					kbd.x = 0;
				}
			}
			n = qread(lineq, buf, n);
		}
		qunlock(&kbd);
		poperror();
		return n;
		/* above belongs in kbdfs */
		/* commented until the above is removed
		error(Egreg); */

	case Qcputime:
		k = offset;
		if(k >= 6*NUMSIZE)
			return 0;
		if(k+n > 6*NUMSIZE)
			n = 6*NUMSIZE - k;
		/* easiest to format in a separate buffer and copy out */
		for(i=0; i<6 && NUMSIZE*i<k+n; i++){
			l = up->time[i];
			if(i == TReal)
				l = MACHP(0)->ticks - l;
			readnum(0, tmp+NUMSIZE*i, NUMSIZE, tk2ms(l), NUMSIZE);
		}
		memmove(buf, tmp+k, n);
		return n;

	case Qjit:
		snprint(tmp, sizeof(tmp), "%d", cflag);
		return readstr(offset, buf, n, tmp);

	case Qkmesg:
		/*
		 * This is unlocked to avoid tying up a process
		 * that's writing to the buffer.  kmesg.n never 
		 * gets smaller, so worst case the reader will
		 * see a slurred buffer.
		 */
		if(offset >= kmesg.n)
			n = 0;
		else{
			if(offset+n > kmesg.n)
				n = kmesg.n - offset;
			memmove(buf, kmesg.buf+offset, n);
		}
		return n;

	case Qkprint:
		return qread(kprintoq, buf, n);

	case Qpid:
		return readnum((ulong)offset, buf, n, up->pid, NUMSIZE);

	case Qppid:
		return readnum((ulong)offset, buf, n, up->parentpid, NUMSIZE);

	case Qtime:
		return readtime((ulong)offset, buf, n);

	case Qbintime:
		return readbintime(buf, n);

	case Qhostowner:
		return readstr((ulong)offset, buf, n, eve);

	case Qhostdomain:
		return readstr((ulong)offset, buf, n, hostdomain);

	case Quser:
		return readstr((ulong)offset, buf, n, up->user);

	case Qnull:
		return 0;

	case Qconfig:
		return readstr((ulong)offset, buf, n, conffile);

	case Qsysstat:
		b = smalloc(conf.nmach*(NUMSIZE*11+1) + 1);	/* +1 for NUL */
		bp = b;
		for(id = 0; id < MAXMACH; id++) {
			if(active.machs[id]) {
				mp = MACHP(id);
				readnum(0, bp, NUMSIZE, id, NUMSIZE);
				bp += NUMSIZE;
				readnum(0, bp, NUMSIZE, mp->cs, NUMSIZE);
				bp += NUMSIZE;
				readnum(0, bp, NUMSIZE, mp->intr, NUMSIZE);
				bp += NUMSIZE;
				readnum(0, bp, NUMSIZE, mp->syscall, NUMSIZE);
				bp += NUMSIZE;
				readnum(0, bp, NUMSIZE, mp->pfault, NUMSIZE);
				bp += NUMSIZE;
				readnum(0, bp, NUMSIZE, mp->tlbfault, NUMSIZE);
				bp += NUMSIZE;
				readnum(0, bp, NUMSIZE, mp->tlbpurge, NUMSIZE);
				bp += NUMSIZE;
				readnum(0, bp, NUMSIZE, mp->load, NUMSIZE);
				bp += NUMSIZE;
				l = mp->perf.period;
				if(l == 0)
					l = 1;
				readnum(0, bp, NUMSIZE,
					(mp->perf.avg_inidle*100)/l, NUMSIZE);
				bp += NUMSIZE;
				readnum(0, bp, NUMSIZE,
					(mp->perf.avg_inintr*100)/l, NUMSIZE);
				bp += NUMSIZE;
				*bp++ = '\n';
			}
		}
		if(waserror()){
			free(b);
			nexterror();
		}
		n = readstr((ulong)offset, buf, n, b);
		free(b);
		poperror();
		return n;

	case Qsysname:
		if(sysname == nil)
			return 0;
		return readstr((ulong)offset, buf, n, sysname);

	case Qrandom:
		return randomread(buf, n);

	case Qnotquiterandom:
		genrandom(buf, n);
		return n;

	case Qdrivers:
		b = smalloc(READSTR);
		k = 0;
		for(i = 0; devtab[i] != nil; i++)
			k += snprint(b+k, READSTR-k, "#%C %s\n",
				devtab[i]->dc, devtab[i]->name);
		if(waserror()){
			free(b);
			nexterror();
		}
		n = readstr((ulong)offset, buf, n, b);
		poperror();
		free(b);
		return n;

	case Qzero:
		memset(buf, 0, n);
		return n;

	case Qmemory:
		return poolread(buf, n, offset);

	/*
	 * The ilock trace, READABLE.
	 *
	 * "echo ilock >/dev/sysctl" has reported these since the lock work,
	 * by print(), to the console -- and this board's console has been
	 * deaf for months, so on the one machine the numbers are wanted on
	 * they cannot be had.  doc/parallel-allocator-survey.ms item 1 asks
	 * for the allocator's lock contention under a real workload before
	 * anything is built, and that is a measurement that has to come
	 * back in a file.
	 *
	 * Reading does NOT reset, unlike the sysctl command: a reader is
	 * something a script does, possibly twice, and a measurement that
	 * disappears when looked at cannot be differenced.  "echo ilock on"
	 * is what zeroes them.
	 */
	case Qilock:
		{
			ulong hz = m->cpuhz? m->cpuhz: 1;
			ulong per = hz/1000000? hz/1000000: 1;

			snprint(tmp, sizeof tmp,
				"ilock trace %d max %ld us pc %#p mean %ld ns n %lud\n",
				ilocktrace,
				maxilockcycles/(long)per,
				(void*)maxilockpc,
				nilocktraced?
				  (long)(cumilockcycles/(long)nilocktraced) * 1000
				   / (long)per: 0L,
				nilocktraced);
		}
		return readstr((ulong)offset, buf, n, tmp);

	case Qmordor:
		error("one does not simply read from mordor");
		return 0;

	case Qosversion:
		snprint(tmp, sizeof tmp, "2000 %ud", kerndate);
		n = readstr((ulong)offset, buf, n, tmp);
		return n;

	default:
		print("consread %llud\n", c->qid.path);
		error(Egreg);
	}
	return -1;		/* never reached */
}

static s32
conswrite(Chan *c, void *va, s32 n, s64 offset)
{
	char buf[256];
	long l, bp;
	char *a;
	Mach *mp;
	int id;
	Cmdbuf *cb;
	Cmdtab *ct;
	s64 t;
	int x;

	a = va;
	switch((ulong)c->qid.path){
	case Qcons:
		/*
		 * Can't page fault in putstrn, so copy the data locally.
		 */
		l = n;
		while(l > 0){
			bp = l;
			if(bp > sizeof buf)
				bp = sizeof buf;
			memmove(buf, a, bp);
			putstrn0(a, bp, 1);
			a += bp;
			l -= bp;
		}
		break;

	case Qkeyboard:
		for(x = 0; x < n; ){
			Rune r;
			x += chartorune(&r, a+x);
			gkbdputc(gkbdq, r);
		}
		break;

	case Qconsctl:
		if(n >= sizeof(buf))
			n = sizeof(buf)-1;
		strncpy(buf, a, n);
		buf[n] = 0;
		for(a = buf; a;){
			if(strncmp(a, "rawon", 5) == 0){
				qlock(&kbd);
				flushkbdline(kbdq);
				kbd.raw = 1;
				qunlock(&kbd);
			} else if(strncmp(a, "rawoff", 6) == 0){
				qlock(&kbd);
				kbd.raw = 0;
				kbd.x = 0;
				qunlock(&kbd);
			}
			if(a = strchr(a, ' '))
				a++;
		}
		break;

	
	case Qtime:
		if(!iseve())
			error(Eperm);
		return writetime(a, n);

	case Qbintime:
		if(!iseve())
			error(Eperm);
		return writebintime(a, n);

	case Qhostowner:
		return hostownerwrite(a, n);

	case Qhostdomain:
		return hostdomainwrite(a, n);

	case Qjit:
		if(n >= sizeof(buf))
			n = sizeof(buf)-1;
		strncpy(buf, va, n);
		buf[n] = '\0';
		x = atoi(buf);
		if(x < 0 || x > 9)
			error(Ebadarg);
		cflag = x;
		return n;

	case Quser:
		return userwrite(a, n);

	case Qnull:
		break;

	case Qconfig:
		error(Eperm);
		break;

	case Qreboot:
		if(!iseve())
			error(Eperm);
		cb = parsecmd(a, n);

		if(waserror()) {
			free(cb);
			nexterror();
		}
		ct = lookupcmd(cb, rebootmsg, nelem(rebootmsg));
		switch(ct->index) {
		case CMreboot:
			/*
			 * Was a bare TODO, so writing "reboot" to /dev/reboot
			 * silently did nothing on every board.  exit(0) is the
			 * reboot path already: it shuts the devices down and
			 * calls archreboot(), which is what main.c's own
			 * reboot() does.  Loading a new kernel image first --
			 * what rebootcmd() would have added -- is still not
			 * implemented, so a reboot restarts the machine rather
			 * than booting something else.
			 */
			exit(0);
			break;
		case CMpanic:
			*(ulong*)0=0;
			panic("/dev/reboot");
		case CMrdb:
			if(consdebug == nil)
				consdebug = rdb;
			consdebug();
			break;
		}
		poperror();
		free(cb);
		break;

	case Qsysstat:
		for(id = 0; id < MAXMACH; id++) {
			if(active.machs[id]) {
				mp = MACHP(id);
				mp->cs = 0;
				mp->intr = 0;
				mp->syscall = 0;
				mp->pfault = 0;
				mp->tlbfault = 0;
				mp->tlbpurge = 0;
			}
		}
		break;

	case Qsysname:
		if(offset != 0)
			error(Ebadarg);
		if(n <= 0 || n >= sizeof buf)
			error(Ebadarg);
		strncpy(buf, a, n);
		buf[n] = 0;
		if(buf[n-1] == '\n')
			buf[n-1] = 0;
		kstrdup(&sysname, buf);
		break;
	
	case Qmordor:
		error("one does not simply write into mordor");
		return 0;

	case Qsysctl:
		if(!iseve())
			error(Eperm);
		cb = parsecmd(a, n);
		if(waserror()){
			free(cb);
			nexterror();
		}
		ct = lookupcmd(cb, sysctlcmd, nelem(sysctlcmd));
		switch(ct->index){
		case CMreboot:
			reboot();
			break;
		case CMhalt:
			halt();
			break;
		case CMpanic:
			panic("sysctl");
		case CMconsole:
			consoleprint = strcmp(cb->f[1], "off") != 0;
			break;
		case CMbroken:
			keepbroken = 1;
			break;
		case CMnobroken:
			keepbroken = 0;
			break;
		case CMprocdump:
			/*
			 * Every process, kernel ones included, with its state
			 * and saved pc: /prog shows only Dis processes, and a
			 * wedged kproc is otherwise invisible from the shell.
			 */
			kstackdump();
			break;
		case CMsched:
			/*
			 * The preemption chain, one counter per link, so
			 * that a chain with one broken link does not read
			 * as a design that does not work.  ticks should be
			 * HZ per second of uptime; hzsched calls fewer,
			 * because the tick only counts when a process is
			 * Running; raised is anyhigher() opening the gate;
			 * taken is vmachine() giving the processor up at a
			 * Dis instruction boundary.  Raised much larger
			 * than taken means whatever holds the processor is
			 * not the interpreter.
			 */
			print("SCHED-COUNTS ticks %lud hzsched %lud raised %lud "
				"taken %lud delayed %lud ioboost %d "
				"sleepacq %lud/%lud max %lud, tsleep %lud max %lud, runq %lud max %lud, rel %lud ticks; "
				"higher %lud quantum %lud uppri %lud runvec %#lux wokepri %lud; "
				"ticks noup %lud notrun %lud run %lud hipri %lud uphi %lud anyhi %lud; "
				"gc %lud/%lud max %lud, idlegc %lud max %lud ticks; "
				"skipscheds %lud preempts %lud coop %d gate %d clock %d boost %d\n",
				m->ticks, hzschedcalls, reschedraised,
				reschedtaken, delayedscheds, ioboost,
				sleepacqticks, sleepacqn, sleepacqmax,
				sleeptsticks, sleeptsmax,
				sleeprqticks, sleeprqmax, sleeprelticks,
				reschedhigher, reschedquantum, lastuppri,
				lastrunvec, wokepri, ticknoup, ticknotrun, tickrun,
				tickhipri, tickuphi, tickanyhi,
				gcticks, gcpasses, gcmax, idlegcticks, idlegcmax,
				skipscheds, preempts, coopsched, schedgate,
				schedclock, lockboost);
			/*
			 * Per-processor, because on a machine with more than
			 * one the aggregate above cannot say whether the
			 * others are scheduling anything.  cs is context
			 * switches, so a secondary with cs 0 has taken its
			 * timer interrupts and run nothing -- which is what
			 * "all four cores take their own interrupts" bought
			 * before they entered schedinit(), and is exactly the
			 * distinction a boot that merely completes cannot draw.
			 */
			{
				int id;
				Mach *mm;

				/*
				 * load is printed ONCE and not per processor,
				 * because it is not a per-processor number:
				 * accounttime() returns early for machno != 0
				 * with "only one processor gets to compute
				 * system load averages", so every secondary's
				 * m->load is 0 by design.  Printing it in the
				 * per-cpu list read as "the load average is
				 * not being computed there", which is a bug
				 * report about correct behaviour.
				 */
				print("SCHED-MACHS nmach %lud load %d (cpu0's,"
					" machine-wide):", (ulong)conf.nmach,
					MACHP(0) != nil? MACHP(0)->load: 0);
				for(id = 0; id < MAXMACH; id++){
					if((mm = MACHP(id)) == nil)
						continue;
					print(" cpu%d[active %d ticks %lud"
						" cs %d]", id,
						active.machs[id], mm->ticks,
						mm->cs);
				}
				print("\n");
				/*
				 * The collector's own counters, which nothing
				 * in this tree printed.  gcdepthmax is the
				 * reason: gchalt used to be both the heap's
				 * "do not collect" flag and destroy()'s C-stack
				 * recursion depth, and heap.c guards that depth
				 * at 64 -- so how close the depth actually runs
				 * to its guard decides whether splitting them
				 * was cosmetic or load-bearing.  halted is the
				 * other half: how often the suppression fired.
				 */
				print("GC-COUNTS runs %lud sweeps %lud epochs"
					" %lud halted %lud, gchalt %d gcdepth %d"
					" depthmax %d (guard 64), destroys %llud"
					" inspects %llud, quantum-open %lud"
					" (must be 0), stw %lud waited %lud"
					" gaveup %lud, runq-other %lud"
					" runq-freed-queued %lud"
					" broken-chains %lud"
					" jitrefsatomic %d cflag %d\n",
					gcnruns, gcsweeps, gcepochs, gchalted,
					gchalt, gcdepth, gcdepthmax,
					gcdestroys, gcinspects, gcinxecseen,
					gcstwstops, gcstwwaits, gcstwfails,
					nrunqother, nrunqdel,
					gcbroken,
					jitrefsatomic, cflag);
			}
			if(cb->nf > 2 && strcmp(cb->f[1], "ioboost") == 0)
				ioboost = atoi(cb->f[2]);
			if(cb->nf > 2 && strcmp(cb->f[1], "coopsched") == 0)
				coopsched = atoi(cb->f[2]);
			if(cb->nf > 2 && strcmp(cb->f[1], "schedgate") == 0)
				schedgate = atoi(cb->f[2]);
			if(cb->nf > 2 && strcmp(cb->f[1], "schedclock") == 0)
				schedclock = atoi(cb->f[2]);
			if(cb->nf > 2 && strcmp(cb->f[1], "lockboost") == 0)
				lockboost = atoi(cb->f[2]);
			if(cb->nf > 1 && strcmp(cb->f[1], "reset") == 0){
				hzschedcalls = reschedraised = reschedtaken = 0;
				sleepacqticks = sleepacqn = sleepacqmax = 0;
				sleeptsticks = sleeptsmax = sleeprelticks = 0;
				sleeprqticks = sleeprqmax = 0;
				reschedhigher = reschedquantum = 0;
				gcticks = gcpasses = gcmax = 0;
				idlegcticks = idlegcmax = 0;
				skipscheds = preempts = delayedscheds = 0;
				print("SCHED-RESET at tick %lud\n", m->ticks);
			}
			if(cb->nf > 2 && strcmp(cb->f[1], "sleeptrace") == 0)
				sleeptrace = atoi(cb->f[2]);
			break;
		case CMilock:
			/*
			 * The longest the kernel has kept interrupts masked,
			 * and where.  "ilock on" starts counting, "ilock off"
			 * stops, and a bare "ilock" reports and resets -- so
			 * the number can be taken over a named interval (a
			 * fatstress run, an enumeration) rather than over
			 * whatever happened since boot.  taslock.c says why
			 * it is not always on.
			 */
			if(cb->nf > 1 && strcmp(cb->f[1], "on") == 0){
				maxilockcycles = 0;
				maxilockpc = 0;
				cumilockcycles = 0;
				nilocktraced = 0;
				ilocktrace = 1;
				print("ILOCK-TRACE on\n");
			}else if(cb->nf > 1 && strcmp(cb->f[1], "off") == 0){
				ilocktrace = 0;
				print("ILOCK-TRACE off\n");
			}else{
				ulong hz = m->cpuhz? m->cpuhz: 1;

#ifndef ILOCKTRACE
				print("ILOCK-TRACE not compiled in (see the board mkfile)\n");
#endif
				print("ILOCK-MAX %ld us at %#p, mean %ld ns over %lud ilocks%s\n",
					maxilockcycles/(long)(hz/1000000? hz/1000000: 1),
					(void*)maxilockpc,
					nilocktraced?
					  (long)(cumilockcycles/(long)nilocktraced)
					   * 1000 / (long)(hz/1000000? hz/1000000: 1): 0L,
					nilocktraced,
					ilocktrace? "": " (tracing off)");
				maxilockcycles = 0;
				maxilockpc = 0;
				cumilockcycles = 0;
				nilocktraced = 0;
			}
			break;
		}
		poperror();
		free(cb);
		break;

	default:
		print("conswrite: %llud\n", c->qid.path);
		error(Egreg);
	}
	return n;
}

Dev consdevtab = {
	'c',
	"cons",

	devreset,
	consinit,
	devshutdown,
	consattach,
	conswalk,
	consstat,
	consopen,
	devcreate,
	consclose,
	consread,
	devbread,
	conswrite,
	devbwrite,
	devremove,
	devwstat,
};

static	ulong	randn;

static void
seedrand(void)
{
	randomread((void*)&randn, sizeof(randn));
}

int
nrand(int n)
{
	if(randn == 0)
		seedrand();
	randn = randn*1103515245 + 12345 + MACHP(0)->ticks;
	return (randn>>16) % n;
}

int
rand(void)
{
	nrand(1);
	return randn;
}

ulong
truerand(void)
{
	ulong x;

	randomread(&x, sizeof(x));
	return x;
}

static uvlong uvorder = 0x0001020304050607ULL;

static uchar*
le2vlong(vlong *to, uchar *f)
{
	uchar *t, *o;
	int i;

	t = (uchar*)to;
	o = (uchar*)&uvorder;
	for(i = 0; i < sizeof(vlong); i++)
		t[o[i]] = f[i];
	return f+sizeof(vlong);
}

static uchar*
vlong2le(uchar *t, vlong from)
{
	uchar *f, *o;
	int i;

	f = (uchar*)&from;
	o = (uchar*)&uvorder;
	for(i = 0; i < sizeof(vlong); i++)
		t[i] = f[o[i]];
	return t+sizeof(vlong);
}

static long order = 0x00010203;

static uchar*
le2long(long *to, uchar *f)
{
	uchar *t, *o;
	int i;

	t = (uchar*)to;
	o = (uchar*)&order;
	for(i = 0; i < sizeof(long); i++)
		t[o[i]] = f[i];
	return f+sizeof(long);
}

static uchar*
long2le(uchar *t, long from)
{
	uchar *f, *o;
	int i;

	f = (uchar*)&from;
	o = (uchar*)&order;
	for(i = 0; i < sizeof(long); i++)
		t[i] = f[o[i]];
	return t+sizeof(long);
}

char *Ebadtimectl = "bad time control";

/*
 *  like the old #c/time but with added info.  Return
 *
 *	secs	nanosecs	fastticks	fasthz
 */
static int
/*
 * Microseconds since the epoch, one number, which is what cons(3)
 * describes and what the hosted kernel has always returned.
 *
 * This returned Plan 9's four fields -- seconds, nanoseconds, ticks and
 * the tick rate -- and every Limbo program that asks the time reads the
 * first number and divides it by a million: daytime(2)'s now(), which
 * is what dates a file, ping(8)'s round trip, cs, dns, keyfs, iostats,
 * timestamp, memfs, lockfs.  On a native kernel all of them therefore
 * got zero, or a round trip a million times too small.  The Pi wrote
 * every file with a 1980 date long before anything asked the network
 * what year it was, and its pings all read "rtt 0 us".
 *
 * /dev/bintime is the binary form and is unchanged; a reader that wants
 * ticks and the tick rate wants that.
 */
readtime(ulong off, char *buf, int n)
{
	vlong nsec, ticks;
	char str[VLNUMSIZE];

	nsec = todget(&ticks);
	snprint(str, sizeof(str), "%lld", nsec/1000LL);
	return readstr(off, buf, n, str);
}

/*
 *  set the time in seconds
 */
static int
/*
 * Microseconds, which is what cons(3) says this file is and what every
 * program that writes it writes: sntp(8) sends seconds*1000000 and
 * wm/calendar appends six zeroes to an epoch time.  This took seconds
 * instead, in a thirteen-character buffer -- so a correct write was
 * both a thousand times too large and too long to fit, and failed with
 * Ebadtimectl.  sntp ignores the error, so a board with no clock asked
 * the network for the time, was told, and stayed at 1970: its console
 * printed the answer and its files kept 1 January 1980 timestamps.
 * The hosted kernel has always read it as microseconds.
 */
writetime(char *buf, int n)
{
	char b[32];
	vlong us;

	if(n >= sizeof(b))
		error(Ebadtimectl);
	strncpy(b, buf, n);
	b[n] = 0;
	us = strtoll(b, 0, 0);
	if(us <= 0)
		error(Ebadtimectl);
	todset(us*1000LL, 0, 0);
	return n;
}

/*
 *  read binary time info.  all numbers are little endian.
 *  ticks and nsec are syncronized.
 */
static int
readbintime(char *buf, int n)
{
	int i;
	vlong nsec, ticks;
	uchar *b = (uchar*)buf;

	i = 0;
	if(fasthz == 0LL)
		fastticks((uvlong*)&fasthz);
	nsec = todget(&ticks);
	if(n >= 3*sizeof(uvlong)){
		vlong2le(b+2*sizeof(uvlong), fasthz);
		i += sizeof(uvlong);
	}
	if(n >= 2*sizeof(uvlong)){
		vlong2le(b+sizeof(uvlong), ticks);
		i += sizeof(uvlong);
	}
	if(n >= 8){
		vlong2le(b, nsec);
		i += sizeof(vlong);
	}
	return i;
}

/*
 *  set any of the following
 *	- time in nsec
 *	- nsec trim applied over some seconds
 *	- clock frequency
 */
static int
writebintime(char *buf, int n)
{
	uchar *p;
	vlong delta;
	long period;

	if(--n <= 0)
		error(Ebadtimectl);
	p = (uchar*)buf + 1;
	switch(*buf){
	case 'n':
		if(n < sizeof(vlong))
			error(Ebadtimectl);
		le2vlong(&delta, p);
		todset(delta, 0, 0);
		break;
	case 'd':
		if(n < sizeof(vlong)+sizeof(long))
			error(Ebadtimectl);
		p = le2vlong(&delta, p);
		le2long(&period, p);
		todset(-1, delta, period);
		break;
	case 'f':
		if(n < sizeof(uvlong))
			error(Ebadtimectl);
		le2vlong(&fasthz, p);
		if(fasthz <= 0)
			error(Ebadtimectl);
		todsetfreq(fasthz);
		break;
	}
	return n+1;
}

void
cpushutdown(void)
{
	int ms, once;

	once = active.machs[m->machno];
	active.machs[m->machno] = 0;
	active.exiting = 1;

	if(once)
		iprint("cpu%d: exiting\n", m->machno);

	/* wait for any other processors to shutdown */
	spllo();
	for(ms = 5*1000; ms > 0; ms -= TK2MS(2)){
		delay(TK2MS(2));
		if(memchr(active.machs, 1, MAXMACH) == nil && consactive() == 0)
			break;
	}
}

/* all the below belongs in kbdfs  */

/*
 * The codes at 0x79 and 0x81 are produed by the PFU Happy Hacking keyboard.
 * A 'standard' keyboard doesn't produce anything above 0x58.
 */
Rune kbtab[] = 
{
[0x00]	No,	0x1b,	'1',	'2',	'3',	'4',	'5',	'6',
[0x08]	'7',	'8',	'9',	'0',	'-',	'=',	'\b',	'\t',
[0x10]	'q',	'w',	'e',	'r',	't',	'y',	'u',	'i',
[0x18]	'o',	'p',	'[',	']',	'\n',	LCtrl,	'a',	's',
[0x20]	'd',	'f',	'g',	'h',	'j',	'k',	'l',	';',
[0x28]	'\'',	'`',	Shift,	'\\',	'z',	'x',	'c',	'v',
[0x30]	'b',	'n',	'm',	',',	'.',	'/',	Shift,	'*',
[0x38]	Latin,	' ',	LCtrl,	KF|1,	KF|2,	KF|3,	KF|4,	KF|5,
[0x40]	KF|6,	KF|7,	KF|8,	KF|9,	KF|10,	Num,	Scroll,	'7',
[0x48]	'8',	'9',	'-',	'4',	'5',	'6',	'+',	'1',
[0x50]	'2',	'3',	'0',	'.',	No,	No,	No,	KF|11,
[0x58]	KF|12,	No,	No,	No,	No,	No,	No,	No,
[0x60]	No,	No,	No,	No,	No,	No,	No,	No,
[0x68]	No,	No,	No,	No,	No,	No,	No,	No,
[0x70]	No,	No,	No,	No,	No,	No,	No,	No,
[0x78]	No,	View,	No,	Up,	No,	No,	No,	No,
};

Rune kbtabshift[] =
{
[0x00]	No,	0x1b,	'!',	'@',	'#',	'$',	'%',	'^',
[0x08]	'&',	'*',	'(',	')',	'_',	'+',	'\b',	'\t',
[0x10]	'Q',	'W',	'E',	'R',	'T',	'Y',	'U',	'I',
[0x18]	'O',	'P',	'{',	'}',	'\n',	LCtrl,	'A',	'S',
[0x20]	'D',	'F',	'G',	'H',	'J',	'K',	'L',	':',
[0x28]	'"',	'~',	Shift,	'|',	'Z',	'X',	'C',	'V',
[0x30]	'B',	'N',	'M',	'<',	'>',	'?',	Shift,	'*',
[0x38]	Latin,	' ',	LCtrl,	KF|1,	KF|2,	KF|3,	KF|4,	KF|5,
[0x40]	KF|6,	KF|7,	KF|8,	KF|9,	KF|10,	Num,	Scroll,	'7',
[0x48]	'8',	'9',	'-',	'4',	'5',	'6',	'+',	'1',
[0x50]	'2',	'3',	'0',	'.',	No,	No,	No,	KF|11,
[0x58]	KF|12,	No,	No,	No,	No,	No,	No,	No,
[0x60]	No,	No,	No,	No,	No,	No,	No,	No,
[0x68]	No,	No,	No,	No,	No,	No,	No,	No,
[0x70]	No,	No,	No,	No,	No,	No,	No,	No,
[0x78]	No,	Up,	No,	Up,	No,	No,	No,	No,
};

Rune kbtabesc1[] =
{
[0x00]	No,	No,	No,	No,	No,	No,	No,	No,
[0x08]	No,	No,	No,	No,	No,	No,	No,	No,
[0x10]	No,	No,	No,	No,	No,	No,	No,	No,
[0x18]	No,	No,	No,	No,	'\n',	LCtrl,	No,	No,
[0x20]	No,	No,	No,	No,	No,	No,	No,	No,
[0x28]	No,	No,	Shift,	No,	No,	No,	No,	No,
[0x30]	No,	No,	No,	No,	No,	'/',	No,	Print,
[0x38]	Latin,	No,	No,	No,	No,	No,	No,	No,
[0x40]	No,	No,	No,	No,	No,	No,	Break,	Home,
[0x48]	Up,	Pgup,	No,	Left,	No,	Right,	No,	End,
[0x50]	Down,	Pgdown,	Ins,	Del,	No,	No,	No,	No,
[0x58]	No,	No,	No,	No,	No,	No,	No,	No,
[0x60]	No,	No,	No,	No,	No,	No,	No,	No,
[0x68]	No,	No,	No,	No,	No,	No,	No,	No,
[0x70]	No,	No,	No,	No,	No,	No,	No,	No,
[0x78]	No,	Up,	No,	No,	No,	No,	No,	No,
};

void
echo(Rune r, char *buf, int n)
{
        if(kbd.raw)
                return;

        if(r == 0x15){
                buf = "^U\n";
                n = 3;
        }
        /*
         * Erasing has to be shown: a lone backspace only moves the cursor
         * left, and the delete a terminal's backspace key actually sends
         * prints as nothing at all.  Back up, blank the character, back up
         * again.
         */
        if(r == '\b' || r == 0x7f){
                buf = "\b \b";
                n = 3;
        }
		putstrn(buf, n);
}

/*
 *  Put character, possibly a rune, into read queue at interrupt time.
 *  Performs translation for compose sequences
 *  Called at interrupt time to process a character.
 */
int
kbdputc(Queue *q, int ch)
{
        int n;
        char buf[UTFmax] = "";
        Rune r;
        static Rune kc[15];
        static int nk, collecting = 0;

        r = ch;
        if(r == Latin) {
                collecting = 1;
                nk = 0;
                return 0;
        }
        if(collecting) {
                int c;
                nk += runetochar((char*)&kc[nk], &r);
                c = latin1(kc, nk);
                if(c < -1)      /* need more keystrokes */
                        return 0;
                collecting = 0;
                if(c == -1) {   /* invalid sequence */
                        echo(kc[0], (char*)kc, nk);
                        qproduce(q, kc, nk);
                        return 0;
                }
                r = (Rune)c;
        }
        kbd.c = r;
        n = runetochar(buf, &r);
        if(n == 0)
                return 0;
        echo(r, buf, n);
        qproduce(q, buf, n);
        return 0;
}

/*
 * Graphics keyboard (/dev/keyboard): no echo, used by wm/tk.
 */
void
gkbdputc(Queue *q, int ch)
{
	int n;
	Rune r;
	static Rune kc[5];
	static int nk, collecting = 0;
	char buf[UTFmax];

	if(q == nil)
		return;
	r = ch;
	if(r == Latin){
		collecting = 1;
		nk = 0;
		return;
	}
	if(collecting){
		int c;

		if(nk < nelem(kc))
			kc[nk++] = r;
		c = latin1(kc, nk);
		if(c < -1)	/* need more keystrokes */
			return;
		collecting = 0;
		if(c == -1){	/* invalid sequence */
			for(n = 0; n < nk; n++){
				int m = runetochar(buf, &kc[n]);
				if(m > 0)
					qproduce(q, buf, m);
			}
			nk = 0;
			return;
		}
		r = (Rune)c;
		nk = 0;
	}
	n = runetochar(buf, &r);
	if(n == 0)
		return;
	qproduce(q, buf, n);
}

void
kbdrepeat(int rep)
{
        kbd.repeat = rep;
        kbd.count = 0;
}

void
kbdclock(void)
{
        if(kbd.repeat == 0)
                return;
        if(kbd.repeat==1 && ++kbd.count>HZ){
                kbd.repeat = 2;
                kbd.count = 0;
                return;
        }
        if(++kbd.count&1)
                kbdputc(kbdq, kbd.c);
}

/*
 *  Called by a uart interrupt for console input.
 *
 *  turn '\r' into '\n' before putting it into the queue.
 */
int
kbdcr2nl(Queue *q, int ch)
{
        if(ch == '\r')
                ch = '\n';
        return kbdputc(q, ch);
}

/*
 *  called from the keyboard interrupt
 */
void
kbdprocesschar(int ch)
{
	int c, i;
	static int esc1, esc2;
	static int alt, caps, ctl, num, shift;
	static int collecting, nk;
	static Rune kc[5];
	int keyup;

	c = ch;
	/*
	 *  e0's is the first of a 2 character sequence
	 */
	if(c == 0xe0){
		esc1 = 1;
		return;
	} else if(c == 0xe1){
		esc2 = 2;
		return;
	}

	keyup = c&0x80;
	c &= 0x7f;
	if(c > sizeof kbtab){
		c |= keyup;
		if(c != 0xFF)	/* these come fairly often: CAPSLOCK U Y */
			print("kbdprocess: unknown key 0x%ux\n", c);
		return;
	}

	if(esc1){
		c = kbtabesc1[c];
		esc1 = 0;
	} else if(esc2){
		esc2--;
		return;
	} else if(shift)
		c = kbtabshift[c];
	else
		c = kbtab[c];

	if(caps && c<='z' && c>='a')
		c += 'A' - 'a';

	/*
	 *  keyup only important for shifts
	 */
	if(keyup){
		switch(c){
		case Latin:
			alt = 0;
			break;
		case Shift:
			shift = 0;
			mouseshifted = 0;
			break;
		case RCtrl:
		case LCtrl:
			ctl = 0;
			break;
		}
		return;
	}

	/*
 	 *  normal character
	 */
	if(!(c & (Spec|KF))){
		if(ctl){
			if(alt && c == Del)
				exit(0);
			c &= 0x1f;
		}
		if(!collecting){
			kbdputc(kbdq, c);
			return;
		}
		kc[nk++] = c;
		c = latin1(kc, nk);
		if(c < -1)	/* need more keystrokes */
			return;
		if(c != -1)	/* valid sequence */
			kbdputc(kbdq, c);
		else	/* dump characters */
			for(i=0; i<nk; i++)
				kbdputc(kbdq, kc[i]);
		nk = 0;
		collecting = 0;
		return;
	} else {
		switch(c){
		case Caps:
			caps ^= 1;
			return;
		case Num:
			num ^= 1;
			return;
		case Shift:
			shift = 1;
			mouseshifted = 1;
			return;
		case Latin:
			alt = 1;
			/*
			 * VMware uses Ctl-Alt as the key combination
			 * to make the VM give up keyboard and mouse focus.
			 * This has the unfortunate side effect that when you
			 * come back into focus, Plan 9 thinks you want to type
			 * a compose sequence (you just typed alt). 
			 *
			 * As a clumsy hack around this, we look for ctl-alt
			 * and don't treat it as the start of a compose sequence.
			 */
			if(!ctl){
				collecting = 1;
				nk = 0;
			}
			return;
		case LCtrl:
		case RCtrl:
			collecting = 0;
			nk = 0;
			ctl = 1;
			return;
		}
	}
	kbdputc(kbdq, c);
}
