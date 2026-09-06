#include	"dat.h"
#include	"fns.h"
#include	"error.h"

extern void	(*coherencefn)(void);

/*
 * ThreadSanitizer cannot see this lock on its own, and until it is told
 * about it the tool is useless against this tree: _tas() is hand
 * written assembly it does not instrument, and unlock()'s "l->val = 0"
 * is a plain store, so every critical section in the system reads as a
 * race on the lock word.  Measured, before these annotations, on eight
 * spawns of a shell: 947 reports, the bulk of them inside
 * emu/port/alloc.c's poolalloc/poolfree/pooldel -- which is not the
 * allocator being wrong, it is the allocator being the most
 * lock-protected code in the system.
 *
 * __tsan_acquire/__tsan_release are the interface for exactly this: a
 * synchronisation primitive the compiler did not generate.  They
 * compile to nothing unless -fsanitize=thread is on.  See
 * doc/dis-parallel-plan.ms, step 0.
 */
#if defined(__has_feature)
#  if __has_feature(thread_sanitizer)
#    define TSANLOCKS 1
#  endif
#endif
#ifdef TSANLOCKS
void	__tsan_acquire(void*);
void	__tsan_release(void*);
#define	TSACQ(l)	__tsan_acquire(l)
#define	TSREL(l)	__tsan_release(l)
#else
#define	TSACQ(l)	USED(l)
#define	TSREL(l)	USED(l)
#endif

void
lock(Lock *l)
{
	int i;

	if(_tas(&l->val) == 0){
		TSACQ(l);
		return;
	}
	for(i=0; i<100; i++){
		if(_tas(&l->val) == 0){
			TSACQ(l);
			return;
		}
		osyield();
	}
	for(i=1;; i++){
		if(_tas(&l->val) == 0){
			TSACQ(l);
			return;
		}
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
	if(_tas(&l->val) != 0)
		return 0;
	TSACQ(l);
	return 1;
}

void
unlock(Lock *l)
{
	TSREL(l);
	/*
	 * A release store, not coherencefn() and a plain assignment.  The
	 * barrier was right, but the store is a data race under the C
	 * memory model whatever the hardware does, and it is the one
	 * ThreadSanitizer can still see after the annotations above -- 218
	 * of the 122 remaining reports on an eight-spawn run named this
	 * line.  __atomic_store_n with __ATOMIC_RELEASE says what
	 * coherencefn() plus the assignment meant, to the compiler and to
	 * the tool at once.
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
