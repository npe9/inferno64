#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

/*
 * The time device: one file, bintime, which is what nsec(2) reads.
 *
 * nsec(2) looks like a system call and is not one.  9front's libc reads
 * /dev/bintime and takes the first eight bytes of it, big-endian, as the
 * nanoseconds; the _NSEC trap exists for binary compatibility and no
 * current libc uses it.  So a program that asks the time on the server
 * personality is asking its name space for a file, and the file has to be
 * here - it is the buddy that holds a program's name space.
 *
 * The clock is not the personality's, though: this is a user task on the
 * microkernel and p9shim.c's seconds() answers 0.  The kernel keeps the
 * time (a task with the console capability sets it, ReqSettime), so each
 * read asks the kernel for it (ReqNsec) rather than caching a value that
 * would be stale by the next read.
 *
 * devcons serves this file in a Plan 9 kernel, with three more fields
 * after the nanoseconds - the fast-tick counter, its frequency, and
 * uptime.  All four are here, since uptime(2) and fastticks(2) read the
 * same file and a short read would leave them reading whatever followed
 * in the caller's buffer.
 */

enum {
	Qdir = 0,
	Qbintime,
	ReqNsec = 36,		/* devosprey.c's xcall op */
};

static Dirtab timedir[] = {
	".",		{Qdir, 0, QTDIR},	0,	DMDIR|0555,
	"bintime",	{Qbintime},		24,	0444,
};

extern long ospreyxcall(int, uvlong*, long);

/* the kernel's clock, also read by devinput.c for the mouse's timestamp */
vlong
p9nsec(void)
{
	uvlong args[5];

	memset(args, 0, sizeof args);
	if(ospreyxcall(ReqNsec, args, 0) < 0)
		return 0;
	return (vlong)args[0];
}

static void
put64(uchar *p, uvlong v)
{
	p[0] = v >> 56; p[1] = v >> 48; p[2] = v >> 40; p[3] = v >> 32;
	p[4] = v >> 24; p[5] = v >> 16; p[6] = v >> 8;  p[7] = v;
}

static Chan*
timeattach(char *spec)
{
	return devattach('T', spec);
}

static Walkqid*
timewalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, timedir, nelem(timedir), devgen);
}

static int
timestat(Chan *c, uchar *dp, int n)
{
	return devstat(c, dp, n, timedir, nelem(timedir), devgen);
}

static Chan*
timeopen(Chan *c, int omode)
{
	return devopen(c, omode, timedir, nelem(timedir), devgen);
}

static void
timeclose(Chan*)
{
}

static long
timeread(Chan *c, void *a, long n, vlong off)
{
	uchar b[24];
	vlong t;

	if(c->qid.type & QTDIR)
		return devdirread(c, a, n, timedir, nelem(timedir), devgen);
	if((ulong)c->qid.path != Qbintime)
		error(Egreg);
	t = p9nsec();
	/*
	 * nanoseconds, then the fast-tick counter and its frequency.  There
	 * is no separate fast clock here, so the nanoseconds are the ticks
	 * and the frequency is a nanosecond's: fastticks(2) then measures
	 * real time, which is what it is for, at the resolution the kernel's
	 * clock actually has rather than a finer one that would be a lie.
	 */
	put64(b + 0, (uvlong)t);
	put64(b + 8, (uvlong)t);
	put64(b + 16, 1000000000ULL);
	if(off < 0 || off >= (vlong)sizeof b)
		return 0;
	if(n > (long)sizeof b - (long)off)
		n = (long)sizeof b - (long)off;
	memmove(a, b + off, n);
	return n;
}

static long
timewrite(Chan*, void*, long, vlong)
{
	error(Eperm);
	return 0;
}

Dev timedevtab = {
	'T',
	"time",

	devreset,
	devinit,
	devshutdown,
	timeattach,
	timewalk,
	timestat,
	timeopen,
	devcreate,
	timeclose,
	timeread,
	devbread,
	timewrite,
	devbwrite,
	devremove,
	devwstat,
};
