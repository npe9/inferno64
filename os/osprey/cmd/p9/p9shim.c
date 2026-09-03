/*
 * p9shim.c - the bodies the Plan 9 namespace library needs that the
 * microkernel does not provide: the error unwinding, single-threaded
 * lock stubs, refcounts, allocation, blocks, and process/sync stubs.
 * Same shape as the draw server's kshim.c, one layer up.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "../port/error.h"

static Mach ospreymach0;
Mach *machp[1] = { &ospreymach0 };
Conf conf;
int cpuserver = 0;
void* xalloc(ulong n){ return mallocz(n, 1); }
void* xspanalloc(ulong n, int align, ulong span){ USED(align); USED(span); return mallocz(n, 1); }

int readnum(ulong off, char *buf, ulong n, ulong val, int size){
	char tmp[64];
	snprint(tmp, sizeof tmp, "%*lud", size-1, val);
	tmp[size-1] = ' ';
	if(off >= (ulong)size) return 0;
	if(off+n > (ulong)size) n = size-off;
	memmove(buf, tmp+off, n);
	return n;
}
int emptystr(char *s){ return s == nil || s[0] == '\0'; }
int return0(void *a){ USED(a); return 0; }

static Proc	theproc;
static char	errbuf0[ERRMAX], errbuf1[ERRMAX];
Proc	*up = &theproc;
char	*eve = "";
extern void exits(char*);

char Enoerror[] = "Enoerror";
char Emount[] = "Emount";
char Eunmount[] = "Eunmount";
char Eismtpt[] = "Eismtpt";
char Eunion[] = "Eunion";
char Emountrpc[] = "Emountrpc";
char Eshutdown[] = "Eshutdown";
char Enocreate[] = "Enocreate";
char Enonexist[] = "Enonexist";
char Eexist[] = "Eexist";
char Ebadsharp[] = "Ebadsharp";
char Enotdir[] = "Enotdir";
char Eisdir[] = "Eisdir";
char Ebadchar[] = "Ebadchar";
char Efilename[] = "Efilename";
char Eperm[] = "Eperm";
char Ebadusefd[] = "Ebadusefd";
char Ebadarg[] = "Ebadarg";
char Einuse[] = "Einuse";
char Eio[] = "Eio";
char Etoobig[] = "Etoobig";
char Etoosmall[] = "Etoosmall";
char Enoport[] = "Enoport";
char Ehungup[] = "Ehungup";
char Ebadctl[] = "Ebadctl";
char Enodev[] = "Enodev";
char Eprocdied[] = "Eprocdied";
char Enochild[] = "Enochild";
char Eioload[] = "Eioload";
char Enovmem[] = "Enovmem";
char Ebadfd[] = "Ebadfd";
char Enofd[] = "Enofd";
char Eisstream[] = "Eisstream";
char Ebadexec[] = "Ebadexec";
char Etimedout[] = "Etimedout";
char Econrefused[] = "Econrefused";
char Econinuse[] = "Econinuse";
char Eintr[] = "Eintr";
char Enomem[] = "Enomem";
char Esoverlap[] = "Esoverlap";
char Emouseset[] = "Emouseset";
char Eshort[] = "Eshort";
char Egreg[] = "Egreg";
char Ebadspec[] = "Ebadspec";
char Enoreg[] = "Enoreg";
char Enoattach[] = "Enoattach";
char Eshortstat[] = "Eshortstat";
char Ebadstat[] = "Ebadstat";
char Enegoff[] = "Enegoff";
char Ecmdargs[] = "Ecmdargs";
char Ebadip[] = "Ebadip";
char Edirseek[] = "Edirseek";
char Etoolong[] = "Etoolong";
char Echange[] = "Echange";

void
p9init(void)
{
	up->user = eve;
	up->errstr = errbuf0;
	up->syserrstr = errbuf1;
	up->nerrlab = 0;
}

_Noreturn void
error(char *s)
{
	kstrcpy(up->errstr, s, ERRMAX);
	nexterror();
}

_Noreturn void
nexterror(void)
{
	longjmp(up->errlab[--up->nerrlab], 1);
}

/* single-threaded for now: the locks are stubs */
void	lock(Lock*){}
int	canlock(Lock*){ return 1; }
void	unlock(Lock*){}
void	ilock(Lock*){}
void	iunlock(Lock*){}
void	qlock(QLock*){}
int	canqlock(QLock*){ return 1; }
void	qunlock(QLock*){}
void	rlock(RWLock*){}
int	canrlock(RWLock*){ return 1; }
void	runlock(RWLock*){}
void	wlock(RWLock*){}
void	wunlock(RWLock*){}

long	incref(Ref *r){ return ++r->ref; }
long	decref(Ref *r){ return --r->ref; }

void*
smalloc(ulong n)
{
	void *p;

	p = mallocz(n, 1);
	if(p == nil)
		error(Enomem);
	return p;
}

void
kstrcpy(char *s, char *t, int ns)
{
	int n;

	n = strlen(t);
	if(n >= ns)
		n = ns-1;
	memmove(s, t, n);
	s[n] = 0;
}

void
kstrdup(char **p, char *b)
{
	int n;
	char *s;

	n = strlen(b)+1;
	s = smalloc(n);
	memmove(s, b, n);
	*p = s;
}

Block*
allocb(int size)
{
	Block *b;

	b = mallocz(sizeof(Block)+size+64, 1);
	if(b == nil)
		error(Enomem);
	b->base = (uchar*)b + sizeof(Block);
	b->rp = b->wp = b->base;
	b->lim = b->base + size + 64;
	return b;
}

void
freeb(Block *b)
{
	if(b != nil)
		free(b);
}

_Noreturn void
panic(char *fmt, ...)
{
	USED(fmt);
	print("p9: panic: %s\n", fmt);
	exits("panic");
}

/* pexit, kproc, tsleep, wakeup, sleep(ksleep), sched, ready live in
 * p9sched.c now; setlabel/gotolabel in xcall.s. */
long	seconds(void){ return 0; }

/* an empty device table for now: the mount/9P device comes next */
extern Dev rootdevtab;
extern Dev envdevtab;
extern Dev mntdevtab;
extern Dev looploopdevtab;
extern Dev expdevtab;
extern Dev pipedevtab;
extern Dev srvdevtab;
extern Dev lfsdevtab;
extern Dev ipdevtab;
Dev *devtab[] = { &rootdevtab, &envdevtab, &mntdevtab, &looploopdevtab, &expdevtab, &pipedevtab, &srvdevtab, &lfsdevtab, &ipdevtab, nil };

long	kerndate = 0;


int
openmode(ulong o)
{
	o &= ~(OTRUNC|OCEXEC|ORCLOSE);
	if(o > OEXEC)
		error(Ebadarg);
	if(o == OEXEC)
		return OREAD;
	return o;
}

/*
 * A bump allocator that never reuses, so freshly handed-out memory is
 * still the zero the BSS arena started as (newpgrp and the name space
 * rely on that).  Each block carries a sixteen-byte header holding its
 * usable size, so msize and realloc work; realloc always allocates
 * fresh and copies, since the bump arena cannot grow a block in place.
 */
static char	arena[1024*1024];
static ulong	arenap;
enum { AHDR = 16 };
void*
malloc(ulong n)
{
	char *p;
	n = (n + 15) & ~15UL;
	if(arenap + AHDR + n > sizeof arena)
		return nil;
	p = arena + arenap;
	arenap += AHDR + n;
	*(ulong*)p = n;
	return p + AHDR;
}
void*	mallocz(ulong n, int clr){ void *p = malloc(n); if(p && clr) memset(p, 0, n); return p; }
ulong	msize(void *v){ return v == nil ? 0 : *(ulong*)((char*)v - AHDR); }
void*
realloc(void *v, ulong n)
{
	void *p;
	ulong old;

	if(n == 0)
		return nil;			/* callers treat a size-0 realloc as free */
	p = malloc(n);
	if(p != nil && v != nil){
		old = msize(v);
		memmove(p, v, old < n ? old : n);
	}
	return p;
}
void	free(void*){}
void	setmalloctag(void*, uintptr){}

/* the name space's owner test; the personality runs as eve */
int	iseve(void){ return strcmp(up->user, eve) == 0; }

void*
vmemchr(void *ss, int c, ulong n)
{
	uchar *s;

	s = ss;
	while(n != 0){ n--;
		if(*s == c)
			return s;
		s++;
	}
	return nil;
}

/* two small kernel functions the name space needs, from proc.c/kerncore.c */
void	todinit(void){}

Pgrp*
newpgrp(void)
{
	Pgrp *p;

	p = malloc(sizeof(Pgrp));	/* arena malloc returns zeroed memory */
	if(p == nil)
		error(Enomem);
	p->ref = 1;
	return p;
}

void
chandevreset(void)
{
	int i;
	extern void schedinit(void);

	schedinit();		/* make the server proc 0 before any reset starts a kproc */
	todinit();
	for(i = 0; devtab[i] != nil; i++)
		devtab[i]->reset();
}

/*
 * The mount client (devmnt) and the queue it buffers replies in pull in
 * a few more kernel primitives.  Single-threaded, the locks are no-ops
 * and sleep only ever waits on a condition already made true by the
 * synchronous transport; the cache is never enabled, so its entry points
 * are stubs a cachedchan() guard keeps unreached.
 */
void	coherence(void){}
void	eqlock(QLock*){}
void	exhausted(char *why){ panic("exhausted: %s", why); }

/*
 * No kernel sleep: libc's sleep (the SLEEP syscall, which services the
 * ring) is the single definition, so the ring transport can yield with
 * it.  devmnt's and qio's own sleep calls are all on the mux-gate and
 * read-ahead paths a single outstanding synchronous RPC never reaches
 * (Arc 1 ran the whole 9P mount without ever entering one).
 */

void	cinit(void){}
int	copen(Chan*){ return 0; }
void	cclunk(Chan*){}
int	cread(Chan*, uchar*, int, vlong){ return 0; }
void	ctrunc(Chan*){}
void	cupdate(Chan*, uchar*, int, vlong){}
void	cwrite(Chan*, uchar*, int, vlong){}

/*
 * qio reaches for the interrupt-time block pool and the scheduler.  With
 * one process and a synchronous transport there is no interrupt path and
 * nothing to reschedule: interrupt allocation is ordinary allocation, the
 * pooled path is declined so copyblock falls back to allocb, and islo/
 * sched are the trivial answers.  validstat trusts the server we wrote.
 */
Block*	iallocb(int n){ return allocb(n); }
Block*	iallocbp(Bpool*){ return nil; }
int	islo(void){ return 1; }
/* sched() lives in p9sched.c */
void	validstat(uchar*, int){}
Conf	conf;

int
readstr(ulong off, char *buf, ulong n, char *str)
{
	ulong size;

	size = strlen(str);
	if(off >= size)
		return 0;
	if(off + n > size)
		n = size - off;
	memmove(buf, str + off, n);
	return n;
}
