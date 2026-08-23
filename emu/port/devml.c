/*
 * devml - inference device: a machine-learning model as a directory.
 *
 * #N binds to /dev like #i does, so instances are /dev/ml/N. Open
 * /dev/ml/clone to get a fresh one; that same fd becomes its ctl file and
 * reading it gives the instance number, exactly as /dev/draw/new does.
 *
 * Per instance:
 *	ctl	verbs below; read gives the instance number
 *	model	write the .mlmodel bytes here, then "load" on ctl
 *	info	what the loaded model takes and returns, and what ran it
 *	in	input data for the selected input
 *	out	the result, after "run"
 *
 * A directory rather than gpu(3)'s single request/response file, because a
 * model has four genuinely different things to say: bulk write-once bytes, a
 * read-only description, an input and an output. Carrying those on one file
 * means inventing a framing protocol - which is what gpu(3) had to do, and
 * why it is not the template for anything that streams.
 *
 * The model crosses as BYTES, never as a host path. An Inferno path is not a
 * host path: it may name a file on a Styx mount from another machine, or one
 * that exists only in this process's namespace, and handing it to a host
 * framework punctures the namespace for no gain. This is not a guess about
 * what the host will accept - CoreML's compileModelAtURL: takes a staged
 * single-file .mlmodel and returns a compiled one, which was checked before
 * this protocol was written (see mlcaps.m).
 *
 * "info" is not a convenience. A client cannot form a valid write to "in"
 * without the input's name, element type and shape, so publishing them is
 * what makes the device usable at all. Its lines are:
 *
 *	in <name> <type> <dim>...
 *	out <name> <type> <dim>...
 *	device <what actually ran it>
 *
 * That last line says what ran, not what was asked for. gpu(3) shipped that
 * distinction wrong once - it reported the precision requested while the wire
 * carried something else - and the same mistake is available here, because
 * MLModelConfiguration.computeUnits is a request that CoreML may not honour.
 * The backend is required to report the device it observes, and to say
 * "requested" plainly if it cannot observe one.
 *
 * "in" and "out" carry raw elements of the type "info" gives, big-endian, as
 * devgpu's wire already is and as Limbo's math->export_real/export_real32
 * already produce - so a caller marshals with what it has, and a model
 * reached across a Styx mount from a different-endian machine still gets the
 * bytes it meant. Converting to whatever the host framework wants is the
 * backend's job, since that is the end that knows the element type.
 *
 * ctl verbs:
 *	units cpu|gpu|ane|all	which compute units to ask for; before "load"
 *	load			compile and load the bytes written to "model"
 *	feed <name>		which input subsequent writes to "in" fill
 *	take <name>		which output subsequent reads of "out" drain
 *	run			run the model, then fetch the output
 *	reset			discard the model bytes and start over
 *
 * The numeric work is not this file's job. It dispatches through the nullable
 * ml* hooks below, the same convention devdraw.c uses for gpudrawfillpoly3d
 * and devgpu.c for gpuhwspmv: a platform backend assigns them at load time
 * (win-ml.m does, with CoreML), and where none is linked every operation
 * fails cleanly rather than being #ifdef'd out. Plain C types only, so a
 * backend needs no Inferno headers.
 */
#include	"dat.h"
#include	"fns.h"
#include	"error.h"

enum
{
	Qtopdir,
	Qclone,
	Q2nd,
	Q3rd,
	Qctl,
	Qmodel,
	Qinfo,
	Qin,
	Qout,

	Maxmodel	= 512*1024*1024,	/* refuse a runaway write */
};

#define	TYPE(q)		((int)(q).path & 0xf)
#define	SLOT(q)		((int)((q).path >> 4) - 1)
#define	MKPATH(s, t)	((((s)+1) << 4) | (t))

/*
 * Nullable backend hooks. Every one reports failure by returning -1 (or nil)
 * and filling err, so the device never has to guess why something did not
 * work - the message the host framework gave is what reaches the caller's
 * %r, which is the only way a wrong model or a wrong input size is
 * diagnosable from Limbo.
 */
void*	(*mlopenmodel)(uchar *spec, int nspec, char *units, char *err, int nerr);
void	(*mlclosemodel)(void *m);
int	(*mlmodelinfo)(void *m, char *buf, int nbuf);
int	(*mlsetinput)(void *m, char *name, uchar *b, int n, char *err, int nerr);
int	(*mlrunmodel)(void *m, char *err, int nerr);
int	(*mlgetoutput)(void *m, char *name, uchar *b, int nbuf, char *err, int nerr);

typedef struct Mstate Mstate;
struct Mstate
{
	int	inuse;
	int	id;
	QLock	l;		/* one operation at a time on an instance */

	uchar	*spec;		/* .mlmodel bytes as written to "model" */
	int	nspec;
	int	aspec;

	void	*m;		/* backend model, or nil until "load" */
	char	units[16];
	char	*feed;		/* selected input name, or nil for the only one */
	char	*take;		/* selected output name, or nil */

	uchar	*out;		/* result pending on "out" */
	int	nout;
};

/*
 * As in devgpu.c this is an array of POINTERS and that is load-bearing:
 * growing it reallocates the pointer array, and an Mstate that moved while a
 * read or write held it would be a use-after-free. Individual Mstates never
 * move.
 */
static Mstate	**mtab;
static int	nmtab;
static Lock	mtablock;
static int	nextid = 1;

static char Enomodel[] = "no model loaded";
static char Enobackend[] = "no inference backend on this platform";

static int
newinstance(void)
{
	int i;
	Mstate **nt, *m;

	lock(&mtablock);
	for(i = 0; i < nmtab; i++)
		if(mtab[i] == nil || !mtab[i]->inuse)
			break;
	if(i == nmtab){
		nt = malloc((nmtab+8) * sizeof(Mstate*));
		if(nt == nil){
			unlock(&mtablock);
			return -1;
		}
		if(mtab != nil)
			memmove(nt, mtab, nmtab * sizeof(Mstate*));
		memset(nt+nmtab, 0, 8 * sizeof(Mstate*));
		free(mtab);	/* only the pointer array moves, never an Mstate */
		mtab = nt;
		nmtab += 8;
	}
	if(mtab[i] == nil){
		m = malloc(sizeof(Mstate));
		if(m == nil){
			unlock(&mtablock);
			return -1;
		}
		memset(m, 0, sizeof(Mstate));
		mtab[i] = m;
	}
	m = mtab[i];
	m->inuse = 1;
	m->id = nextid++;
	strcpy(m->units, "all");
	unlock(&mtablock);
	return i;
}

/* Drop everything an instance holds. Called with no lock held. */
static void
mlfree(Mstate *m)
{
	void *bm;

	bm = m->m;
	m->m = nil;
	if(bm != nil && mlclosemodel != nil)
		mlclosemodel(bm);
	free(m->spec);	m->spec = nil;	m->nspec = m->aspec = 0;
	free(m->feed);	m->feed = nil;
	free(m->take);	m->take = nil;
	free(m->out);	m->out = nil;	m->nout = 0;
	strcpy(m->units, "all");
	m->inuse = 0;
}

static Mstate*
instance(Chan *c)
{
	int s;
	Mstate *m;

	s = SLOT(c->qid);
	lock(&mtablock);
	if(s < 0 || s >= nmtab || mtab[s] == nil || !mtab[s]->inuse){
		unlock(&mtablock);
		return nil;
	}
	m = mtab[s];
	unlock(&mtablock);
	return m;
}

static int
mlgen(Chan *c, char *name, Dirtab *tab, int ntab, int s, Dir *dp)
{
	Qid q;
	int t, i, slot;
	static char *files[] = { "ctl", "model", "info", "in", "out" };
	static int ftype[] = { Qctl, Qmodel, Qinfo, Qin, Qout };

	USED(name); USED(tab); USED(ntab);
	q.vers = 0;

	if(s == DEVDOTDOT){
		switch(TYPE(c->qid)){
		case Qtopdir:
		case Q2nd:
			mkqid(&q, Qtopdir, 0, QTDIR);
			devdir(c, q, "#N", 0, eve, DMDIR|0555, dp);
			break;
		default:
			mkqid(&q, Q2nd, 0, QTDIR);
			devdir(c, q, "ml", 0, eve, DMDIR|0555, dp);
			break;
		}
		return 1;
	}

	t = TYPE(c->qid);
	if(t == Qtopdir){
		if(s != 0)
			return -1;
		mkqid(&q, Q2nd, 0, QTDIR);
		devdir(c, q, "ml", 0, eve, DMDIR|0555, dp);
		return 1;
	}

	/* second level: "clone" and one directory per live instance */
	if(t == Q2nd || t == Qclone){
		if(s == 0){
			mkqid(&q, Qclone, 0, QTFILE);
			devdir(c, q, "clone", 0, eve, 0666, dp);
			return 1;
		}
		lock(&mtablock);
		for(i = 0, slot = -1; i < nmtab; i++)
			if(mtab[i] != nil && mtab[i]->inuse && ++slot == s-1)
				break;
		if(i >= nmtab){
			unlock(&mtablock);
			return -1;
		}
		snprint(up->genbuf, sizeof(up->genbuf), "%d", mtab[i]->id);
		unlock(&mtablock);
		mkqid(&q, MKPATH(i, Q3rd), 0, QTDIR);
		devdir(c, q, up->genbuf, 0, eve, DMDIR|0555, dp);
		return 1;
	}

	/* third level: the instance's files */
	if(s < 0 || s >= nelem(files))
		return -1;
	mkqid(&q, MKPATH(SLOT(c->qid), ftype[s]), 0, QTFILE);
	devdir(c, q, files[s], 0, eve, ftype[s] == Qinfo ? 0444 : 0666, dp);
	return 1;
}

static Chan*
mlattach(char *spec)
{
	return devattach('N', spec);
}

static Walkqid*
mlwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, nil, 0, mlgen);
}

static int
mlstat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, nil, 0, mlgen);
}

static Chan*
mlopen(Chan *c, int omode)
{
	int s;
	Qid q;

	if(c->qid.type & QTDIR){
		if(omode != OREAD)
			error(Eisdir);
		c->mode = omode;
		c->flag |= COPEN;
		c->offset = 0;
		return c;
	}
	if(TYPE(c->qid) == Qclone){
		s = newinstance();
		if(s < 0)
			error(Enomem);
		/* the clone fd becomes this instance's ctl, as /dev/draw/new does */
		mkqid(&q, MKPATH(s, Qctl), 0, QTFILE);
		c->qid = q;
	}
	c->mode = openmode(omode);
	c->flag |= COPEN;
	c->offset = 0;
	return c;
}

static void
mlclose(Chan *c)
{
	Mstate *m;

	if(c->qid.type & QTDIR)
		return;
	/*
	 * Only the ctl fd owns the instance's lifetime. Closing "in" or
	 * "out" must not tear down a model the caller is still using - it is
	 * ordinary for a program to open, write and close "in" repeatedly.
	 */
	if(TYPE(c->qid) != Qctl)
		return;
	m = instance(c);
	if(m == nil)
		return;
	mlfree(m);
}

static long
mlread(Chan *c, void *va, long n, vlong off)
{
	Mstate *m;
	char *buf;
	long rv;

	if(c->qid.type & QTDIR)
		return devdirread(c, va, n, nil, 0, mlgen);

	m = instance(c);
	if(m == nil)
		error(Enonexist);

	switch(TYPE(c->qid)){
	case Qctl:
		snprint(up->genbuf, sizeof(up->genbuf), "%11d ", m->id);
		return readstr(off, va, n, up->genbuf);

	case Qinfo:
		if(m->m == nil)
			error(Enomodel);
		if(mlmodelinfo == nil)
			error(Enobackend);
		buf = malloc(8192);
		if(buf == nil)
			error(Enomem);
		if(waserror()){
			free(buf);
			nexterror();
		}
		if(mlmodelinfo(m->m, buf, 8192) < 0)
			error("cannot describe the model");
		rv = readstr(off, va, n, buf);
		poperror();
		free(buf);
		return rv;

	case Qout:
		/*
		 * Whatever "run" fetched, read like an ordinary file so a
		 * short read does not lose the tail.
		 */
		if(m->out == nil)
			return 0;
		if(off >= m->nout)
			return 0;
		rv = m->nout - off;
		if(rv > n)
			rv = n;
		memmove(va, m->out + off, rv);
		return rv;
	}
	error(Ebadarg);
	return 0;
}

/* Take the model's own account of what it takes and returns. */
static void
domodelload(Mstate *m)
{
	char err[ERRMAX];
	void *bm;

	if(mlopenmodel == nil)
		error(Enobackend);
	if(m->nspec == 0)
		error("no model bytes were written");
	err[0] = '\0';
	bm = mlopenmodel(m->spec, m->nspec, m->units, err, sizeof(err));
	if(bm == nil)
		error(err[0] ? err : "cannot load the model");
	if(m->m != nil && mlclosemodel != nil)
		mlclosemodel(m->m);
	m->m = bm;
}

static void
dorun(Mstate *m)
{
	char err[ERRMAX];
	int nb;
	uchar *b;

	if(m->m == nil)
		error(Enomodel);
	if(mlrunmodel == nil || mlgetoutput == nil)
		error(Enobackend);
	err[0] = '\0';
	if(mlrunmodel(m->m, err, sizeof(err)) < 0)
		error(err[0] ? err : "the model did not run");

	/* Ask how big the result is, then fetch it. */
	err[0] = '\0';
	nb = mlgetoutput(m->m, m->take, nil, 0, err, sizeof(err));
	if(nb < 0)
		error(err[0] ? err : "no output");
	b = malloc(nb == 0 ? 1 : nb);
	if(b == nil)
		error(Enomem);
	if(waserror()){
		free(b);
		nexterror();
	}
	err[0] = '\0';
	if(mlgetoutput(m->m, m->take, b, nb, err, sizeof(err)) < 0)
		error(err[0] ? err : "cannot read the output");
	poperror();
	free(m->out);
	m->out = b;
	m->nout = nb;
}

static void
mlctl(Mstate *m, char *buf)
{
	char *fields[4];
	int nf;

	nf = tokenize(buf, fields, nelem(fields));
	if(nf == 0)
		return;

	if(strcmp(fields[0], "units") == 0){
		if(nf < 2)
			error(Ebadarg);
		if(strcmp(fields[1], "cpu") != 0 && strcmp(fields[1], "gpu") != 0 &&
		   strcmp(fields[1], "ane") != 0 && strcmp(fields[1], "all") != 0)
			error("units must be cpu, gpu, ane or all");
		/* Takes effect at load: the compute units are part of the
		 * configuration a model is loaded with, not a per-run choice. */
		snprint(m->units, sizeof(m->units), "%s", fields[1]);
		return;
	}
	if(strcmp(fields[0], "load") == 0){
		domodelload(m);
		return;
	}
	if(strcmp(fields[0], "feed") == 0){
		if(nf < 2)
			error(Ebadarg);
		free(m->feed);
		m->feed = strdup(fields[1]);
		return;
	}
	if(strcmp(fields[0], "take") == 0){
		if(nf < 2)
			error(Ebadarg);
		free(m->take);
		m->take = strdup(fields[1]);
		return;
	}
	if(strcmp(fields[0], "run") == 0){
		dorun(m);
		return;
	}
	if(strcmp(fields[0], "reset") == 0){
		if(m->m != nil && mlclosemodel != nil)
			mlclosemodel(m->m);
		m->m = nil;
		free(m->spec); m->spec = nil; m->nspec = m->aspec = 0;
		free(m->out); m->out = nil; m->nout = 0;
		return;
	}
	error(Ebadarg);
}

static long
mlwrite(Chan *c, void *va, long n, vlong off)
{
	Mstate *m;
	char buf[256], err[ERRMAX];
	uchar *nb;
	int need;

	USED(off);
	if(c->qid.type & QTDIR)
		error(Eperm);
	m = instance(c);
	if(m == nil)
		error(Enonexist);

	qlock(&m->l);
	if(waserror()){
		qunlock(&m->l);
		nexterror();
	}

	switch(TYPE(c->qid)){
	case Qctl:
		if(n <= 0 || n >= sizeof(buf))
			error(Ebadarg);
		memmove(buf, va, n);
		buf[n] = '\0';
		mlctl(m, buf);
		break;

	case Qmodel:
		/*
		 * Appended, not positional: a model arrives as a stream of
		 * writes of whatever size the caller chose, and is compiled
		 * only when ctl says "load".
		 */
		if(n < 0 || m->nspec > Maxmodel - n)
			error("model too large");
		if(m->nspec + n > m->aspec){
			need = m->aspec ? m->aspec : 64*1024;
			while(need < m->nspec + n)
				need *= 2;
			nb = malloc(need);
			if(nb == nil)
				error(Enomem);
			if(m->spec != nil)
				memmove(nb, m->spec, m->nspec);
			free(m->spec);
			m->spec = nb;
			m->aspec = need;
		}
		memmove(m->spec + m->nspec, va, n);
		m->nspec += n;
		break;

	case Qin:
		if(m->m == nil)
			error(Enomodel);
		if(mlsetinput == nil)
			error(Enobackend);
		err[0] = '\0';
		if(mlsetinput(m->m, m->feed, va, n, err, sizeof(err)) < 0)
			error(err[0] ? err : "cannot set the input");
		break;

	default:
		error(Ebadarg);
	}

	poperror();
	qunlock(&m->l);
	return n;
}

Dev mldevtab = {
	'N',
	"ml",

	devinit,
	mlattach,
	mlwalk,
	mlstat,
	mlopen,
	devcreate,
	mlclose,
	mlread,
	devbread,
	mlwrite,
	devbwrite,
	devremove,
	devwstat,
};
