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
	if(p == nil)
		panic("p9sched: no runnable proc (deadlock)");
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
 * Timed sleep.  There is no timer interrupt in the personality, so the
 * timeout never fires: a tsleep either returns at once (condition already
 * true) or parks until a wakeup on the same Rendez.  The protocol timer
 * kprocs tsleep on their own Rendez with a return0 condition and so park
 * here for good, which is harmless - loopback needs no retransmit timer.
 */
void
tsleep(Rendez *r, int (*f)(void*), void *arg, ulong ms)
{
	USED(ms);
	ksleep(r, f, arg);
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
	up->state = Running;
	up->pid = 1;
	strncpy(up->text, "p9server", sizeof up->text - 1);
}
