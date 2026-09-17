#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"

static Alarms	alarms;
static Rendez	alarmr;

void
alarmkproc(void*)
{
	Proc *rp;
	ulong now, when;

	while(waserror())
		;

	for(;;){
		now = MACHP(0)->ticks;
		qlock(&alarms);
		for(rp = alarms.head; rp != nil; rp = rp->palarm){
			if((when = rp->alarm) == 0)
				continue;
			if((long)(now - when) < 0)
				break;
			if(!canqlock(&rp->debug))
				break;
			if(rp->alarm != 0){
				static Note alarm = {
					"alarm",
					NUser,
					1,
				};
				incref(&alarm);
				pushnote(rp, &alarm);
				rp->alarm = 0;
			}
			qunlock(&rp->debug);
		}
		alarms.head = rp;
		qunlock(&alarms);

		sleep(&alarmr, return0, 0);
	}
}

/*
 * Start it, once.  Two callers want it and one boot runs both: proc0
 * starts it for the paths that enter user mode without the Plan 9
 * setup, and init0 starts it for the personality - and the plain user
 * path (xup64, xu386) goes through proc0 and then calls init0, so it
 * asked twice.  Two of them sleep on alarmr, which holds one sleeper:
 * the second overwrote the first, so one kproc sat in Wakeme for ever
 * and the kernel said "double sleep called from ... alarm 2 -> alarm 6"
 * at every boot of those configurations.
 *
 * No lock: both calls are proc0's, one after the other, on the one
 * processor that runs it before any other kproc could ask.
 */
void
alarmkprocstart(void)
{
	static int started;

	if(started)
		return;
	started = 1;
	kproc("alarm", alarmkproc, 0);
}

/*
 *  called every clock tick on cpu0
 */
void
checkalarms(void)
{
	Proc *p;
	ulong now, when;

	p = alarms.head;
	if(p != nil){
		now = MACHP(0)->ticks;
		when = p->alarm;
		if(when == 0 || (long)(now - when) >= 0)
			wakeup(&alarmr);
	}
}

ulong
procalarm(ulong time)
{
	Proc **l, *f;
	ulong when, old;

	when = MACHP(0)->ticks;
	old = up->alarm;
	if(old) {
		old -= when;
		if((long)old > 0)
			old = tk2ms(old);
		else
			old = 0;
	}
	if(time == 0) {
		up->alarm = 0;
		return old;
	}
	when += ms2tk(time);
	if(when == 0)
		when = 1;

	qlock(&alarms);
	l = &alarms.head;
	for(f = *l; f; f = f->palarm) {
		if(up == f){
			*l = f->palarm;
			break;
		}
		l = &f->palarm;
	}
	l = &alarms.head;
	for(f = *l; f; f = f->palarm) {
		time = f->alarm;
		if(time != 0 && (long)(time - when) >= 0)
			break;
		l = &f->palarm;
	}
	up->palarm = f;
	*l = up;
	up->alarm = when;
	qunlock(&alarms);

	return old;
}

