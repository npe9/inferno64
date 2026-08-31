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

/* process and sync primitives: stubs until wired to the microkernel */
void	pexit(char *s, int f){ USED(s); USED(f); exits(nil); }
void	kproc(char *n, void (*f)(void*), void *a){ USED(n); USED(f); USED(a); }
void	tsleep(Rendez *r, int (*f)(void*), void *a, ulong ms){ USED(r); USED(f); USED(a); USED(ms); }
Proc*	wakeup(Rendez *r){ USED(r); return nil; }
int	setlabel(Label *l){ USED(l); return 0; }
void	gotolabel(Label *l){ USED(l); }
long	seconds(void){ return 0; }

/* an empty device table for now: the mount/9P device comes next */
extern Dev rootdevtab;
extern Dev envdevtab;
Dev *devtab[] = { &rootdevtab, &envdevtab, nil };

long	kerndate = 0;

void	muxclose(Mnt*){}		/* until the mount/9P device exists */

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

	todinit();
	for(i = 0; devtab[i] != nil; i++)
		devtab[i]->reset();
}
