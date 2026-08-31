#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

/*
 * An in-process 9P server reached through a transport device that does
 * not leave the address space.  devmnt speaks real 9P to it: mountio
 * hands a T-message to this device's bwrite, and doread takes the
 * R-message back from its bread.  The marshalling (convS2M/convM2S) and
 * the mount client (devmnt) are the kernel's own; only the transport is
 * short - a function call rather than the microkernel ring.  Carrying
 * the same 9P across the ring to a server container is the next step;
 * this proves the file personality can name a server's files at all.
 *
 * The served tree is two files: the root directory and one file,
 * "hello", holding a fixed string.
 */

enum { Qroot = 0, Qhello = 1, Msize = 8192, Nfid = 64 };

static char hellodata[] = "hello from the 9P server, across the mount table\n";

static struct {
	ulong	fid;
	int	qid;		/* Qroot or Qhello */
	int	used;
} fids[Nfid];

/* one outstanding reply, since the transport is synchronous */
static uchar	replybuf[Msize];
static long	replylen;
static long	replyrp;

static int
findfid(ulong fid)
{
	int i;
	for(i = 0; i < Nfid; i++)
		if(fids[i].used && fids[i].fid == fid)
			return i;
	return -1;
}

static int
newfid(ulong fid)
{
	int i;
	i = findfid(fid);
	if(i >= 0)
		return i;
	for(i = 0; i < Nfid; i++)
		if(!fids[i].used){
			fids[i].used = 1;
			fids[i].fid = fid;
			fids[i].qid = Qroot;
			return i;
		}
	return -1;
}

static void
setqid(Qid *q, int which)
{
	q->path = which;
	q->vers = 0;
	q->type = which == Qroot ? QTDIR : QTFILE;
}

static void
mkdir(Dir *d, int which)
{
	memset(d, 0, sizeof *d);
	setqid(&d->qid, which);
	d->name = which == Qroot ? "/" : "hello";
	d->uid = d->gid = d->muid = "none";
	d->mode = which == Qroot ? (DMDIR|0555) : 0444;
	d->length = which == Qroot ? 0 : sizeof(hellodata)-1;
	d->type = 'L';
	d->dev = 0;
}

static void
respond(Fcall *r)
{
	replylen = convS2M(r, replybuf, sizeof replybuf);
	replyrp = 0;
}

static void
serve(uchar *msg, long n)
{
	Fcall t, r;
	Dir d;
	uchar statbuf[256];
	int i, f, nf;
	long cnt;

	if(convM2S(msg, n, &t) == 0){
		replylen = 0;
		return;
	}
	r.tag = t.tag;
	r.type = t.type + 1;		/* the matching R-type, unless overridden */

	switch(t.type){
	default:
		r.type = Rerror;
		r.ename = "not supported";
		break;

	case Tversion:
		r.msize = t.msize < Msize ? t.msize : Msize;
		r.version = "9P2000";
		break;

	case Tauth:
		r.type = Rerror;
		r.ename = "no authentication required";
		break;

	case Tattach:
		f = newfid(t.fid);
		if(f < 0){ r.type = Rerror; r.ename = "no fids"; break; }
		fids[f].qid = Qroot;
		setqid(&r.qid, Qroot);
		break;

	case Twalk:
		f = findfid(t.fid);
		if(f < 0){ r.type = Rerror; r.ename = "unknown fid"; break; }
		r.nwqid = 0;
		nf = fids[f].qid;
		for(i = 0; i < t.nwname; i++){
			if(nf == Qroot && strcmp(t.wname[i], "hello") == 0)
				nf = Qhello;
			else
				break;			/* no such name */
			setqid(&r.wqid[i], nf);
			r.nwqid++;
		}
		if(t.nwname != 0 && r.nwqid == 0){
			r.type = Rerror;
			r.ename = "file does not exist";
			break;
		}
		if(r.nwqid == t.nwname){		/* full walk: bind newfid */
			int g = newfid(t.newfid);
			if(g < 0){ r.type = Rerror; r.ename = "no fids"; break; }
			fids[g].qid = nf;
		}
		break;

	case Topen:
		f = findfid(t.fid);
		if(f < 0){ r.type = Rerror; r.ename = "unknown fid"; break; }
		setqid(&r.qid, fids[f].qid);
		r.iounit = 0;
		break;

	case Tread:
		f = findfid(t.fid);
		if(f < 0){ r.type = Rerror; r.ename = "unknown fid"; break; }
		cnt = t.count;
		if(fids[f].qid == Qhello){
			long len = sizeof(hellodata)-1;
			long off = t.offset;
			if(off >= len) off = len;
			if(cnt > len - off) cnt = len - off;
			r.data = hellodata + off;
			r.count = cnt;
		} else {			/* root directory */
			if(t.offset != 0){	/* one entry, then EOF */
				r.count = 0;
				r.data = (char*)statbuf;
			} else {
				mkdir(&d, Qhello);
				r.count = convD2M(&d, statbuf, sizeof statbuf);
				r.data = (char*)statbuf;
			}
		}
		break;

	case Tclunk:
		f = findfid(t.fid);
		if(f >= 0)
			fids[f].used = 0;
		break;

	case Tstat:
		f = findfid(t.fid);
		if(f < 0){ r.type = Rerror; r.ename = "unknown fid"; break; }
		mkdir(&d, fids[f].qid);
		r.nstat = convD2M(&d, statbuf, sizeof statbuf);
		r.stat = statbuf;
		break;
	}
	respond(&r);
}

/* transport device: a byte conduit devmnt bwrites requests to and breads replies from */

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
	serve(b->rp, n);
	freeb(b);
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
