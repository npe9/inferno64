#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"ring9p.h"

/*
 * The transport device: devmnt speaks 9P to it, and it carries the 9P
 * across the microkernel ring to a file server that is a container of its
 * own (ring9p.c does the segattach and the ring round trip; srv9p.c, in
 * that container, answers).  mountio hands a T-message to bwrite, which
 * ships it over the ring and keeps the R-message; doread takes it back
 * from bread.  Nothing here holds a file or answers 9P - the bytes come
 * from across the ring, which is the whole point of the arc.
 */

enum { Msize = 8192 };

/* one outstanding reply, since the transport is synchronous; this device
 * is in the p9 library, which is loaded with a data segment, so a static
 * buffer is fine here (unlike the flat-loaded server) */
static uchar	replybuf[Msize];
static long	replylen;
static long	replyrp;

static Chan*
looattach(char *spec)
{
	return devattach('L', spec);
}

static Walkqid*
loowalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, nil, 0, devgen);
}

static int
loostat(Chan *c, uchar *dp, int n)
{
	return devstat(c, dp, n, nil, 0, devgen);
}

static Chan*
looopen(Chan *c, int omode)
{
	c->mode = openmode(omode);
	c->flag |= COPEN;
	c->offset = 0;
	return c;
}

static void
looclose(Chan*)
{
}

static Block*
loobread(Chan*, long n, ulong)
{
	Block *b;
	long cnt;

	cnt = replylen - replyrp;
	if(cnt <= 0)
		return nil;
	if(cnt > n)
		cnt = n;
	b = allocb(cnt);
	memmove(b->wp, replybuf + replyrp, cnt);
	b->wp += cnt;
	replyrp += cnt;
	return b;
}

static long
loobwrite(Chan*, Block *b, ulong)
{
	long n;

	n = BLEN(b);
	if(ring9p_init() < 0){
		freeb(b);
		error("9P transport: no ring to the file server");
	}
	replylen = ring9p_xfer(b->rp, n, replybuf, sizeof replybuf);
	replyrp = 0;
	freeb(b);
	if(replylen <= 0)
		error("9P transport: no reply from the file server");
	return n;
}

static long
looread(Chan *c, void *a, long n, vlong off)
{
	Block *b;
	long m;

	USED(c);
	b = loobread(c, n, off);
	if(b == nil)
		return 0;
	m = BLEN(b);
	memmove(a, b->rp, m);
	freeb(b);
	return m;
}

static long
loowrite(Chan *c, void *a, long n, vlong)
{
	Block *b;

	USED(c);
	b = allocb(n);
	memmove(b->wp, a, n);
	b->wp += n;
	return loobwrite(c, b, 0);
}

Dev looploopdevtab = {
	'L',
	"9ploop",

	devreset,
	devinit,
	devshutdown,
	looattach,
	loowalk,
	loostat,
	looopen,
	devcreate,
	looclose,
	looread,
	loobread,
	loowrite,
	loobwrite,
	devremove,
	devwstat,
};
