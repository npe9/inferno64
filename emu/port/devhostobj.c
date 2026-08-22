/*
 * devhostobj - Styx access to the host-object registry (hostobj.c).
 *
 *	/dev/hostobj/ctl	text commands, one verb per line
 *	/dev/hostobj/N		the bytes of object N, when it has any
 *
 * The two-file split is deliberate and is the shape doc/hpc-plan.md item 6
 * argues every host-capability device should take: text for control, binary
 * for payload, and payload crossing the Styx boundary only when something
 * explicitly reads it. gpu(3)'s single-file request-then-reply shape is not
 * used here because it cannot stream, cannot let one proc produce while
 * another consumes, and moves bulk data on every call.
 *
 * ctl verbs:
 *	list		one line per live object: id type w h fmt len
 *	info id		the same, for one object
 *	test n		make an n-byte object filled with a known pattern
 *	free id		drop this registry's reference
 *
 * "test" exists so the registry and this device can be exercised with no
 * platform code at all - it is the producer used by hostobjtest(1), and it
 * means emu-g can run the tests even though every real producer is
 * macOS-only. Real producers (VideoToolbox, CoreML) register what they make
 * through hostobjnew() from a platform file.
 */
#include	"dat.h"
#include	"fns.h"
#include	"error.h"
#include	"hostobj.h"

enum
{
	Qdir,
	Qctl,
	Qobj,
};

#define TYPE(q)		((int)(q).path & 0xf)
#define OBJID(q)	((int)(q).path >> 4)
#define QID(o, t)	(((o)<<4) | (t))

enum
{
	Maxlist = 256,		/* objects reported by one gen/list */
	Maxresp = 8192,
};

/*
 * One pending reply per OPEN, hung off Chan.aux - not one global. Each open of
 * ctl is its own conversation, and several procs will have one at once; a
 * single shared reply would have them overwriting each other's answers. This
 * is the same per-handle arrangement devgpu.c uses, and the reason it uses it.
 */
typedef struct Ctlresp Ctlresp;
struct Ctlresp
{
	char*	s;
	int	len;
	int	off;
};

static void
setresp(Chan *c, char *s)
{
	Ctlresp *r;

	r = c->aux;
	if(r == nil){
		free(s);
		return;
	}
	free(r->s);
	r->s = s;
	r->len = s == nil? 0: strlen(s);
	r->off = 0;
}

static int
hostobjgen(Chan *c, char *unused_name, Dirtab *unused_tab, int unused_ntab, int s, Dir *dp)
{
	Qid q;
	Hostobj *o;
	char name[16];

	USED(unused_name); USED(unused_tab); USED(unused_ntab);
	if(s == DEVDOTDOT){
		mkqid(&q, QID(0, Qdir), 0, QTDIR);
		devdir(c, q, ".", 0, eve, DMDIR|0555, dp);
		return 1;
	}
	if(s == 0){
		mkqid(&q, QID(0, Qctl), 0, QTFILE);
		devdir(c, q, "ctl", 0, eve, 0666, dp);
		return 1;
	}
	/* By slot: see hostobjslot(). An empty slot is a hole, and returning 0
	 * tells devwalk/devdirread to skip it and keep going rather than stop. */
	if(s-1 >= hostobjnslot())
		return -1;
	o = hostobjslot(s-1);
	if(o == nil)
		return 0;
	snprint(name, sizeof(name), "%d", o->id);
	mkqid(&q, QID(o->id, Qobj), 0, QTFILE);
	devdir(c, q, name, o->len, eve, 0444, dp);
	hostobjput(o);
	return 1;
}

static Chan*
hostobjattach(char *spec)
{
	return devattach('O', spec);
}

static Walkqid*
hostobjwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, nil, 0, hostobjgen);
}

static int
hostobjstat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, nil, 0, hostobjgen);
}

static Chan*
hostobjopen(Chan *c, int omode)
{
	Hostobj *o;

	if((c->qid.type & QTDIR) == 0 && TYPE(c->qid) == Qobj){
		/* Fail the open rather than the first read if the object has
		 * already gone; the id is only a name and says nothing about
		 * whether it is still live. */
		o = hostobjget(OBJID(c->qid));
		if(o == nil)
			error(Enonexist);
		hostobjput(o);
	}
	c = devopen(c, omode, nil, 0, hostobjgen);
	if((c->qid.type & QTDIR) == 0 && TYPE(c->qid) == Qctl){
		c->aux = malloc(sizeof(Ctlresp));
		if(c->aux == nil){
			cclose(c);
			error(Enomem);
		}
		memset(c->aux, 0, sizeof(Ctlresp));
	}
	return c;
}

static void
hostobjclose(Chan *c)
{
	Ctlresp *r;

	r = c->aux;
	if(r != nil){
		c->aux = nil;
		free(r->s);
		free(r);
	}
}

static void
objline(char *buf, int nbuf, Hostobj *o)
{
	snprint(buf, nbuf, "%d %s %d %d %s %zud\n",
		o->id, o->type, o->w, o->h, o->fmt[0]? o->fmt: "-",
		(uintptr)o->len);
}

static long
hostobjread(Chan *c, void *va, long n, vlong off)
{
	Hostobj *o;
	Ctlresp *r;
	long m;

	if(c->qid.type & QTDIR)
		return devdirread(c, va, n, nil, 0, hostobjgen);

	if(TYPE(c->qid) == Qctl){
		r = c->aux;
		if(r == nil || r->s == nil)
			return 0;
		m = r->len - r->off;
		if(m > n)
			m = n;
		if(m > 0){
			memmove(va, r->s + r->off, m);
			r->off += m;
		}
		return m;
	}

	o = hostobjget(OBJID(c->qid));
	if(o == nil)
		error(Enonexist);
	m = hostobjbytes(o, va, n, off);
	hostobjput(o);
	return m;
}

/* The portable producer: a known pattern, so a test can verify every byte. */
static void
mktest(Chan *c, int len)
{
	Hostobj *o;
	uchar *d;
	int i;
	char buf[64];

	if(len <= 0 || len > 16*1024*1024)
		error(Ebadarg);
	d = malloc(len);
	if(d == nil)
		error(Enomem);
	for(i = 0; i < len; i++)
		d[i] = (uchar)(i & 0xff);
	o = hostobjnew("bytes", nil, nil, len);
	if(o == nil){
		free(d);
		error(Enomem);
	}
	o->data = d;
	snprint(buf, sizeof(buf), "%d\n", o->id);
	setresp(c, strdup(buf));
}

static long
hostobjwrite(Chan *c, void *va, long n, vlong off)
{
	Hostobj *o;
	char *buf, *f[4], *s;
	int nf, id, ids[Maxlist], nids, i, l;

	USED(off);
	if(TYPE(c->qid) != Qctl)
		error(Eperm);

	buf = malloc(n+1);
	if(buf == nil)
		error(Enomem);
	if(waserror()){
		free(buf);
		nexterror();
	}
	memmove(buf, va, n);
	buf[n] = 0;
	nf = tokenize(buf, f, nelem(f));
	if(nf < 1)
		error(Ebadctl);

	if(strcmp(f[0], "test") == 0 && nf == 2)
		mktest(c, atoi(f[1]));
	else if(strcmp(f[0], "list") == 0){
		s = malloc(Maxresp);
		if(s == nil)
			error(Enomem);
		s[0] = 0;
		l = 0;
		nids = hostobjlist(ids, Maxlist);
		for(i = 0; i < nids && l < Maxresp-128; i++){
			o = hostobjget(ids[i]);
			if(o == nil)
				continue;
			objline(s+l, Maxresp-l, o);
			l += strlen(s+l);
			hostobjput(o);
		}
		setresp(c, s);
	}else if(strcmp(f[0], "info") == 0 && nf == 2){
		id = atoi(f[1]);
		o = hostobjget(id);
		if(o == nil)
			error(Enonexist);
		s = malloc(128);
		if(s == nil){
			hostobjput(o);
			error(Enomem);
		}
		objline(s, 128, o);
		hostobjput(o);
		setresp(c, s);
	}else if(strcmp(f[0], "free") == 0 && nf == 2){
		id = atoi(f[1]);
		o = hostobjget(id);
		if(o == nil)
			error(Enonexist);
		hostobjput(o);	/* the reference just taken */
		hostobjput(o);	/* and the registry's own */
		setresp(c, nil);
	}else
		error(Ebadctl);

	poperror();
	free(buf);
	return n;
}

Dev hostobjdevtab = {
	'O',
	"hostobj",

	devinit,
	hostobjattach,
	hostobjwalk,
	hostobjstat,
	hostobjopen,
	devcreate,
	hostobjclose,
	hostobjread,
	devbread,
	hostobjwrite,
	devbwrite,
	devremove,
	devwstat,
};
