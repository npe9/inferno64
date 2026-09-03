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
	p = dequeue();
	if(p == nil){
		int i;
		for(i = 0; i < nallproc; i++)
			print("p9sched: proc %d %s state=%d twhen=%lud\n",
				allproc[i]->pid, allproc[i]->text, allproc[i]->state, allproc[i]->twhen);
		panic("p9sched: no runnable proc (deadlock), tick %lud", p9ticks);
	}
	if(setlabel(&me->sched))
		return;			/* resumed later */
	up = p;
	p->state = Running;
	gotolabel(&p->sched);
}

void
ksleep(Rendez *r, int (*f)(void*), void *arg)
{
	if(f(arg))
		return;			/* condition already true */
	r->p = up;
	up->rendez = r;
	up->state = Wakeme;
	while(!f(arg))
		sched();		/* switch away; a wakeup readies us */
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
	r->p = up;
	up->rendez = r;
	up->state = Wakeme;
	while(!f(arg) && (long)(p9ticks - up->twhen) < 0)
		sched();
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
	p = dequeue();
	if(p == nil)
		panic("p9sched: last proc exited");
	up = p;
	p->state = Running;
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
