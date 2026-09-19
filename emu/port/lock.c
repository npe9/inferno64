#include	"dat.h"
#include	"fns.h"
#include	"error.h"

extern void	(*coherencefn)(void);

void
lock(Lock *l)
{
	int i;

	if(_tas(&l->val) == 0)
		return;
	for(i=0; i<100; i++){
		if(_tas(&l->val) == 0)
			return;
		osyield();
	}
	for(i=1;; i++){
		if(_tas(&l->val) == 0)
			return;
		osmillisleep(i*10);
		if(i > 100){
			osyield();
			i = 1;
		}
	}
}

int
canlock(Lock *l)
{
	return _tas(&l->val) == 0;
}

void
unlock(Lock *l)
{
	coherencefn();
	/*
	 * A release store, not a plain one.
	 *
	 * coherencefn is nil until main() sets it, and main() sets it to
	 * nofence - an empty function - on every platform in this tree;
	 * nothing anywhere assigns it anything else. So this was a plain
	 * store with no barrier in front of it.
	 *
	 * On x86 that is nearly harmless, because its store order is already
	 * what the code assumes. On arm64 it is not: the stores a critical
	 * section made can become visible after the store that releases the
	 * lock, so the next thread to take the lock - whose _tas does have
	 * acquire semantics - can read state the previous holder has already
	 * finished writing but not yet published. That is how a proc pushed
	 * onto isched.vmq could vanish from it with nobody popping it, which
	 * is the scheduler hang.
	 */
	__atomic_store_n(&l->val, 0, __ATOMIC_RELEASE);
}

void
qlock(QLock *q)
{
	Proc *p;

	lock(&q->use);
	if(!q->locked) {
		q->locked = 1;
		unlock(&q->use);
		return;
	}
	p = q->tail;
	if(p == 0)
		q->head = up;
	else
		p->qnext = up;
	q->tail = up;
	up->qnext = 0;
	unlock(&q->use);
	osblock();
}

int
canqlock(QLock *q)
{
	if(!canlock(&q->use))
		return 0;
	if(q->locked){
		unlock(&q->use);
		return 0;
	}
	q->locked = 1;
	unlock(&q->use);
	return 1;
}

void
qunlock(QLock *q)
{
	Proc *p;

	lock(&q->use);
	p = q->head;
	if(p) {
		q->head = p->qnext;
		if(q->head == 0)
			q->tail = 0;
		unlock(&q->use);
		osready(p);
		return;
	}
	q->locked = 0;
	unlock(&q->use);
}

void
rlock(RWlock *l)
{
	qlock(&l->x);		/* wait here for writers and exclusion */
	lock(&l->l);
	l->readers++;
	canqlock(&l->k);	/* block writers if we are the first reader */
	unlock(&l->l);
	qunlock(&l->x);
}

/* same as rlock but punts if there are any writers waiting */
int
canrlock(RWlock *l)
{
	if (!canqlock(&l->x))
		return 0;
	lock(&l->l);
	l->readers++;
	canqlock(&l->k);	/* block writers if we are the first reader */
	unlock(&l->l);
	qunlock(&l->x);
	return 1;
}

void
runlock(RWlock *l)
{
	lock(&l->l);
	if(--l->readers == 0)	/* last reader out allows writers */
		qunlock(&l->k);
	unlock(&l->l);
}

void
wlock(RWlock *l)
{
	qlock(&l->x);		/* wait here for writers and exclusion */
	qlock(&l->k);		/* wait here for last reader */
}

void
wunlock(RWlock *l)
{
	qunlock(&l->k);
	qunlock(&l->x);
}
