/*
 * p9sched.c - a cooperative scheduler for the p9 personality's kprocs.
 *
 * The shim ran single-threaded: kproc, sleep and wakeup were no-ops, so
 * the real Plan 9 IP stack's asynchronous pieces - above all the loopback
 * medium's read kproc - never ran, and any blocking read panicked.  This
 * gives the personality the classic Plan 9 kproc mechanism, cooperative
 * (no preemption is needed - the personality yields only at sleep):
 *
 *   - setlabel/gotolabel (xcall.s) switch SP and PC between procs.
 *   - each kproc is a Proc with its own stack and a saved Label.
 *   - sched() puts a running caller back on the run queue and resumes the
 *     next runnable proc; a caller that has marked itself Wakeme (asleep)
 *     is not requeued.
 *   - sleep() blocks on a Rendez until wakeup() readies it; both re-check
 *     the sleep condition, so a spurious wakeup just loops.
 *
 * The kernel's sleep collides with the host libc's sleep(int), so this
 * translation unit and every other kernel-side one are compiled with
 * -Dsleep=ksleep (see build.sh); the name the stack calls is ksleep here.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "../port/error.h"

enum { KSTK = 32*1024 };	/* per-kproc stack */

static Proc *runq;		/* ready queue head */
static Proc *runqt;		/* ready queue tail */
static int   p9pidalloc = 1;
static ulong p9ticks;		/* 10ms clock ticks since boot, advanced by sched_tick */
static Proc *allproc[64];	/* every proc, for timed wakeups and the deadlock dump */
static int   nallproc;

static void
enqueue(Proc *p)
{
	p->state = Ready;
	p->rnext = nil;
	if(runqt != nil)
		runqt->rnext = p;
	else
		runq = p;
	runqt = p;
}

static Proc*
dequeue(void)
{
	Proc *p;

	p = runq;
	if(p != nil){
		runq = p->rnext;
		if(runq == nil)
			runqt = nil;
		p->rnext = nil;
	}
	return p;
}

void
ready(Proc *p)
{
	if(p->state != Ready)
		enqueue(p);
}

/*
 * The private words of whichever proc is running.
 *
 * privalloc(2) is "one word of storage that is this process's own", and
 * a program gets the address of one once and then reads and writes it
 * from every flow of control it has.  In a kernel that word is on the
 * process's own page; here every flow of control is a kproc of one
 * address space, so the word is at one address and its contents are
 * swapped at the switch (sched, below).  A program that never calls
 * privalloc costs two memmoves of an empty array per switch.
 */
void *privblock[Nprivwords];
static int nprivalloc;

/*
 * Hand out the next one, or nil when they are gone - which is what
 * privalloc(2) answers, and what libc's callers do not check, so the
 * number has to be enough rather than nearly enough.
 */
void**
p9privalloc(void)
{
	if(nprivalloc >= Nprivwords)
		return nil;
	return &privblock[nprivalloc++];
}

extern vlong p9nsec(void);	/* devtime.c: the microkernel's clock, by xcall */
void sched_tick(void);		/* below: one 10ms tick of the cooperative clock */

/*
 * Nothing is runnable.  Whether that is a deadlock depends on why: if
 * every proc is asleep on a rendezvous, nothing but another proc could
 * ready it and there is no other proc, so it is one.  If some proc is
 * asleep on a deadline, it is not - it is an idle machine, and the way
 * out is time passing.
 *
 * The personality's event loops advance the cooperative clock from the
 * microkernel's tick semaphore, and while one of them is running there
 * is always something runnable.  But a program can sleep with no loop
 * under it: main.c runs its programs one after another on the server's
 * own flow of control, and a program that calls sleep(2) there put the
 * only proc there was to sleep.  That was a panic until now, and it is
 * the "no idle" this scheduler was written down as lacking.
 *
 * What it does about it is ask the kernel what time it is and turn the
 * answer into the ticks the sleepers are counting.  It is a busy wait
 * and it says so: blocking would mean downing a semaphore the kernel
 * has granted this container, and the tick reservation belongs to
 * whichever loop asked for it, not to the scheduler.  An idle machine
 * spending its own time in a syscall is the honest cost of that.
 *
 * Returns 1 if it advanced the clock and something may now be ready, 0
 * if there is nothing to wait for - which is the real deadlock.
 */
static int
idle(void)
{
	static vlong last;
	vlong now;
	int i, waiting;

	waiting = 0;
	for(i = 0; i < nallproc; i++)
		if(allproc[i]->state == Wakeme && allproc[i]->twhen != 0){
			waiting = 1;
			break;
		}
	if(!waiting)
		return 0;
	now = p9nsec();
	if(now == 0)
		return 0;		/* no clock to wait on: a deadlock after all */
	if(last == 0 || now < last)
		last = now;
	while(now - last >= 10*1000000LL){	/* a 10ms tick, this clock's unit */
		last += 10*1000000LL;
		sched_tick();
	}
	return 1;
}

/*
 * Give up the processor.  A Running caller is put back on the run queue; a
 * caller that has set itself Wakeme (in ksleep) is not.  Returns here when
 * another proc gotolabels back in.
 */
void
sched(void)
{
	Proc *me, *p;

	me = up;
	if(me->state == Running)
		enqueue(me);
	while((p = dequeue()) == nil && idle())
		;
	if(p == nil){
		int i;
		for(i = 0; i < nallproc; i++)
			print("p9sched: proc %d %s state=%d twhen=%lud\n",
				allproc[i]->pid, allproc[i]->text, allproc[i]->state, allproc[i]->twhen);
		panic("p9sched: no runnable proc (deadlock), tick %lud", p9ticks);
	}
	/*
	 * The private words go with the proc.  Saved before the switch and
	 * loaded by whoever does the switching, so that the proc being
	 * resumed finds its own: doing it the other way round - restoring
	 * after setlabel returns 1 - would leave a brand-new kproc, which
	 * arrives through launch and not through a setlabel, running on
	 * whatever the last proc left behind.
	 */
	memmove(me->priv, privblock, sizeof privblock);
	if(setlabel(&me->sched))
		return;			/* resumed later, with my words already loaded */
	up = p;
	p->state = Running;
	memmove(privblock, p->priv, sizeof privblock);
	gotolabel(&p->sched);
}

/*
 * Sleep until the condition is true.  A wakeup readies the sleeper but
 * proves nothing about the condition, so it is checked again, and - the
 * point that was missed for a long time - the sleep is armed again
 * before each switch: a wakeup clears the rendezvous and sched() marks
 * the sleeper Running, so a sleeper that just looped back to sched()
 * was put on the run queue as if runnable and ran round with the loop
 * proc for good, the serve loop never regaining its select.  A bulk
 * transfer's queue wakeups made that happen once in two runs.
 */
void
ksleep(Rendez *r, int (*f)(void*), void *arg)
{
	while(!f(arg)){
		r->p = up;
		up->rendez = r;
		up->state = Wakeme;
		sched();		/* switch away; a wakeup readies us */
	}
	up->rendez = nil;
	up->state = Running;
}

Proc*
wakeup(Rendez *r)
{
	Proc *p;

	p = r->p;
	if(p != nil && p->state == Wakeme){
		r->p = nil;
		p->rendez = nil;
		enqueue(p);		/* Ready; it re-checks its condition */
	}
	return p;
}

/*
 * Timed sleep.  The osprey clock tick (serviced by the server loop, which
 * calls sched_tick every 10ms) is the time base.  A tsleep returns when
 * its condition comes true, when a wakeup arrives on its Rendez, or when
 * its deadline passes - whichever first.  The protocol timer kprocs
 * (arp's rxmitproc, tcp's tcpack) tsleep on their own Rendez with a
 * return0 condition, so the deadline is what drives them, and they now
 * cycle instead of parking for good - which a real wire needs for
 * retransmission and address resolution.
 */
void
tsleep(Rendez *r, int (*f)(void*), void *arg, ulong ms)
{
	ulong wait;

	if(f(arg))
		return;
	wait = (ms + 9) / 10;		/* ms -> ticks, at least one */
	if(wait == 0)
		wait = 1;
	up->twhen = p9ticks + wait;
	while(!f(arg) && (long)(p9ticks - up->twhen) < 0){
		r->p = up;		/* armed again before each switch, as in ksleep */
		up->rendez = r;
		up->state = Wakeme;
		sched();
	}
	up->rendez = nil;
	up->twhen = 0;
	up->state = Running;
}

/*
 * A clock tick: advance the clock and ready any proc whose tsleep
 * deadline has passed.  Called from the server loop each time the osprey
 * device delivers a tick on its semaphore.
 */
void
sched_tick(void)
{
	int i;
	Proc *p;

	p9ticks++;
	/*
	 * The stack's own clock, NOW (TK2MS(MACHP(0)->ticks)), advances with
	 * it: arp.c decides whether to send a request, and whether to send
	 * it again, by the time since the entry was made, and with a clock
	 * stuck at zero it never sent one at all - which loopback and the
	 * ring medium, needing no ARP, never showed; the first real wire did.
	 */
	MACHP(0)->ticks = p9ticks;
	for(i = 0; i < nallproc; i++){
		p = allproc[i];
		if(p->state == Wakeme && p->twhen != 0 && (long)(p9ticks - p->twhen) >= 0){
			if(p->rendez != nil){
				p->rendez->p = nil;
				p->rendez = nil;
			}
			enqueue(p);	/* deadline passed: it re-checks and returns */
		}
	}
}

/*
 * The fast clock, for il.c's round-trip timing: the tick count, at 100 Hz.
 * The name is what -Dfastticks=kfastticks (build.sh) turns the stack's
 * fastticks into; libc's own fastticks opens /dev/bintime through nsec(),
 * an OPEN the microkernel does not answer.
 */
uvlong
kfastticks(uvlong *hz)
{
	if(hz != nil)
		*hz = 100;
	return p9ticks;
}

/*
 * rendezvous(2).
 *
 * Two flows of control name the same tag and meet there: the first to
 * arrive sleeps, the second wakes it, and each is handed the other's
 * value.  It is symmetric on purpose - neither side is the waker by
 * construction - and that is what makes it safe to use as libthread
 * does, where a proc with no ready thread sets a flag, drops a lock and
 * only then rendezvouses, so the waker can get there first.
 *
 * libthread is the caller.  runthread puts a proc with nothing to run to
 * sleep on the address of its ready queue, and _threadready wakes it on
 * the same address when it puts a thread there (sched.c).  Without this,
 * a program's second proc would be started and never woken.
 *
 * No locks: this personality's scheduler is cooperative and switches
 * only where it is asked to, so the scan and the claim below are one
 * indivisible step already.
 */
/*
 * How many tags can be waited on at once.  A flow of control is inside
 * at most one call at a time, so it can be blocked in at most one
 * rendezvous, and the flows that can reach this are a loaded program's:
 * the one p9exec entered on, and the ones proccreate made, which come
 * out of p9proc.c's sixteen slots.  Seventeen is the most there can be,
 * so this is enough with room to spare and running out is not a
 * program's doing but a bookkeeping mistake in the personality.
 */
enum { Nrend = 24 };

typedef struct Rend Rend;
struct Rend {
	int	inuse;
	void	*tag;
	void	*val;		/* going in, the sleeper's; coming out, the waker's */
	int	done;
	Rendez	r;
};
static Rend rends[Nrend];

static int
rendone(void *a)
{
	return ((Rend*)a)->done;
}

void*
p9rendezvous(void *tag, void *val)
{
	Rend *e;
	void *other;
	int i;

	for(i = 0; i < Nrend; i++)
		if(rends[i].inuse && !rends[i].done && rends[i].tag == tag){
			/* the other side is already here: take its value, leave ours */
			e = &rends[i];
			other = e->val;
			e->val = val;
			e->done = 1;
			wakeup(&e->r);
			return other;
		}
	for(i = 0; i < Nrend; i++)
		if(!rends[i].inuse)
			break;
	if(i == Nrend)
		panic("p9 rendezvous: all %d slots taken, which is more flows of control than there can be", Nrend);
	e = &rends[i];
	e->inuse = 1;
	e->tag = tag;
	e->val = val;
	e->done = 0;
	ksleep(&e->r, rendone, e);
	other = e->val;
	e->inuse = 0;
	e->done = 0;
	return other;
}

/*
 * Run every kproc that is ready, then return to the caller (the server
 * loop).  The caller is Running, so sched() requeues it; it is handed back
 * the processor once the ready kprocs have each run until they sleep.
 */
void
runkprocs(void)
{
	while(runq != nil)
		sched();
}

static void
launch(void)
{
	(*up->kpfun)(up->kparg);
	pexit("kproc returned", 1);
}

void
kproc(char *name, void (*f)(void*), void *arg)
{
	Proc *p;
	uintptr top, sp;

	p = mallocz(sizeof(Proc), 1);
	if(p == nil)
		panic("kproc: no memory");
	p->kstack = malloc(KSTK);
	if(p->kstack == nil)
		panic("kproc: no stack");
	if(nallproc < nelem(allproc))
		allproc[nallproc++] = p;
	p->kpfun = f;
	p->kparg = arg;
	p->pid = ++p9pidalloc;
	strncpy(p->text, name, sizeof p->text - 1);
	/* its own error buffers: error()/kstrcpy write here, and a kproc that
	 * does namec/fd work must not share the server proc's single buffers */
	p->errstr = mallocz(ERRMAX, 1);
	p->syserrstr = mallocz(ERRMAX, 1);
	/* inherit the server's name space so #I and /net resolve */
	p->pgrp = up->pgrp; p->egrp = up->egrp; p->fgrp = up->fgrp;
	p->dot = up->dot; p->slash = up->slash; p->user = up->user;

	top = (uintptr)p->kstack + KSTK;
	top &= ~(uintptr)15;			/* 16-align */
	sp = top - 16;				/* gotolabel writes the pc at 0(sp), RETs to it */
	p->sched.sp = sp;
	p->sched.pc = (uintptr)launch;
	enqueue(p);
}

void
pexit(char *msg, int freemem)
{
	Proc *p;

	USED(msg); USED(freemem);
	up->state = Dead;			/* our stack is leaked: we are on it */
	/*
	 * The same idle sched has, and for the same reason: an empty run
	 * queue is not the end of the machine if some proc is waiting on a
	 * deadline.  A program's second flow of control ending while the
	 * flow that is waiting for it sleeps is exactly that, and it used to
	 * panic here.
	 *
	 * Nothing is saved of this proc's private words - it is dead and
	 * will not be resumed - but the next one's are loaded, as they are
	 * in sched: without that it would run on whatever this proc left in
	 * the block.
	 */
	while((p = dequeue()) == nil && idle())
		;
	if(p == nil)
		panic("p9sched: last proc exited");
	up = p;
	p->state = Running;
	memmove(privblock, p->priv, sizeof privblock);
	gotolabel(&p->sched);
	for(;;)					/* gotolabel does not return */
		;
}

/*
 * Make the running server the first proc.  Called once before any device
 * reset can start a kproc.
 */
void
schedinit(void)
{
	static int done;

	if(done)
		return;
	done = 1;
	if(nallproc < nelem(allproc))
		allproc[nallproc++] = up;
	up->state = Running;
	up->pid = 1;
	strncpy(up->text, "p9server", sizeof up->text - 1);
}
