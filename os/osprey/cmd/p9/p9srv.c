#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

/*
 * The personality as a 9P server: an exportfs over its own name space.
 * Where devmnt made the personality a 9P client of a server elsewhere,
 * p9srv answers 9P about the personality's own files - a T-message names
 * a fid, and the server walks, opens and reads the channel that fid
 * stands for in this name space, the way exportfs does.  It is reached
 * through a transport device (#X) so devmnt can mount it: the personality
 * mounts its own export and reads its own files back over 9P, a loopback
 * that proves the server serves the real name space.  The walk does not
 * follow mounts (nomount), so mounting the export does not recurse.
 */

enum { Nsfid = 64, Xmsize = 8192 };

typedef struct Sfid Sfid;
struct Sfid {
	ulong	fid;
	Chan	*c;
	int	used;
};

/* the export's fid table and one outstanding reply; the p9 library has a
 * data segment, so these statics are fine (unlike the flat-loaded server) */
static Sfid	sfids[Nsfid];
static uchar	xreply[Xmsize];
static long	xreplylen;
static long	xreplyrp;

static Sfid*
sfind(ulong fid)
{
	int i;
	for(i = 0; i < Nsfid; i++)
		if(sfids[i].used && sfids[i].fid == fid)
			return &sfids[i];
	return nil;
}

static Sfid*
salloc(ulong fid)
{
	int i;
	Sfid *s = sfind(fid);
	if(s != nil)
		return s;
	for(i = 0; i < Nsfid; i++)
		if(!sfids[i].used){
			sfids[i].used = 1;
			sfids[i].fid = fid;
			sfids[i].c = nil;
			return &sfids[i];
		}
	return nil;
}

/* serve one 9P message against this name space; return the R-message len */
static long
p9srv(uchar *msg, long n, uchar *rbuf, long rmax)
{
	Fcall t, r;
	Sfid *sf, *nsf;
	Chan *c;
	int i;

	if(convM2S(msg, n, &t) == 0)
		return 0;
	r.tag = t.tag;
	r.type = t.type + 1;

	switch(t.type){
	default:
		r.type = Rerror; r.ename = "not supported"; break;

	case Tversion:
		r.msize = t.msize < Xmsize ? t.msize : Xmsize;
		r.version = "9P2000";
		break;

	case Tauth:
		r.type = Rerror; r.ename = "no authentication required"; break;

	case Tattach:
		sf = salloc(t.fid);
		if(sf == nil){ r.type = Rerror; r.ename = "no fids"; break; }
		sf->c = cclone(up->slash);	/* the fid stands for the root */
		r.qid = sf->c->qid;
		break;

	case Twalk:
		sf = sfind(t.fid);
		if(sf == nil){ r.type = Rerror; r.ename = "unknown fid"; break; }
		c = cclone(sf->c);
		r.nwqid = 0;
		for(i = 0; i < t.nwname; i++){
			if(waserror())
				break;			/* walk raised: stop here */
			if(walk(&c, &t.wname[i], 1, 1, nil) < 0){
				poperror();
				break;
			}
			poperror();
			r.wqid[i] = c->qid;
			r.nwqid++;
		}
		if(t.nwname != 0 && r.nwqid == 0){
			cclose(c);
			r.type = Rerror; r.ename = "file does not exist"; break;
		}
		if(r.nwqid == t.nwname){		/* full walk: bind newfid */
			if(t.newfid == t.fid){
				cclose(sf->c);
				sf->c = c;
			} else {
				nsf = salloc(t.newfid);
				if(nsf == nil){ cclose(c); r.type = Rerror; r.ename = "no fids"; break; }
				nsf->c = c;
			}
		} else
			cclose(c);			/* partial walk: discard */
		break;

	case Topen:
		sf = sfind(t.fid);
		if(sf == nil){ r.type = Rerror; r.ename = "unknown fid"; break; }
		sf->c = devtab[sf->c->type]->open(sf->c, t.mode);
		r.qid = sf->c->qid;
		r.iounit = 0;
		break;

	case Tread:
		sf = sfind(t.fid);
		if(sf == nil){ r.type = Rerror; r.ename = "unknown fid"; break; }
		c = sf->c;
		{
			static uchar data[Xmsize];
			long cnt = t.count;
			if(cnt > Xmsize) cnt = Xmsize;
			r.count = devtab[c->type]->read(c, data, cnt, t.offset);
			r.data = (char*)data;
		}
		break;

	case Tclunk:
		sf = sfind(t.fid);
		if(sf != nil){
			if(sf->c != nil)
				cclose(sf->c);
			sf->used = 0;
		}
		break;
	}
	return convS2M(&r, rbuf, rmax);
}

/* transport device #X: devmnt bwrites a T-message, breads the R-message */

static Chan*
xattach(char *spec)
{
	return devattach('X', spec);
}

static Walkqid*
xwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, nil, 0, devgen);
}

static int
xstat(Chan *c, uchar *dp, int n)
{
	return devstat(c, dp, n, nil, 0, devgen);
}

static Chan*
xopen(Chan *c, int omode)
{
	c->mode = openmode(omode);
	c->flag |= COPEN;
	c->offset = 0;
	return c;
}

static void
xclose(Chan*)
{
}

static Block*
xbread(Chan*, long n, ulong)
{
	Block *b;
	long cnt;

	cnt = xreplylen - xreplyrp;
	if(cnt <= 0)
		return nil;
	if(cnt > n)
		cnt = n;
	b = allocb(cnt);
	memmove(b->wp, xreply + xreplyrp, cnt);
	b->wp += cnt;
	xreplyrp += cnt;
	return b;
}

static long
xbwrite(Chan*, Block *b, ulong)
{
	long n;

	n = BLEN(b);
	xreplylen = p9srv(b->rp, n, xreply, sizeof xreply);
	xreplyrp = 0;
	freeb(b);
	return n;
}

static long
xread(Chan *c, void *a, long n, vlong off)
{
	Block *b;
	long m;

	USED(c);
	b = xbread(c, n, off);
	if(b == nil)
		return 0;
	m = BLEN(b);
	memmove(a, b->rp, m);
	freeb(b);
	return m;
}

static long
xwrite(Chan *c, void *a, long n, vlong)
{
	Block *b;

	USED(c);
	b = allocb(n);
	memmove(b->wp, a, n);
	b->wp += n;
	return xbwrite(c, b, 0);
}

Dev expdevtab = {
	'X',
	"9pexp",

	devreset,
	devinit,
	devshutdown,
	xattach,
	xwalk,
	xstat,
	xopen,
	devcreate,
	xclose,
	xread,
	xbread,
	xwrite,
	xbwrite,
	devremove,
	devwstat,
};
