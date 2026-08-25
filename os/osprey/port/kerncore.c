#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

/*
 * Kernel core that is not name space.  These functions lived in chan.c
 * and sysproc.c because that is where Plan 9 put them, but they are the
 * reference counting the whole kernel turns on, two string helpers, the
 * device bring-up main() calls at boot, a byte swap the reboot path
 * uses, and the do-nothing sleep predicate.  None is name space, so they
 * belong here, linked into every configuration, and the microkernel
 * keeps them while it drops chan.c and sysproc.c.  chandevinit stays in
 * chan.c, and is reproduced in the microkernel's own configuration
 * without one line: the kproc that drains the channel-close queue, which
 * a kernel with no channels never fills.
 */

long
incref(Ref *r)
{
	long old, new;

	do {
		old = r->ref;
		new = old+1;
	} while(!cmpswap(&r->ref, old, new));
	return new;
}

long
decref(Ref *r)
{
	long old, new;

	do {
		old = r->ref;
		if(old <= 0)
			panic("decref pc=%#p", getcallerpc(&r));
		new = old-1;
	} while(!cmpswap(&r->ref, old, new));
	return new;
}

/*
 * Rather than strncpy, which zeros the rest of the buffer, kstrcpy
 * truncates if necessary, always zero terminates, does not zero fill,
 * and puts ... at the end of the string if it's too long.  Usually used to
 * save a string in up->genbuf;
 */
void
kstrcpy(char *s, char *t, int ns)
{
	int nt;

	nt = strlen(t);
	if(nt < ns){
		memmove(s, t, nt);
		s[nt] = '\0';
		return;
	}
	/* too long, truncate */
	nt = ns-1;
	memmove(s, t, nt);
	s[nt] = '\0';
	/* append ... if there is space */
	ns -= 4;
	if(ns < 0)
		return;
	/* look for first byte of UTF-8 sequence by skipping continuation bytes */
	while(ns>0 && (s[--ns]&0xC0)==0x80)
		;
	strcpy(s+ns, "...");
}

int
emptystr(char *s)
{
	if(s == nil)
		return 1;
	if(s[0] == '\0')
		return 1;
	return 0;
}

/*
 * Atomically replace *p with copy of s
 */
void
kstrdup(char **p, char *s)
{
	int n;
	char *t, *prev;

	n = strlen(s);
	/* if it's a user, we can wait for memory; if not, something's very wrong */
	if(up != nil)
		t = smalloc(n+1);
	else{
		t = malloc(n+1);
		if(t == nil)
			panic("kstrdup: no memory");
	}
	setmalloctag(t, getcallerpc(&p));
	memmove(t, s, n);
	t[n] = '\0';
	prev = *p;
	*p = t;
	free(prev);
}

void
chandevreset(void)
{
	int i;

	todinit();	/* avoid later reentry causing infinite recursion */
	for(i=0; devtab[i] != nil; i++)
		devtab[i]->reset();
}

void
chandevshutdown(void)
{
	int i;

	/* shutdown in reverse order */
	for(i=0; devtab[i] != nil; i++)
		;
	for(i--; i >= 0; i--)
		devtab[i]->shutdown();
}

ulong
beswal(ulong l)
{
	uchar *p;

	p = (uchar*)&l;
	return (p[0]<<24) | (p[1]<<16) | (p[2]<<8) | p[3];
}

int
return0(void*)
{
	return 0;
}
