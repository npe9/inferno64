/*
 * devgpu - execution-target device for gpu(2)/appl/lib/gpu.b.
 *
 * #G binds flat into /dev (main.c, matching #A audio's own "/dev/audio,
 * /dev/audioctl - no subdirectory" convention), so its one file is
 * named /dev/gpuclone, not /dev/gpu/clone. One clone-allocated handle
 * per uploaded sparse(2) CSR matrix: open /dev/gpuclone to get a
 * fresh handle; the SAME open Chan then carries both the one-time
 * upload and every subsequent matvec exchange - no separate ctl/data
 * file split, since every message on a handle is naturally one
 * request followed by one response, matching how gpu(2)'s own
 * Backend.apply()/cmd() call this one call at a time already.
 *
 * Protocol is deliberately text, not binary, for this first pass: a
 * real high-throughput version would move to a compact binary
 * encoding once real GPU compute (see gpudrawfillpoly3d/g for the
 * existing GPU *render* hooks this mirrors one layer down) is wired
 * in on top of this device - correctness and the end-to-end plumbing
 * come first, matching how every other module built into gpu(2) this
 * session was scoped. Write one request, then read its response,
 * exactly once per write - no pipelining.
 *
 *   write "U <n> <nnz>\n<n+1 rowptr ints>\n<nnz colidx ints>\n<nnz val reals>\n"
 *       -> upload a CSR matrix, replacing any previous upload on
 *          this handle. read() afterward returns "OK\n" or an error.
 *   write "X <n reals>\n"
 *       -> compute y = A*x against the uploaded matrix (error if
 *          none uploaded, or n doesn't match). read() afterward
 *          returns "<n reals>\n", the result y.
 *
 * The matvec itself runs on the CPU in this device (software.c) -
 * this file's whole job is the protocol and handle lifecycle, not
 * the numeric kernel; a future GPU-backed replacement of gpuspmv()
 * changes only software.c, not this file's Styx surface.
 */
#include	"dat.h"
#include	"fns.h"
#include	"error.h"

enum
{
	Qdir,
	Qclone,
	Qhandle,
};

#define TYPE(q)		((int)(q).path & 0xf)
#define HANDLE(q)	((int)(q).path >> 4)
#define QID(h, t)	(((h)<<4) | (t))

typedef struct Gstate Gstate;
struct Gstate
{
	int	inuse;
	int	n;
	int	nnz;
	int	*rowptr;
	int	*colidx;
	double	*val;

	char	*resp;		/* pending read() response */
	int	resplen;
	int	respoff;
};

static Gstate	*gtab;
static int	ngtab;
static Lock	gtablock;

/* Software matvec: y = A*x, CSR. The one thing a real GPU backend
 * would replace - kept as its own function for exactly that reason. */
static void
gpuspmv(Gstate *g, double *x, double *y)
{
	int row, jj;
	double s;

	for(row = 0; row < g->n; row++){
		s = 0.0;
		for(jj = g->rowptr[row]; jj < g->rowptr[row+1]; jj++)
			s += g->val[jj] * x[g->colidx[jj]];
		y[row] = s;
	}
}

static void
gfree(Gstate *g)
{
	free(g->rowptr);
	free(g->colidx);
	free(g->val);
	free(g->resp);
	g->rowptr = nil;
	g->colidx = nil;
	g->val = nil;
	g->resp = nil;
	g->resplen = 0;
	g->respoff = 0;
	g->n = 0;
	g->nnz = 0;
	g->inuse = 0;
}

static int
newhandle(void)
{
	int i;
	Gstate *ng;

	lock(&gtablock);
	for(i = 0; i < ngtab; i++)
		if(!gtab[i].inuse)
			break;
	if(i == ngtab){
		ng = malloc((ngtab+16) * sizeof(Gstate));
		if(ng == nil){
			unlock(&gtablock);
			return -1;
		}
		if(gtab != nil)
			memmove(ng, gtab, ngtab * sizeof(Gstate));
		memset(ng+ngtab, 0, 16 * sizeof(Gstate));
		free(gtab);
		gtab = ng;
		ngtab += 16;
	}
	gtab[i].inuse = 1;
	unlock(&gtablock);
	return i;
}

static void
setresp(Gstate *g, char *s)
{
	free(g->resp);
	g->resp = s;
	g->resplen = strlen(s);
	g->respoff = 0;
}

/* Parses "<count> <ints...>" starting at *sp, filling a freshly
 * malloc'd array; advances *sp past what it consumed. Returns nil on
 * a malformed count/short list. */
static int*
parseints(char **sp, int count)
{
	int *a;
	int i;
	char *s;

	a = malloc(count * sizeof(int));
	if(a == nil)
		return nil;
	s = *sp;
	for(i = 0; i < count; i++){
		while(*s == ' ' || *s == '\t')
			s++;
		if(*s == 0){
			free(a);
			return nil;
		}
		a[i] = strtol(s, &s, 10);
	}
	*sp = s;
	return a;
}

static double*
parsereals(char **sp, int count)
{
	double *a;
	int i;
	char *s;

	a = malloc(count * sizeof(double));
	if(a == nil)
		return nil;
	s = *sp;
	for(i = 0; i < count; i++){
		while(*s == ' ' || *s == '\t')
			s++;
		if(*s == 0){
			free(a);
			return nil;
		}
		a[i] = strtod(s, &s);
	}
	*sp = s;
	return a;
}

static int
gpugen(Chan *c, char *unused_name, Dirtab *unused_tab, int unused_ntab, int s, Dir *dp)
{
	Qid q;

	USED(unused_name); USED(unused_tab); USED(unused_ntab);
	if(s == DEVDOTDOT){
		mkqid(&q, QID(0, Qdir), 0, QTDIR);
		devdir(c, q, ".", 0, eve, DMDIR|0555, dp);
		return 1;
	}
	if(s != 0)
		return -1;
	mkqid(&q, QID(0, Qclone), 0, QTFILE);
	devdir(c, q, "gpuclone", 0, eve, 0666, dp);
	return 1;
}

static Chan*
gpuattach(char *spec)
{
	return devattach('G', spec);
}

static Walkqid*
gpuwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, nil, 0, gpugen);
}

static int
gpustat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, nil, 0, gpugen);
}

static Chan*
gpuopen(Chan *c, int omode)
{
	int h;
	Qid q;

	if(c->qid.type & QTDIR){
		if(omode != 0)
			error(Eisdir);
		c->mode = 0;
		c->flag |= COPEN;
		c->offset = 0;
		return c;
	}
	if(TYPE(c->qid) != Qclone)
		error(Ebadarg);
	h = newhandle();
	if(h < 0)
		error(Enomem);
	mkqid(&q, QID(h, Qhandle), 0, QTFILE);
	c->qid = q;
	c->mode = openmode(omode);
	c->flag |= COPEN;
	c->offset = 0;
	return c;
}

static void
gpuclose(Chan *c)
{
	Gstate *g;
	int h;

	if(c->qid.type & QTDIR)
		return;
	if(TYPE(c->qid) != Qhandle)
		return;
	h = HANDLE(c->qid);
	if(h < 0 || h >= ngtab)
		return;
	g = &gtab[h];
	lock(&gtablock);
	gfree(g);
	unlock(&gtablock);
}

static long
gpuread(Chan *c, void *va, long n, vlong unused_offset)
{
	Gstate *g;
	int h;
	long m;

	USED(unused_offset);
	if(c->qid.type & QTDIR)
		return devdirread(c, va, n, nil, 0, gpugen);
	h = HANDLE(c->qid);
	if(h < 0 || h >= ngtab || !gtab[h].inuse)
		error(Enonexist);
	g = &gtab[h];
	if(g->resp == nil)
		return 0;
	m = g->resplen - g->respoff;
	if(m > n)
		m = n;
	if(m > 0){
		memmove(va, g->resp + g->respoff, m);
		g->respoff += m;
	}
	return m;
}

static long
gpuwrite(Chan *c, void *va, long n, vlong unused_offset)
{
	Gstate *g;
	int h;
	char *buf, *s;
	int nn, nnz;
	int *rowptr, *colidx;
	double *val, *x, *y;
	int i;
	char *out;

	USED(unused_offset);
	h = HANDLE(c->qid);
	if(h < 0 || h >= ngtab || !gtab[h].inuse)
		error(Enonexist);
	g = &gtab[h];

	buf = malloc(n+1);
	if(buf == nil)
		error(Enomem);
	memmove(buf, va, n);
	buf[n] = 0;

	if(buf[0] == 'U'){
		s = buf+1;
		while(*s == ' ')
			s++;
		nn = strtol(s, &s, 10);
		while(*s == ' ')
			s++;
		nnz = strtol(s, &s, 10);
		if(nn <= 0 || nnz < 0){
			free(buf);
			error(Ebadarg);
		}
		rowptr = parseints(&s, nn+1);
		colidx = parseints(&s, nnz);
		val = parsereals(&s, nnz);
		free(buf);
		if(rowptr == nil || colidx == nil || val == nil){
			free(rowptr); free(colidx); free(val);
			error(Ebadarg);
		}
		lock(&gtablock);
		free(g->rowptr); free(g->colidx); free(g->val);
		g->rowptr = rowptr;
		g->colidx = colidx;
		g->val = val;
		g->n = nn;
		g->nnz = nnz;
		setresp(g, strdup("OK\n"));
		unlock(&gtablock);
		return n;
	}
	if(buf[0] == 'X'){
		if(g->rowptr == nil){
			free(buf);
			error(Ebadctl);
		}
		s = buf+1;
		x = parsereals(&s, g->n);
		free(buf);
		if(x == nil)
			error(Ebadarg);
		y = malloc(g->n * sizeof(double));
		if(y == nil){
			free(x);
			error(Enomem);
		}
		gpuspmv(g, x, y);
		free(x);
		/* "%g\n" per value, generously bounded */
		out = malloc(g->n * 32 + 1);
		if(out == nil){
			free(y);
			error(Enomem);
		}
		out[0] = 0;
		for(i = 0; i < g->n; i++){
			char one[32];
			snprint(one, sizeof one, "%g ", y[i]);
			strcat(out, one);
		}
		strcat(out, "\n");
		free(y);
		lock(&gtablock);
		setresp(g, out);
		unlock(&gtablock);
		return n;
	}
	free(buf);
	error(Ebadctl);
	return 0;	/* not reached */
}

Dev gpudevtab = {
	'G',
	"gpu",

	devinit,
	gpuattach,
	gpuwalk,
	gpustat,
	gpuopen,
	devcreate,
	gpuclose,
	gpuread,
	devbread,
	gpuwrite,
	devbwrite,
	devremove,
	devwstat,
};
