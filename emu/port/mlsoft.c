/*
 * ml(3)'s software backend: run the model here, with this system's own
 * arithmetic and nothing else.
 *
 * mlonnx.c needs a host framework and a host process to put it in. Native
 * Inferno has neither, and a machine with no neural engine has nothing for it
 * to talk to either, so on both of those ml(3) had no backend at all and said
 * so. This is the path that does not ask the host for anything: it reads the
 * ONNX file itself and evaluates the graph with libmath, which every
 * configuration already links - emu's link line has it, and so does the "math"
 * line in os/pc/pc.
 *
 * ONNX is protocol buffers, and the wire format is the whole of what has to be
 * understood to read one: a varint tag holding a field number and a wire type,
 * then either a varint, a fixed 32 or 64 bit quantity, or a length and that
 * many bytes. Nothing here needs a schema compiler; the field numbers are in
 * onnx.proto and they are written down in the enums below. mkonnxmodel.py in
 * this directory writes the same format by hand from the other side, and the
 * two were built against each other.
 *
 * WHAT IT DOES NOT DO. This is not an ONNX runtime. It implements the
 * operators listed in Opset below - the ones a feed-forward numeric model is
 * made of - and an operator outside that set is an error naming the operator,
 * never a wrong answer. In particular it has no Conv, so the VITS voice
 * say(1) uses will not load here; that model wants about forty distinct
 * operators including convolution, sequence slicing and a random normal
 * generator, and wanting them is a different project from wanting a fallback.
 * What is here runs the fixture in lib/ml, and multi-layer perceptrons and
 * regressors of the shape that fixture is a small example of.
 *
 * Everything is computed in double. ONNX models are usually float32 and are
 * converted on the way in and back on the way out, so results will differ from
 * a float32 runtime in the last bits - mltest(1) compares the two backends and
 * allows for exactly that.
 */

#include	"dat.h"
#include	"fns.h"
#include	"error.h"
#include	"ml.h"

/*
 * From libmath, which emu and every native configuration already link.
 * mathi.h itself cannot be included here: it declares the floating point
 * control enums that the kernel headers above have already declared.
 */
extern void	gemm(int, int, int, int, int, double, double*, int,
			double*, int, double, double*, int);
extern double	__ieee754_exp(double);
extern double	__ieee754_log(double);
extern double	__ieee754_sqrt(double);
extern double	__ieee754_pow(double, double);
extern double	tanh(double);
extern double	fabs(double);

enum {
	Maxdim	= 8,

	/* protobuf wire types */
	Wvarint	= 0,
	W64	= 1,
	Wbytes	= 2,
	W32	= 5,

	/* ONNX TensorProto.DataType, the ones that appear in real models */
	Tfloat	= 1,
	Tuint8	= 2,
	Tint8	= 3,
	Tint32	= 6,
	Tint64	= 7,
	Tdouble	= 11,
};

typedef struct Buf Buf;
typedef struct Ten Ten;
typedef struct Node Node;
typedef struct Vin Vin;
typedef struct Soft Soft;

struct Buf
{
	uchar	*p;
	uchar	*e;
};

/*
 * A value. The declared element type is carried alongside the doubles because
 * it is what the outside world sees: ml(3) hands over bytes, and the bytes
 * have to be in the type the model says it wants.
 */
struct Ten
{
	char	*name;
	int	etype;
	int	nd;
	vlong	d[Maxdim];
	int	nel;
	double	*v;
};

struct Node
{
	char	*op;
	char	**in;
	int	nin;
	char	**out;
	int	nout;

	double	alpha;
	double	beta;
	int	transa;
	int	transb;
	int	axis;
	int	hasaxis;
	vlong	*ints;		/* "perm", and any other int list */
	int	nints;
	Ten	*t;		/* Constant's value */
};

/* a declared graph input or output */
struct Vin
{
	char	*name;
	int	etype;
	int	nd;
	vlong	d[Maxdim];	/* < 0 where the model left it open */
};

struct Soft
{
	Node	*node;
	int	nnode;
	Ten	*init;		/* the weights, by name */
	int	ninit;
	Vin	*gin;
	int	ngin;
	Vin	*gout;
	int	ngout;

	Ten	*feed;		/* what was written to "in" */
	int	nfeed;
	Ten	*res;		/* what the last run produced */
	int	nres;

	/* shapes named by ctl "shape", for dimensions the model left open */
	char	*shname[8];
	vlong	shdim[8][Maxdim];
	int	shnd[8];
	int	nsh;
};

static char	Ebadmodel[] = "that is not an ONNX model this can read";

/*
 * Protobuf.
 *
 * Every one of these returns 0 on success and -1 when the buffer runs out or
 * says something impossible, and every caller checks. A truncated model is a
 * thing that happens - the device appends the bytes as they are written, and a
 * short write leaves one - so running off the end has to be an error and not a
 * fault.
 */
static int
varint(Buf *b, uvlong *v)
{
	int s;
	uvlong x;

	x = 0;
	for(s = 0; s < 64; s += 7){
		if(b->p >= b->e)
			return -1;
		x |= (uvlong)(*b->p & 0x7f) << s;
		if((*b->p++ & 0x80) == 0){
			*v = x;
			return 0;
		}
	}
	return -1;
}

static int
tag(Buf *b, int *fnum, int *wt)
{
	uvlong v;

	if(varint(b, &v) < 0)
		return -1;
	*fnum = v >> 3;
	*wt = v & 7;
	return 0;
}

/* the bytes of a length-delimited field, as a buffer of their own */
static int
delim(Buf *b, Buf *o)
{
	uvlong n;

	if(varint(b, &n) < 0)
		return -1;
	if(n > (uvlong)(b->e - b->p))
		return -1;
	o->p = b->p;
	o->e = b->p + n;
	b->p += n;
	return 0;
}

/* step over a field whose contents are of no interest */
static int
skip(Buf *b, int wt)
{
	uvlong v;
	Buf t;

	switch(wt){
	case Wvarint:
		return varint(b, &v);
	case W64:
		if(b->e - b->p < 8)
			return -1;
		b->p += 8;
		return 0;
	case W32:
		if(b->e - b->p < 4)
			return -1;
		b->p += 4;
		return 0;
	case Wbytes:
		return delim(b, &t);
	}
	return -1;
}

static char*
str(Buf *f)
{
	char *s;
	int n;

	n = f->e - f->p;
	s = malloc(n + 1);
	if(s == nil)
		return nil;
	memmove(s, f->p, n);
	s[n] = '\0';
	return s;
}

static u32int
get32le(uchar *p)
{
	return (u32int)p[0] | ((u32int)p[1]<<8) | ((u32int)p[2]<<16) | ((u32int)p[3]<<24);
}

static uvlong
get64le(uchar *p)
{
	return (uvlong)get32le(p) | ((uvlong)get32le(p+4) << 32);
}

static float
tofloat(u32int u)
{
	union { u32int u; float f; } x;

	x.u = u;
	return x.f;
}

static double
todouble(uvlong u)
{
	union { uvlong u; double d; } x;

	x.u = u;
	return x.d;
}

static int
esize(int etype)
{
	switch(etype){
	case Tdouble:
	case Tint64:	return 8;
	case Tfloat:
	case Tint32:	return 4;
	case Tint8:
	case Tuint8:	return 1;
	}
	return 0;
}

static char*
etypename(int etype)
{
	switch(etype){
	case Tdouble:	return "f64";
	case Tfloat:	return "f32";
	case Tint64:	return "i64";
	case Tint32:	return "i32";
	case Tint8:	return "i8";
	case Tuint8:	return "u8";
	}
	return "opaque";
}

static void
tenfree(Ten *t)
{
	if(t == nil)
		return;
	free(t->name);
	free(t->v);
	t->name = nil;
	t->v = nil;
}

static int
tenalloc(Ten *t)
{
	int i;

	t->nel = 1;
	for(i = 0; i < t->nd; i++)
		t->nel *= t->d[i];
	t->v = malloc((t->nel? t->nel: 1) * sizeof(double));
	return t->v == nil? -1: 0;
}

/*
 * TensorProto. The values arrive either packed in raw_data, in the host's byte
 * order and the declared type, or in one of the typed repeated fields; real
 * exporters use raw_data and the typed fields are here because small constants
 * come that way.
 */
static int
tensorproto(Buf *b, Ten *t)
{
	int fn, wt, i, es;
	uvlong v;
	Buf f;
	uchar *p;

	memset(t, 0, sizeof(*t));
	t->etype = Tfloat;
	while(b->p < b->e){
		if(tag(b, &fn, &wt) < 0)
			return -1;
		switch(fn){
		case 1:			/* dims */
			if(wt == Wbytes){	/* packed */
				if(delim(b, &f) < 0)
					return -1;
				while(f.p < f.e){
					if(varint(&f, &v) < 0 || t->nd >= Maxdim)
						return -1;
					t->d[t->nd++] = v;
				}
			}else{
				if(varint(b, &v) < 0 || t->nd >= Maxdim)
					return -1;
				t->d[t->nd++] = v;
			}
			break;
		case 2:			/* data_type */
			if(varint(b, &v) < 0)
				return -1;
			t->etype = v;
			break;
		case 8:			/* name */
			if(delim(b, &f) < 0)
				return -1;
			free(t->name);
			t->name = str(&f);
			if(t->name == nil)
				return -1;
			break;
		case 9:			/* raw_data */
			if(delim(b, &f) < 0)
				return -1;
			if(t->v != nil)
				break;
			es = esize(t->etype);
			if(es == 0)
				return -1;
			if(tenalloc(t) < 0)
				return -1;
			if((f.e - f.p) < t->nel * es)
				return -1;
			p = f.p;
			for(i = 0; i < t->nel; i++, p += es)
				switch(t->etype){
				case Tfloat:	t->v[i] = tofloat(get32le(p)); break;
				case Tdouble:	t->v[i] = todouble(get64le(p)); break;
				case Tint64:	t->v[i] = (double)(vlong)get64le(p); break;
				case Tint32:	t->v[i] = (double)(int)get32le(p); break;
				case Tint8:	t->v[i] = (double)(schar)*p; break;
				case Tuint8:	t->v[i] = (double)*p; break;
				}
			break;
		case 4:			/* float_data */
		case 7:			/* int64_data */
		case 5:			/* int32_data */
			if(wt != Wbytes){
				if(skip(b, wt) < 0)
					return -1;
				break;
			}
			if(delim(b, &f) < 0)
				return -1;
			if(t->v != nil)
				break;
			if(tenalloc(t) < 0)
				return -1;
			i = 0;
			while(f.p < f.e && i < t->nel){
				if(fn == 4){
					if(f.e - f.p < 4)
						return -1;
					t->v[i++] = tofloat(get32le(f.p));
					f.p += 4;
				}else{
					if(varint(&f, &v) < 0)
						return -1;
					t->v[i++] = (double)(vlong)v;
				}
			}
			break;
		default:
			if(skip(b, wt) < 0)
				return -1;
		}
	}
	if(t->v == nil && tenalloc(t) < 0)
		return -1;
	return 0;
}

/* AttributeProto: only the attributes the operator set below can use */
static int
attribute(Buf *b, Node *n)
{
	char *name;
	int fn, wt, r;
	uvlong v;
	vlong iv;
	double fv;
	Buf f;

	name = nil;
	iv = 0;
	fv = 0.0;
	r = -1;
	while(b->p < b->e){
		if(tag(b, &fn, &wt) < 0)
			goto out;
		switch(fn){
		case 1:			/* name */
			if(delim(b, &f) < 0)
				goto out;
			free(name);
			name = str(&f);
			if(name == nil)
				goto out;
			break;
		case 2:			/* f */
			if(b->e - b->p < 4)
				goto out;
			fv = tofloat(get32le(b->p));
			b->p += 4;
			break;
		case 3:			/* i */
			if(varint(b, &v) < 0)
				goto out;
			iv = v;
			break;
		case 5:			/* t */
			if(delim(b, &f) < 0)
				goto out;
			if(n->t == nil){
				n->t = malloc(sizeof(Ten));
				if(n->t == nil)
					goto out;
				if(tensorproto(&f, n->t) < 0)
					goto out;
			}
			break;
		case 8:			/* ints */
			if(wt == Wbytes){
				if(delim(b, &f) < 0)
					goto out;
				while(f.p < f.e){
					if(varint(&f, &v) < 0)
						goto out;
					n->ints = realloc(n->ints, (n->nints+1)*sizeof(vlong));
					if(n->ints == nil)
						goto out;
					n->ints[n->nints++] = v;
				}
			}else{
				if(varint(b, &v) < 0)
					goto out;
				n->ints = realloc(n->ints, (n->nints+1)*sizeof(vlong));
				if(n->ints == nil)
					goto out;
				n->ints[n->nints++] = v;
			}
			break;
		default:
			if(skip(b, wt) < 0)
				goto out;
		}
	}
	if(name != nil){
		if(strcmp(name, "alpha") == 0)
			n->alpha = fv;
		else if(strcmp(name, "beta") == 0)
			n->beta = fv;
		else if(strcmp(name, "transA") == 0)
			n->transa = iv != 0;
		else if(strcmp(name, "transB") == 0)
			n->transb = iv != 0;
		else if(strcmp(name, "axis") == 0){
			n->axis = iv;
			n->hasaxis = 1;
		}
	}
	r = 0;
out:
	free(name);
	return r;
}

static int
addstr(char ***v, int *n, Buf *f)
{
	char **nv, *s;

	s = str(f);
	if(s == nil)
		return -1;
	nv = realloc(*v, (*n+1)*sizeof(char*));
	if(nv == nil){
		free(s);
		return -1;
	}
	*v = nv;
	nv[(*n)++] = s;
	return 0;
}

static int
nodeproto(Buf *b, Node *n)
{
	int fn, wt;
	Buf f;

	memset(n, 0, sizeof(*n));
	n->alpha = 1.0;
	n->beta = 1.0;
	n->axis = -1;
	while(b->p < b->e){
		if(tag(b, &fn, &wt) < 0)
			return -1;
		switch(fn){
		case 1:			/* input */
			if(delim(b, &f) < 0 || addstr(&n->in, &n->nin, &f) < 0)
				return -1;
			break;
		case 2:			/* output */
			if(delim(b, &f) < 0 || addstr(&n->out, &n->nout, &f) < 0)
				return -1;
			break;
		case 4:			/* op_type */
			if(delim(b, &f) < 0)
				return -1;
			free(n->op);
			n->op = str(&f);
			if(n->op == nil)
				return -1;
			break;
		case 5:			/* attribute */
			if(delim(b, &f) < 0)
				return -1;
			if(attribute(&f, n) < 0)
				return -1;
			break;
		default:
			if(skip(b, wt) < 0)
				return -1;
		}
	}
	return n->op == nil? -1: 0;
}

/*
 * ValueInfoProto, and the TypeProto chain under it. A dimension the model left
 * as a name rather than a number - "batch_size", and every real exporter emits
 * one - is recorded as -1 and has to be settled before the input can be given
 * any bytes.
 */
static int
valueinfo(Buf *b, Vin *w)
{
	int fn, wt, dfn, dwt;
	uvlong v;
	Buf f, ty, te, sh, dm;

	memset(w, 0, sizeof(*w));
	w->etype = 0;
	while(b->p < b->e){
		if(tag(b, &fn, &wt) < 0)
			return -1;
		switch(fn){
		case 1:			/* name */
			if(delim(b, &f) < 0)
				return -1;
			free(w->name);
			w->name = str(&f);
			if(w->name == nil)
				return -1;
			break;
		case 2:			/* type */
			if(delim(b, &ty) < 0)
				return -1;
			while(ty.p < ty.e){
				if(tag(&ty, &fn, &wt) < 0)
					return -1;
				if(fn != 1){		/* tensor_type */
					if(skip(&ty, wt) < 0)
						return -1;
					continue;
				}
				if(delim(&ty, &te) < 0)
					return -1;
				while(te.p < te.e){
					if(tag(&te, &fn, &wt) < 0)
						return -1;
					if(fn == 1){	/* elem_type */
						if(varint(&te, &v) < 0)
							return -1;
						w->etype = v;
					}else if(fn == 2){	/* shape */
						if(delim(&te, &sh) < 0)
							return -1;
						while(sh.p < sh.e){
							if(tag(&sh, &fn, &wt) < 0)
								return -1;
							if(fn != 1){
								if(skip(&sh, wt) < 0)
									return -1;
								continue;
							}
							if(delim(&sh, &dm) < 0)
								return -1;
							if(w->nd >= Maxdim)
								return -1;
							w->d[w->nd] = -1;
							while(dm.p < dm.e){
								if(tag(&dm, &dfn, &dwt) < 0)
									return -1;
								if(dfn == 1){	/* dim_value */
									if(varint(&dm, &v) < 0)
										return -1;
									w->d[w->nd] = v;
								}else if(skip(&dm, dwt) < 0)
									return -1;
							}
							w->nd++;
						}
					}else if(skip(&te, wt) < 0)
						return -1;
				}
			}
			break;
		default:
			if(skip(b, wt) < 0)
				return -1;
		}
	}
	return w->name == nil? -1: 0;
}

static int
graphproto(Buf *b, Soft *s)
{
	int fn, wt;
	Buf f;
	void *p;

	while(b->p < b->e){
		if(tag(b, &fn, &wt) < 0)
			return -1;
		switch(fn){
		case 1:			/* node */
			if(delim(b, &f) < 0)
				return -1;
			p = realloc(s->node, (s->nnode+1)*sizeof(Node));
			if(p == nil)
				return -1;
			s->node = p;
			if(nodeproto(&f, &s->node[s->nnode]) < 0)
				return -1;
			s->nnode++;
			break;
		case 5:			/* initializer */
			if(delim(b, &f) < 0)
				return -1;
			p = realloc(s->init, (s->ninit+1)*sizeof(Ten));
			if(p == nil)
				return -1;
			s->init = p;
			if(tensorproto(&f, &s->init[s->ninit]) < 0)
				return -1;
			s->ninit++;
			break;
		case 11:		/* input */
		case 12:		/* output */
			if(delim(b, &f) < 0)
				return -1;
			if(fn == 11){
				p = realloc(s->gin, (s->ngin+1)*sizeof(Vin));
				if(p == nil)
					return -1;
				s->gin = p;
				if(valueinfo(&f, &s->gin[s->ngin]) < 0)
					return -1;
				s->ngin++;
			}else{
				p = realloc(s->gout, (s->ngout+1)*sizeof(Vin));
				if(p == nil)
					return -1;
				s->gout = p;
				if(valueinfo(&f, &s->gout[s->ngout]) < 0)
					return -1;
				s->ngout++;
			}
			break;
		default:
			if(skip(b, wt) < 0)
				return -1;
		}
	}
	return 0;
}

/*
 * A graph input that also appears as an initializer is a weight with a default,
 * not something the caller is expected to provide. Real exporters emit these
 * and reporting them as inputs would ask the caller for the weights.
 */
static int
isinit(Soft *s, char *name)
{
	int i;

	for(i = 0; i < s->ninit; i++)
		if(s->init[i].name != nil && strcmp(s->init[i].name, name) == 0)
			return 1;
	return 0;
}

/* Arithmetic. */

/*
 * libmath's gemm is the Fortran one: column major, and a row-major array read
 * as column major is its own transpose. So computing the transpose of what is
 * wanted, with the operands the other way round, lands the result in row-major
 * order: C = op(A)op(B) row-major is C' = op(B)'op(A)' column-major.
 */
static void
rgemm(int ta, int tb, int m, int n, int k, double alpha,
	double *a, double *b, double beta, double *c)
{
	gemm(tb? 'T': 'N', ta? 'T': 'N', n, m, k, alpha,
		b, tb? k: n,
		a, ta? m: k, beta,
		c, n);
}

/* numpy broadcasting: dimensions line up from the right, and 1 stretches */
static int
bshape(Ten *x, Ten *y, Ten *r)
{
	int i, nd;
	vlong dx, dy;

	nd = x->nd > y->nd? x->nd: y->nd;
	if(nd > Maxdim)
		return -1;
	r->nd = nd;
	for(i = 0; i < nd; i++){
		dx = i < nd - x->nd? 1: x->d[i - (nd - x->nd)];
		dy = i < nd - y->nd? 1: y->d[i - (nd - y->nd)];
		if(dx != dy && dx != 1 && dy != 1)
			return -1;
		r->d[i] = dx > dy? dx: dy;
	}
	return 0;
}

/* where element idx of the broadcast result comes from in x */
static int
bindex(Ten *r, Ten *x, int idx)
{
	int i, off, o, coord;
	vlong st;

	off = 0;
	st = 1;
	for(i = r->nd - 1; i >= 0; i--){
		coord = idx % r->d[i];
		idx /= r->d[i];
		o = i - (r->nd - x->nd);
		if(o >= 0){
			if(x->d[o] != 1)
				off += coord * st;
			st *= x->d[o];
		}
	}
	return off;
}

static int
binop(char *op, Ten *x, Ten *y, Ten *r)
{
	int i, a, b;

	if(bshape(x, y, r) < 0 || tenalloc(r) < 0)
		return -1;
	for(i = 0; i < r->nel; i++){
		a = bindex(r, x, i);
		b = bindex(r, y, i);
		switch(op[0]){
		case 'A':	r->v[i] = x->v[a] + y->v[b]; break;	/* Add */
		case 'S':	r->v[i] = x->v[a] - y->v[b]; break;	/* Sub */
		case 'M':	r->v[i] = x->v[a] * y->v[b]; break;	/* Mul */
		case 'D':	r->v[i] = y->v[b] == 0.0? 0.0: x->v[a] / y->v[b]; break;
		case 'P':	r->v[i] = __ieee754_pow(x->v[a], y->v[b]); break;
		}
	}
	return 0;
}

/* Evaluation. */

typedef struct Env Env;
struct Env
{
	Ten	*t;
	int	n;
	int	a;
};

static Ten*
lookup(Env *e, char *name)
{
	int i;

	if(name == nil || *name == '\0')
		return nil;
	for(i = 0; i < e->n; i++)
		if(e->t[i].name != nil && strcmp(e->t[i].name, name) == 0)
			return &e->t[i];
	return nil;
}

/* takes ownership of t's storage; name is copied */
static int
bind(Env *e, char *name, Ten *t)
{
	Ten *o;
	void *p;

	o = lookup(e, name);
	if(o != nil){
		free(o->v);
		t->name = o->name;
		*o = *t;
		return 0;
	}
	if(e->n >= e->a){
		e->a = e->a? e->a*2: 32;
		p = realloc(e->t, e->a*sizeof(Ten));
		if(p == nil)
			return -1;
		e->t = p;
	}
	t->name = strdup(name);
	if(t->name == nil)
		return -1;
	e->t[e->n++] = *t;
	return 0;
}

static void
envfree(Env *e)
{
	int i;

	for(i = 0; i < e->n; i++)
		tenfree(&e->t[i]);
	free(e->t);
	e->t = nil;
	e->n = e->a = 0;
}

static int
evalnode(Node *n, Env *e, char *err, int nerr)
{
	Ten *x, *y, *z, r;
	int i, j, k, m, nn, ax, off, nel, rem;
	vlong perm[Maxdim], st[Maxdim], co[Maxdim], v;
	double s, mx;

	memset(&r, 0, sizeof(r));
	x = n->nin > 0? lookup(e, n->in[0]): nil;
	y = n->nin > 1? lookup(e, n->in[1]): nil;
	z = n->nin > 2? lookup(e, n->in[2]): nil;

	if(strcmp(n->op, "Constant") == 0){
		if(n->t == nil){
			snprint(err, nerr, "Constant with no value");
			return -1;
		}
		r = *n->t;
		r.name = nil;
		r.v = malloc((r.nel? r.nel: 1)*sizeof(double));
		if(r.v == nil)
			return -1;
		memmove(r.v, n->t->v, r.nel*sizeof(double));
		goto done;
	}

	if(x == nil){
		snprint(err, nerr, "%s wants %s, which nothing produced",
			n->op, n->nin > 0? n->in[0]: "an input");
		return -1;
	}

	if(strcmp(n->op, "Gemm") == 0 || strcmp(n->op, "MatMul") == 0){
		int ta, tb, mm, kk, nnc;

		if(y == nil){
			snprint(err, nerr, "%s wants two inputs", n->op);
			return -1;
		}
		ta = n->transa;
		tb = n->transb;
		if(strcmp(n->op, "MatMul") == 0)
			ta = tb = 0;
		if(x->nd != 2 || y->nd != 2){
			snprint(err, nerr, "%s here is two-dimensional only", n->op);
			return -1;
		}
		mm = ta? x->d[1]: x->d[0];
		kk = ta? x->d[0]: x->d[1];
		nnc = tb? y->d[0]: y->d[1];
		if((tb? y->d[1]: y->d[0]) != kk){
			snprint(err, nerr, "%s: inner dimensions do not agree", n->op);
			return -1;
		}
		r.etype = x->etype;
		r.nd = 2;
		r.d[0] = mm;
		r.d[1] = nnc;
		if(tenalloc(&r) < 0)
			return -1;
		/*
		 * C starts as the bias, broadcast, so gemm's beta adds it in
		 * place rather than needing a pass of its own.
		 */
		if(z != nil && strcmp(n->op, "Gemm") == 0){
			for(i = 0; i < mm; i++)
				for(j = 0; j < nnc; j++){
					if(z->nd == 1)
						r.v[i*nnc + j] = z->v[z->d[0] == 1? 0: j];
					else if(z->nd == 2)
						r.v[i*nnc + j] = z->v[(z->d[0]==1? 0: i)*z->d[1] +
							(z->d[1]==1? 0: j)];
					else
						r.v[i*nnc + j] = z->v[0];
				}
			rgemm(ta, tb, mm, nnc, kk, n->alpha, x->v, y->v, n->beta, r.v);
		}else{
			for(i = 0; i < r.nel; i++)
				r.v[i] = 0.0;
			rgemm(ta, tb, mm, nnc, kk,
				strcmp(n->op, "Gemm") == 0? n->alpha: 1.0,
				x->v, y->v, 0.0, r.v);
		}
		goto done;
	}

	if(strcmp(n->op, "Add") == 0 || strcmp(n->op, "Sub") == 0 ||
	   strcmp(n->op, "Mul") == 0 || strcmp(n->op, "Div") == 0 ||
	   strcmp(n->op, "Pow") == 0){
		if(y == nil){
			snprint(err, nerr, "%s wants two inputs", n->op);
			return -1;
		}
		r.etype = x->etype;
		if(binop(n->op, x, y, &r) < 0){
			snprint(err, nerr, "%s: shapes do not broadcast", n->op);
			return -1;
		}
		goto done;
	}

	if(strcmp(n->op, "Relu") == 0 || strcmp(n->op, "Sigmoid") == 0 ||
	   strcmp(n->op, "Tanh") == 0 || strcmp(n->op, "Exp") == 0 ||
	   strcmp(n->op, "Log") == 0 || strcmp(n->op, "Sqrt") == 0 ||
	   strcmp(n->op, "Neg") == 0 || strcmp(n->op, "Abs") == 0 ||
	   strcmp(n->op, "Identity") == 0){
		r = *x;
		r.name = nil;
		if(tenalloc(&r) < 0)
			return -1;
		for(i = 0; i < r.nel; i++){
			s = x->v[i];
			switch(n->op[0]){
			case 'R':	r.v[i] = s > 0.0? s: 0.0; break;
			case 'S':
				if(n->op[1] == 'i')
					r.v[i] = 1.0/(1.0 + __ieee754_exp(-s));
				else
					r.v[i] = s <= 0.0? 0.0: __ieee754_sqrt(s);
				break;
			case 'T':	r.v[i] = tanh(s); break;
			case 'E':	r.v[i] = __ieee754_exp(s); break;
			case 'L':	r.v[i] = s <= 0.0? -1e308: __ieee754_log(s); break;
			case 'N':	r.v[i] = -s; break;
			case 'A':	r.v[i] = fabs(s); break;
			case 'I':	r.v[i] = s; break;
			}
		}
		goto done;
	}

	if(strcmp(n->op, "Softmax") == 0){
		r = *x;
		r.name = nil;
		if(tenalloc(&r) < 0)
			return -1;
		ax = n->hasaxis? n->axis: -1;
		if(ax < 0)
			ax += x->nd;
		if(ax < 0 || ax >= x->nd){
			snprint(err, nerr, "Softmax: axis outside the tensor");
			return -1;
		}
		/* stride of the axis, and how many rows there are along it */
		k = 1;
		for(i = ax+1; i < x->nd; i++)
			k *= x->d[i];
		nn = x->d[ax];
		nel = r.nel / (nn? nn: 1);
		for(m = 0; m < nel; m++){
			off = (m / k) * (nn * k) + m % k;
			mx = x->v[off];
			for(i = 1; i < nn; i++)
				if(x->v[off + i*k] > mx)
					mx = x->v[off + i*k];
			s = 0.0;
			for(i = 0; i < nn; i++){
				r.v[off + i*k] = __ieee754_exp(x->v[off + i*k] - mx);
				s += r.v[off + i*k];
			}
			for(i = 0; i < nn; i++)
				r.v[off + i*k] /= s;
		}
		goto done;
	}

	if(strcmp(n->op, "Reshape") == 0 || strcmp(n->op, "Flatten") == 0 ||
	   strcmp(n->op, "Squeeze") == 0 || strcmp(n->op, "Unsqueeze") == 0){
		r = *x;
		r.name = nil;
		if(tenalloc(&r) < 0)
			return -1;
		memmove(r.v, x->v, r.nel*sizeof(double));
		if(strcmp(n->op, "Reshape") == 0){
			if(y == nil){
				snprint(err, nerr, "Reshape wants a shape");
				return -1;
			}
			if(y->nel > Maxdim){
				snprint(err, nerr, "Reshape: too many dimensions");
				return -1;
			}
			rem = x->nel;
			k = -1;
			r.nd = y->nel;
			for(i = 0; i < y->nel; i++){
				v = (vlong)y->v[i];
				if(v == 0)
					v = i < x->nd? x->d[i]: 1;
				r.d[i] = v;
				if(v < 0)
					k = i;
				else if(v != 0)
					rem /= v;
			}
			if(k >= 0)
				r.d[k] = rem;
			r.nel = x->nel;
		}else if(strcmp(n->op, "Flatten") == 0){
			ax = n->hasaxis? n->axis: 1;
			if(ax < 0)
				ax += x->nd;
			k = 1;
			for(i = 0; i < ax && i < x->nd; i++)
				k *= x->d[i];
			r.nd = 2;
			r.d[0] = k;
			r.d[1] = k? x->nel / k: 0;
		}else{
			/* Squeeze and Unsqueeze take their axes as a list */
			snprint(err, nerr,
				"%s is not implemented; this backend does the operators in ml(3)",
				n->op);
			free(r.v);
			return -1;
		}
		goto done;
	}

	if(strcmp(n->op, "Transpose") == 0){
		if(x->nd > Maxdim)
			return -1;
		for(i = 0; i < x->nd; i++)
			perm[i] = n->nints == x->nd? n->ints[i]: x->nd-1-i;
		r = *x;
		r.name = nil;
		for(i = 0; i < x->nd; i++){
			if(perm[i] < 0 || perm[i] >= x->nd){
				snprint(err, nerr, "Transpose: perm outside the tensor");
				return -1;
			}
			r.d[i] = x->d[perm[i]];
		}
		if(tenalloc(&r) < 0)
			return -1;
		/* strides of the source, in source dimension order */
		st[x->nd-1] = 1;
		for(i = x->nd-2; i >= 0; i--)
			st[i] = st[i+1] * x->d[i+1];
		for(m = 0; m < r.nel; m++){
			k = m;
			for(i = r.nd-1; i >= 0; i--){
				co[i] = k % r.d[i];
				k /= r.d[i];
			}
			off = 0;
			for(i = 0; i < r.nd; i++)
				off += co[i] * st[perm[i]];
			r.v[m] = x->v[off];
		}
		goto done;
	}

	if(strcmp(n->op, "Concat") == 0){
		Ten *v;
		int outer, inner, at;

		ax = n->hasaxis? n->axis: 0;
		if(ax < 0)
			ax += x->nd;
		r = *x;
		r.name = nil;
		r.d[ax] = 0;
		for(i = 0; i < n->nin; i++){
			v = lookup(e, n->in[i]);
			if(v == nil || v->nd != x->nd){
				snprint(err, nerr, "Concat: inputs do not agree");
				return -1;
			}
			r.d[ax] += v->d[ax];
		}
		if(tenalloc(&r) < 0)
			return -1;
		outer = 1;
		for(i = 0; i < ax; i++)
			outer *= r.d[i];
		inner = 1;
		for(i = ax+1; i < r.nd; i++)
			inner *= r.d[i];
		at = 0;
		for(i = 0; i < n->nin; i++){
			v = lookup(e, n->in[i]);
			for(j = 0; j < outer; j++)
				for(k = 0; k < v->d[ax]*inner; k++)
					r.v[j*r.d[ax]*inner + at*inner + k] =
						v->v[j*v->d[ax]*inner + k];
			at += v->d[ax];
		}
		goto done;
	}

	snprint(err, nerr,
		"%s is not implemented; this backend does the operators listed in ml(3)",
		n->op);
	return -1;

done:
	if(n->nout < 1 || bind(e, n->out[0], &r) < 0){
		free(r.v);
		return -1;
	}
	return 0;
}

/* The backend proper. */

void*	mlsoft_open(uchar*, int, char*, char*, int);
void	mlsoft_close(void*);
int	mlsoft_info(void*, char*, int);
int	mlsoft_setinput(void*, char*, uchar*, int, char*, int);
int	mlsoft_run(void*, char*, int);
int	mlsoft_getoutput(void*, char*, uchar*, int, char*, int);
int	mlsoft_setshape(void*, char*, char**, int, char*, int);

static void
seterr(char *err, int nerr, char *s)
{
	if(err != nil && nerr > 0)
		snprint(err, nerr, "%s", s);
}

void*
mlsoft_open(uchar *spec, int nspec, char *units, char *err, int nerr)
{
	Soft *s;
	Buf b, f;
	int fn, wt, got;

	USED(units);
	if(spec == nil || nspec <= 0){
		seterr(err, nerr, "empty model");
		return nil;
	}
	s = malloc(sizeof(Soft));
	if(s == nil){
		seterr(err, nerr, "out of memory");
		return nil;
	}
	memset(s, 0, sizeof(Soft));

	/* ModelProto: the graph is field 7 and the rest is provenance */
	b.p = spec;
	b.e = spec + nspec;
	got = 0;
	while(b.p < b.e){
		if(tag(&b, &fn, &wt) < 0)
			goto bad;
		if(fn == 7 && wt == Wbytes){
			if(delim(&b, &f) < 0 || graphproto(&f, s) < 0)
				goto bad;
			got = 1;
		}else if(skip(&b, wt) < 0)
			goto bad;
	}
	if(!got)
		goto bad;
	return s;
bad:
	mlsoft_close(s);
	seterr(err, nerr, Ebadmodel);
	return nil;
}

void
mlsoft_close(void *h)
{
	Soft *s = h;
	int i, j;

	if(s == nil)
		return;
	for(i = 0; i < s->nnode; i++){
		for(j = 0; j < s->node[i].nin; j++)
			free(s->node[i].in[j]);
		for(j = 0; j < s->node[i].nout; j++)
			free(s->node[i].out[j]);
		free(s->node[i].in);
		free(s->node[i].out);
		free(s->node[i].op);
		free(s->node[i].ints);
		if(s->node[i].t != nil){
			tenfree(s->node[i].t);
			free(s->node[i].t);
		}
	}
	free(s->node);
	for(i = 0; i < s->ninit; i++)
		tenfree(&s->init[i]);
	free(s->init);
	for(i = 0; i < s->ngin; i++)
		free(s->gin[i].name);
	free(s->gin);
	for(i = 0; i < s->ngout; i++)
		free(s->gout[i].name);
	free(s->gout);
	for(i = 0; i < s->nfeed; i++)
		tenfree(&s->feed[i]);
	free(s->feed);
	for(i = 0; i < s->nres; i++)
		tenfree(&s->res[i]);
	free(s->res);
	for(i = 0; i < s->nsh; i++)
		free(s->shname[i]);
	free(s);
}

int
mlsoft_info(void *h, char *buf, int nbuf)
{
	Soft *s = h;
	int i, j, o;
	Vin *w;

	if(s == nil || buf == nil || nbuf <= 0)
		return -1;
	o = 0;
	for(i = 0; i < s->ngin; i++){
		w = &s->gin[i];
		if(isinit(s, w->name))
			continue;
		o += snprint(buf+o, nbuf-o, "in %s %s", w->name, etypename(w->etype));
		for(j = 0; j < w->nd; j++)
			o += snprint(buf+o, nbuf-o, " %lld", (vlong)w->d[j]);
		o += snprint(buf+o, nbuf-o, "\n");
	}
	for(i = 0; i < s->ngout; i++){
		w = &s->gout[i];
		o += snprint(buf+o, nbuf-o, "out %s %s", w->name, etypename(w->etype));
		for(j = 0; j < w->nd; j++)
			o += snprint(buf+o, nbuf-o, " %lld", (vlong)w->d[j]);
		o += snprint(buf+o, nbuf-o, "\n");
	}
	o += snprint(buf+o, nbuf-o, "device soft (this system's own arithmetic)\n");
	return o;
}

static Vin*
findin(Soft *s, char *name)
{
	int i;

	for(i = 0; i < s->ngin; i++){
		if(isinit(s, s->gin[i].name))
			continue;
		if(name == nil || *name == '\0' || strcmp(s->gin[i].name, name) == 0)
			return &s->gin[i];
	}
	return nil;
}

int
mlsoft_setshape(void *h, char *name, char **dims, int ndims, char *err, int nerr)
{
	Soft *s = h;
	Vin *w;
	int i;

	if(s == nil)
		return -1;
	w = findin(s, name);
	if(w == nil){
		seterr(err, nerr, "the model has no such input");
		return -1;
	}
	if(ndims > Maxdim){
		seterr(err, nerr, "too many dimensions");
		return -1;
	}
	for(i = 0; i < s->nsh; i++)
		if(strcmp(s->shname[i], w->name) == 0)
			break;
	if(i == s->nsh){
		if(s->nsh >= nelem(s->shname)){
			seterr(err, nerr, "too many shapes are pinned");
			return -1;
		}
		s->shname[i] = strdup(w->name);
		if(s->shname[i] == nil)
			return -1;
		s->nsh++;
	}
	s->shnd[i] = ndims;
	for(i = 0; i < ndims; i++)
		s->shdim[s->nsh-1][i] = strtoll(dims[i], nil, 10);
	return 0;
}

int
mlsoft_setinput(void *h, char *name, uchar *b, int n, char *err, int nerr)
{
	Soft *s = h;
	Vin *w;
	Ten t;
	vlong d[Maxdim];
	int i, nd, es, known, open, idx;
	void *p;
	uchar *q;

	if(s == nil)
		return -1;
	w = findin(s, name);
	if(w == nil){
		seterr(err, nerr, "the model has no such input");
		return -1;
	}
	es = esize(w->etype);
	if(es == 0){
		seterr(err, nerr, "that input has a type this cannot read");
		return -1;
	}

	/* the declared shape, with anything pinned by "shape" put in */
	nd = w->nd;
	for(i = 0; i < nd; i++)
		d[i] = w->d[i];
	for(idx = 0; idx < s->nsh; idx++)
		if(strcmp(s->shname[idx], w->name) == 0){
			nd = s->shnd[idx];
			for(i = 0; i < nd; i++)
				d[i] = s->shdim[idx][i];
			break;
		}

	/*
	 * One dimension still open can be worked out from how many bytes
	 * arrived, which is what makes a variable batch usable without having
	 * to say so. Two cannot, and guessing is worse than refusing.
	 */
	known = 1;
	open = -1;
	for(i = 0; i < nd; i++){
		if(d[i] < 0){
			if(open >= 0){
				seterr(err, nerr,
					"more than one dimension is open; say ctl \"shape\"");
				return -1;
			}
			open = i;
		}else
			known *= d[i];
	}
	if(open >= 0){
		if(known <= 0 || n % (known*es) != 0){
			seterr(err, nerr, "those bytes do not divide into the model's shape");
			return -1;
		}
		d[open] = n / (known * es);
		known *= d[open];
	}
	if(known * es != n){
		seterr(err, nerr, "that is the wrong number of bytes for this input");
		return -1;
	}

	memset(&t, 0, sizeof(t));
	t.etype = w->etype;
	t.nd = nd;
	for(i = 0; i < nd; i++)
		t.d[i] = d[i];
	if(tenalloc(&t) < 0)
		return -1;

	/* ml(3)'s wire is big-endian whatever this machine is */
	q = b;
	for(i = 0; i < t.nel; i++, q += es)
		switch(w->etype){
		case Tfloat:
			t.v[i] = tofloat(((u32int)q[0]<<24)|((u32int)q[1]<<16)|
				((u32int)q[2]<<8)|q[3]);
			break;
		case Tdouble:
			t.v[i] = todouble(((uvlong)q[0]<<56)|((uvlong)q[1]<<48)|
				((uvlong)q[2]<<40)|((uvlong)q[3]<<32)|
				((uvlong)q[4]<<24)|((uvlong)q[5]<<16)|
				((uvlong)q[6]<<8)|q[7]);
			break;
		case Tint64:
			t.v[i] = (double)(vlong)(((uvlong)q[0]<<56)|((uvlong)q[1]<<48)|
				((uvlong)q[2]<<40)|((uvlong)q[3]<<32)|
				((uvlong)q[4]<<24)|((uvlong)q[5]<<16)|
				((uvlong)q[6]<<8)|q[7]);
			break;
		case Tint32:
			t.v[i] = (double)(int)(((u32int)q[0]<<24)|((u32int)q[1]<<16)|
				((u32int)q[2]<<8)|q[3]);
			break;
		case Tint8:
			t.v[i] = (double)(schar)*q;
			break;
		case Tuint8:
			t.v[i] = (double)*q;
			break;
		}

	for(i = 0; i < s->nfeed; i++)
		if(strcmp(s->feed[i].name, w->name) == 0){
			free(s->feed[i].v);
			t.name = s->feed[i].name;
			s->feed[i] = t;
			return 0;
		}
	p = realloc(s->feed, (s->nfeed+1)*sizeof(Ten));
	if(p == nil){
		free(t.v);
		return -1;
	}
	s->feed = p;
	t.name = strdup(w->name);
	if(t.name == nil){
		free(t.v);
		return -1;
	}
	s->feed[s->nfeed++] = t;
	return 0;
}

int
mlsoft_run(void *h, char *err, int nerr)
{
	Soft *s = h;
	Env e;
	Ten t, *v;
	int i, r;
	void *p;

	if(s == nil)
		return -1;
	memset(&e, 0, sizeof(e));
	r = -1;

	/* the weights, then whatever was fed in, then the graph in order */
	for(i = 0; i < s->ninit; i++){
		t = s->init[i];
		t.name = nil;
		t.v = malloc((t.nel? t.nel: 1)*sizeof(double));
		if(t.v == nil)
			goto out;
		memmove(t.v, s->init[i].v, t.nel*sizeof(double));
		if(bind(&e, s->init[i].name, &t) < 0){
			free(t.v);
			goto out;
		}
	}
	for(i = 0; i < s->nfeed; i++){
		t = s->feed[i];
		t.name = nil;
		t.v = malloc((t.nel? t.nel: 1)*sizeof(double));
		if(t.v == nil)
			goto out;
		memmove(t.v, s->feed[i].v, t.nel*sizeof(double));
		if(bind(&e, s->feed[i].name, &t) < 0){
			free(t.v);
			goto out;
		}
	}
	for(i = 0; i < s->ngin; i++)
		if(!isinit(s, s->gin[i].name) && lookup(&e, s->gin[i].name) == nil){
			snprint(err, nerr, "nothing was written to the input %s",
				s->gin[i].name);
			goto out;
		}

	/*
	 * ONNX requires the nodes to be in topological order, so one pass is
	 * enough; a node whose input is missing says so rather than looping.
	 */
	for(i = 0; i < s->nnode; i++)
		if(evalnode(&s->node[i], &e, err, nerr) < 0)
			goto out;

	for(i = 0; i < s->nres; i++)
		tenfree(&s->res[i]);
	free(s->res);
	s->res = nil;
	s->nres = 0;
	for(i = 0; i < s->ngout; i++){
		v = lookup(&e, s->gout[i].name);
		if(v == nil){
			snprint(err, nerr, "the graph produced no %s", s->gout[i].name);
			goto out;
		}
		p = realloc(s->res, (s->nres+1)*sizeof(Ten));
		if(p == nil)
			goto out;
		s->res = p;
		t = *v;
		t.name = strdup(s->gout[i].name);
		t.etype = s->gout[i].etype? s->gout[i].etype: v->etype;
		t.v = malloc((t.nel? t.nel: 1)*sizeof(double));
		if(t.name == nil || t.v == nil){
			free(t.name);
			free(t.v);
			goto out;
		}
		memmove(t.v, v->v, t.nel*sizeof(double));
		s->res[s->nres++] = t;
	}
	r = 0;
out:
	envfree(&e);
	return r;
}

int
mlsoft_getoutput(void *h, char *name, uchar *b, int nbuf, char *err, int nerr)
{
	Soft *s = h;
	Ten *t;
	int i, es, n;
	uchar *q;
	union { u32int u; float f; } f32;
	union { uvlong u; double d; } f64;
	vlong iv;

	if(s == nil)
		return -1;
	if(s->nres == 0){
		seterr(err, nerr, "there is no result; run it first");
		return -1;
	}
	t = nil;
	for(i = 0; i < s->nres; i++)
		if(name == nil || *name == '\0' || strcmp(s->res[i].name, name) == 0){
			t = &s->res[i];
			break;
		}
	if(t == nil){
		seterr(err, nerr, "the model has no such output");
		return -1;
	}
	es = esize(t->etype);
	if(es == 0)
		es = 4, t->etype = Tfloat;
	n = t->nel * es;
	if(b == nil)			/* devml asking how big it is */
		return n;
	if(n > nbuf){
		seterr(err, nerr, "the output does not fit the read");
		return -1;
	}
	q = b;
	for(i = 0; i < t->nel; i++, q += es)
		switch(t->etype){
		case Tfloat:
			f32.f = (float)t->v[i];
			q[0] = f32.u>>24; q[1] = f32.u>>16; q[2] = f32.u>>8; q[3] = f32.u;
			break;
		case Tdouble:
			f64.d = t->v[i];
			q[0] = f64.u>>56; q[1] = f64.u>>48; q[2] = f64.u>>40; q[3] = f64.u>>32;
			q[4] = f64.u>>24; q[5] = f64.u>>16; q[6] = f64.u>>8; q[7] = f64.u;
			break;
		case Tint64:
			iv = (vlong)t->v[i];
			q[0] = iv>>56; q[1] = iv>>48; q[2] = iv>>40; q[3] = iv>>32;
			q[4] = iv>>24; q[5] = iv>>16; q[6] = iv>>8; q[7] = iv;
			break;
		case Tint32:
			iv = (vlong)t->v[i];
			q[0] = iv>>24; q[1] = iv>>16; q[2] = iv>>8; q[3] = iv;
			break;
		default:
			q[0] = (uchar)(vlong)t->v[i];
			break;
		}
	return n;
}

/*
 * Not a pointer and not installed by a constructor: this backend is always
 * here, and a static initialiser is the portable way to say so. mlonnx.c has
 * to use a constructor because it is only sometimes linked; this one has no
 * such problem, and native Inferno's compilers have no constructors anyway.
 */
Mlbackend mlsoftbe = {
	"soft",
	mlsoft_open,
	mlsoft_close,
	mlsoft_info,
	mlsoft_setinput,
	mlsoft_run,
	mlsoft_getoutput,
	mlsoft_setshape,
};
