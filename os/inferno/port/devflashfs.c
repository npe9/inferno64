#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

/*
 * A read-only file system in addressable memory, served where it lies.
 *
 * The built-in root (devroot.c) already answers Dev.xip, but it is
 * compiled into the kernel: changing a file means relinking.  This is
 * the second provider, and the one a board with spare flash wants --
 * the image is written into a memory-mapped region and the kernel is
 * told where it is, so a Dis module in it is executed in place without
 * the loader copying it into RAM.  See doc/xip.ms and
 * doc/pycubed-plan.ms phase 3.
 *
 * The device is #G.  It is not os/inferno/port/devflash.c, which is
 * #F and is the opposite thing: a driver that programs NOR flash
 * through flashif.h.  This one does not write anything and does not
 * know what the memory is; it only needs it to be addressable.
 *
 * A board sets flashfsbase and flashfslen before chandevreset(); zero means
 * there is none and attaching fails, so a kernel can carry the driver
 * and a board need not have the memory.  The format is the one
 * utils/mkflashfs writes, and its header is checked at attach: a region
 * that does not start with the magic is not silently served as an empty
 * directory.
 *
 * One flat directory.  A board's spare flash is not a place that wants
 * a tree, and a tree is what mount points are for.
 */

enum {
	Namelen	= 56,
	Hdrlen	= 24,
	Entlen	= 8+Namelen,
	Version	= 1,
	Qdir	= 0,		/* qid.path 0 is the directory, files are 1.. */
};

uchar*	flashfsbase;		/* set by the board; nil means none */
u32	flashfslen;

static uchar*	fsbase;
static int	nfile;

static u32
get32(uchar *p)
{
	return (u32)p[0] | ((u32)p[1]<<8) | ((u32)p[2]<<16) | ((u32)p[3]<<24);
}

static uchar*
entry(int i)
{
	return fsbase + Hdrlen + i*Entlen;
}

/*
 * Whole-image check, done once at attach rather than per access: every
 * entry has to lie inside the image, so nothing below has to bounds
 * check again and a corrupt region is refused rather than handed out.
 */
static char*
flashfscheck(uchar *base, u32 len)
{
	u32 total, off, n;
	int i, nf, j;
	uchar *e;
	char *nm;

	if(base == nil || len < Hdrlen)
		return "no flash file system";
	if(memcmp(base, "flashfs", 8) != 0)
		return "bad flash file system magic";
	if(get32(base+8) != Version)
		return "wrong flash file system version";
	nf = get32(base+12);
	total = get32(base+16);
	if(total > len || total < Hdrlen)
		return "flash file system longer than its region";
	if(nf < 0 || (u32)nf > (total-Hdrlen)/Entlen)
		return "implausible flash file count";
	for(i = 0; i < nf; i++) {
		e = base + Hdrlen + i*Entlen;
		off = get32(e+0);
		n = get32(e+4);
		if(off > total || n > total || off+n > total)
			return "flash file outside the image";
		nm = (char*)e+8;
		for(j = 0; j < Namelen; j++)
			if(nm[j] == 0)
				break;
		if(j == 0 || j == Namelen)
			return "bad flash file name";
	}
	return nil;
}

static int
flashfsgen(Chan *c, char *name, Dirtab *tab, s32 ntab, s32 i, Dir *dp)
{
	uchar *e;
	Qid q;

	USED(name); USED(tab); USED(ntab);
	if(i == DEVDOTDOT) {
		mkqid(&q, Qdir, 0, QTDIR);
		devdir(c, q, "#G", 0, eve, DMDIR|0555, dp);
		return 1;
	}
	if(i >= nfile)
		return -1;
	e = entry(i);
	mkqid(&q, i+1, 0, QTFILE);
	devdir(c, q, (char*)e+8, get32(e+4), eve, 0444, dp);
	return 1;
}

static Chan*
flashfsattach(char *spec)
{
	char *err;

	if(*spec)
		error(Ebadspec);
	err = flashfscheck(flashfsbase, flashfslen);
	if(err != nil)
		error(err);
	fsbase = flashfsbase;
	nfile = get32(fsbase+12);
	return devattach('G', spec);
}

static Walkqid*
flashfswalk(Chan *c, Chan *nc, char **name, s32 nname)
{
	return devwalk(c, nc, name, nname, nil, 0, flashfsgen);
}

static s32
flashfsstat(Chan *c, uchar *db, s32 n)
{
	return devstat(c, db, n, nil, 0, flashfsgen);
}

static Chan*
flashfsopen(Chan *c, u32 omode)
{
	if((omode & (OWRITE|OTRUNC)) || omode == OEXEC && (c->qid.type & QTDIR))
		error(Eperm);
	return devopen(c, omode, nil, 0, flashfsgen);
}

static void
flashfsclose(Chan *c)
{
	USED(c);
}

/*
 * The one file whose bytes are somewhere: qid.path i+1 is entry i.
 */
static uchar*
filedata(Chan *c, u32 *lenp)
{
	uchar *e;
	u32 p;

	p = c->qid.path;
	if(p == Qdir || p > (u32)nfile)
		return nil;
	e = entry(p-1);
	*lenp = get32(e+4);
	return fsbase + get32(e+0);
}

static s32
flashfsread(Chan *c, void *buf, s32 n, s64 offset)
{
	uchar *data;
	u32 len;

	if(c->qid.type & QTDIR)
		return devdirread(c, buf, n, nil, 0, flashfsgen);
	data = filedata(c, &len);
	if(data == nil)
		error(Egreg);
	if(offset < 0 || offset >= len)
		return 0;
	if(offset+n > len)
		n = len - offset;
	memmove(buf, data+offset, n);
	return n;
}

static s32
flashfswrite(Chan*, void*, s32, s64)
{
	error(Eperm);
	return 0;
}

/*
 * Execute in place.  The region is memory-mapped and read-only for the
 * life of the kernel, which is exactly what Dev.xip promises
 * (os/inferno/port/portdat.h), so a module here is never copied.
 */
static void*
flashfsxip(Chan *c, u32 *lenp)
{
	if(c->qid.type & QTDIR)
		return nil;
	return filedata(c, lenp);
}

Dev flashfsdevtab = {
	'G',
	"flash",

	devreset,
	devinit,
	devshutdown,
	flashfsattach,
	flashfswalk,
	flashfsstat,
	flashfsopen,
	devcreate,
	flashfsclose,
	flashfsread,
	devbread,
	flashfswrite,
	devbwrite,
	devremove,
	devwstat,
	nil,		/* power */
	nil,		/* config */
	flashfsxip,
};
