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
 * The wire format is binary.  Text was tried first and was not merely
 * slow: formatting a whole CSR matrix as decimal exhausted the Limbo
 * heap at a 16x16x16 mesh, long before the GPU was the limit.  Integers
 * are 32-bit and values IEEE754 single, both big-endian, matching what
 * Limbo's math->export_int/export_real32 produce so the sender needs no
 * hand-rolled marshalling.  Single precision throughout because the
 * hardware path is f32-only anyway (Metal has no double) - see the
 * 'P' request.  Write one request, then read its response, exactly
 * once per write - no pipelining.
 *
 *   write "P\n"
 *       -> read() returns "f32\n" or "f64\n": the precision this
 *          device would actually compute in.  Not cosmetic - a caller
 *          needing f64 must know before trusting a result, which is
 *          what gpu(2)'s "precision" verb uses this for.
 *   write 'U' n nnz rowptr[n+1] colidx[nnz] val[nnz]
 *       -> upload a CSR matrix, replacing any previous one on this
 *          handle.  read() returns "OK\n" or an error.
 *   write 'X' x[n]
 *       -> compute y = A*x against the uploaded matrix.  read()
 *          returns y[n] as raw single-precision values.
 *
 * The numeric kernel itself is NOT this file's job: gpuspmv() below
 * dispatches to a platform backend's real GPU compute through the
 * nullable gpuhw* hooks (win-gpu.m provides Metal ones on this
 * platform), and falls back to a portable CPU loop wherever no such
 * backend is linked - the same convention devdraw.c already uses for
 * gpudrawfillpoly3d/g. This file owns only the protocol and handle
 * lifecycle, so neither adding nor removing a hardware backend
 * changes its Styx surface at all.
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

/*
 * Nullable hardware hooks, exactly the convention devdraw.c already
 * uses for gpudrawfillpoly3d/g: a platform backend that has real GPU
 * compute (win-gpu.m, Metal) assigns these at load time; everywhere
 * else they stay nil and every matvec silently uses the portable CPU
 * path below. Plain C types only, so the backend implementing them
 * needs no Inferno headers at all.
 *
 * gpuhwupload returns an opaque per-matrix handle (device-resident
 * buffers) or nil if it can't; gpuhwspmv returns 0 if it couldn't run
 * and the caller should fall back. Metal has no f64, so a hardware
 * backend is inherently f32 - gpu(2) is what decides whether that's
 * acceptable for a given solve (see its "precision" verb), not this
 * file.
 */
void*	(*gpuhwupload)(int n, int nnz, int *rowptr, int *colidx, double *val);
int	(*gpuhwspmv)(void *h, double *x, double *y, int n);
void	(*gpuhwfree)(void *h);

typedef struct Gstate Gstate;
struct Gstate
{
	int	inuse;
	int	n;
	int	nnz;
	int	*rowptr;
	int	*colidx;
	double	*val;
	void	*hw;		/* gpuhwupload handle, or nil for the CPU path */

	char	*resp;		/* pending read() response */
	int	resplen;
	int	respoff;
};

/*
 * Handle table. This is an array of POINTERS, not of Gstate, and that is
 * load-bearing: growing it reallocates the pointer array, and a Gstate that
 * moved out from under a concurrent gpuread/gpuwrite would be a use-after-free.
 * Individually allocated Gstates never move, and gfree() only resets one for
 * reuse rather than freeing it, so a resolved Gstate* stays valid memory for
 * the life of the process.
 *
 * Everything that touches gtab or ngtab does so under gtablock - see
 * gethandle(), which is the only way to turn a Chan into a Gstate.
 */
static Gstate	**gtab;
static int	ngtab;
static Lock	gtablock;

/* y = A*x, CSR - on real GPU hardware when a backend provided one for
 * this matrix, otherwise the portable CPU path. */
static void
gpuspmv(Gstate *g, double *x, double *y)
{
	int row, jj;
	double s;

	if(g->hw != nil && gpuhwspmv != nil && gpuhwspmv(g->hw, x, y, g->n))
		return;
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
	if(g->hw != nil && gpuhwfree != nil)
		gpuhwfree(g->hw);
	g->hw = nil;
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

/*
 * Resolve a Chan to its Gstate, or nil if the handle is not live. The table
 * is read only under gtablock; the Gstate returned outlives the lock because
 * Gstates are never moved or freed (see the gtab comment above).
 *
 * Serialising two procs that share one handle is NOT this lock's job and
 * cannot be: every message here is one request followed by its response, so
 * interleaving two conversations on a single handle scrambles the protocol
 * whatever the locking. One handle per proc, which is what gpu(2) does.
 */
static Gstate*
gethandle(Chan *c)
{
	Gstate *g;
	int h;

	h = HANDLE(c->qid);
	lock(&gtablock);
	if(h < 0 || h >= ngtab || gtab[h] == nil || !gtab[h]->inuse){
		unlock(&gtablock);
		return nil;
	}
	g = gtab[h];
	unlock(&gtablock);
	return g;
}

static int
newhandle(void)
{
	int i;
	Gstate **ng, *g;

	lock(&gtablock);
	for(i = 0; i < ngtab; i++)
		if(gtab[i] == nil || !gtab[i]->inuse)
			break;
	if(i == ngtab){
		ng = malloc((ngtab+16) * sizeof(Gstate*));
		if(ng == nil){
			unlock(&gtablock);
			return -1;
		}
		if(gtab != nil)
			memmove(ng, gtab, ngtab * sizeof(Gstate*));
		memset(ng+ngtab, 0, 16 * sizeof(Gstate*));
		free(gtab);	/* only the pointer array moves, never a Gstate */
		gtab = ng;
		ngtab += 16;
	}
	if(gtab[i] == nil){
		g = malloc(sizeof(Gstate));
		if(g == nil){
			unlock(&gtablock);
			return -1;
		}
		memset(g, 0, sizeof(Gstate));
		gtab[i] = g;
	}
	gtab[i]->inuse = 1;
	unlock(&gtablock);
	return i;
}

/* Binary-safe variant of setresp: takes ownership of buf. */
static void
setrespn(Gstate *g, char *buf, int len)
{
	free(g->resp);
	g->resp = buf;
	g->resplen = len;
	g->respoff = 0;
}

static uint
be32(uchar *p)
{
	return ((uint)p[0]<<24) | ((uint)p[1]<<16) | ((uint)p[2]<<8) | (uint)p[3];
}

/* IEEE754 single, big-endian on the wire (matches Limbo's
 * math->export_real32), to double. */
static double
be32f(uchar *p)
{
	union { uint u; float f; } v;

	v.u = be32(p);
	return (double)v.f;
}

static void
put32f(uchar *p, double d)
{
	union { uint u; float f; } v;

	v.f = (float)d;
	p[0] = v.u>>24; p[1] = v.u>>16; p[2] = v.u>>8; p[3] = v.u;
}

static void
setresp(Gstate *g, char *s)
{
	free(g->resp);
	g->resp = s;
	g->resplen = strlen(s);
	g->respoff = 0;
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

	if(c->qid.type & QTDIR)
		return;
	if(TYPE(c->qid) != Qhandle)
		return;
	g = gethandle(c);
	if(g == nil)
		return;
	lock(&gtablock);
	gfree(g);
	unlock(&gtablock);
}

static long
gpuread(Chan *c, void *va, long n, vlong unused_offset)
{
	Gstate *g;
	long m;

	USED(unused_offset);
	if(c->qid.type & QTDIR)
		return devdirread(c, va, n, nil, 0, gpugen);
	g = gethandle(c);
	if(g == nil)
		error(Enonexist);
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
	char *buf;
	int nn, nnz, i;
	int *rowptr, *colidx;
	double *val, *x, *y;
	char *out;

	USED(unused_offset);
	g = gethandle(c);
	if(g == nil)
		error(Enonexist);

	buf = malloc(n+1);
	if(buf == nil)
		error(Enomem);
	memmove(buf, va, n);
	buf[n] = 0;

	if(buf[0] == 'P'){
		free(buf);
		lock(&gtablock);
		/* Report what a matvec on this handle would really deliver to
		 * the caller, not what it computes with internally.
		 *
		 * This used to answer f64 whenever no hardware hooks were
		 * linked, on the grounds that the portable gpuspmv() loop below
		 * is written in double. That was wrong, and wrong in the one
		 * direction this request exists to prevent: 'U' and 'X' carry
		 * values as be32f/put32f - IEEE754 SINGLE - on every path,
		 * hardware or not. So the vector handed back has been through
		 * f32 twice regardless, and a caller who asked for f64 and was
		 * told f64 was quietly getting f32.
		 *
		 * f32 is therefore the honest answer for this protocol as it
		 * stands, and the effect is that "precision f64" now declines
		 * this device on every path instead of only the hardware one.
		 * Carrying real f64 needs new request tags with 8-byte values;
		 * until those exist, do not soften this back. */
		setresp(g, strdup("f32\n"));
		unlock(&gtablock);
		return n;
	}
	if(buf[0] == 'U'){
		uchar *q;
		int need;

		/* 'U' n nnz rowptr[n+1] colidx[nnz] val[nnz], all big-endian,
		 * ints 32-bit and values IEEE754 single - see gpu(3).  Text
		 * was unusable here: formatting a matrix's worth of numbers
		 * exhausted the heap well before the GPU became the limit. */
		if(n < 9){
			free(buf);
			error(Ebadarg);
		}
		q = (uchar*)buf;
		nn = be32(q+1);
		nnz = be32(q+5);
		if(nn <= 0 || nnz < 0){
			free(buf);
			error(Ebadarg);
		}
		need = 9 + (nn+1)*4 + nnz*4 + nnz*4;
		if(n < need){
			free(buf);
			error(Eshortstat);
		}
		rowptr = malloc((nn+1) * sizeof(int));
		colidx = malloc((nnz > 0 ? nnz : 1) * sizeof(int));
		val = malloc((nnz > 0 ? nnz : 1) * sizeof(double));
		if(rowptr == nil || colidx == nil || val == nil){
			free(rowptr); free(colidx); free(val); free(buf);
			error(Enomem);
		}
		q += 9;
		for(i = 0; i <= nn; i++, q += 4)
			rowptr[i] = (int)be32(q);
		for(i = 0; i < nnz; i++, q += 4)
			colidx[i] = (int)be32(q);
		for(i = 0; i < nnz; i++, q += 4)
			val[i] = be32f(q);
		free(buf);
		lock(&gtablock);
		if(g->hw != nil && gpuhwfree != nil)
			gpuhwfree(g->hw);
		g->hw = nil;
		free(g->rowptr); free(g->colidx); free(g->val);
		g->rowptr = rowptr;
		g->colidx = colidx;
		g->val = val;
		g->n = nn;
		g->nnz = nnz;
		/* Resident upload: the matrix crosses once here, and only the
		 * vector crosses per matvec afterward - the whole point of
		 * gpu(2)'s "resident on". */
		if(gpuhwupload != nil)
			g->hw = gpuhwupload(nn, nnz, rowptr, colidx, val);
		setresp(g, strdup("OK\n"));
		unlock(&gtablock);
		return n;
	}
	if(buf[0] == 'X'){
		uchar *q, *out;

		if(g->rowptr == nil){
			free(buf);
			error(Ebadctl);
		}
		if(n < 1 + g->n*4){
			free(buf);
			error(Eshortstat);
		}
		x = malloc(g->n * sizeof(double));
		y = malloc(g->n * sizeof(double));
		if(x == nil || y == nil){
			free(x); free(y); free(buf);
			error(Enomem);
		}
		q = (uchar*)buf + 1;
		for(i = 0; i < g->n; i++, q += 4)
			x[i] = be32f(q);
		free(buf);
		gpuspmv(g, x, y);
		free(x);
		out = malloc(g->n * 4);
		if(out == nil){
			free(y);
			error(Enomem);
		}
		for(i = 0; i < g->n; i++)
			put32f(out + i*4, y[i]);
		free(y);
		lock(&gtablock);
		setrespn(g, (char*)out, g->n * 4);
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
