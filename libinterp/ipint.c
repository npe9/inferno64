#include "lib9.h"
#include "kernel.h"
#include "isa.h"
#include "interp.h"
#include "runt.h"
#include "../include/mp.h"
#include "libsec.h"
#include "pool.h"
#include "ipint.h"
#include "raise.h"

#include "ipintsmod.h"

void mpand(mpint*, mpint*, mpint*);
void mpor(mpint*, mpint*, mpint*);
void mpxor(mpint*, mpint*, mpint*);
void mpnot(mpint*, mpint*);

enum
{
	MaxBigBytes = 1024
};

/* infinite precision integer */
struct IPint
{
	IPints_IPint x;
	mpint*	b;
};

Type	*TIPint;
static uchar IPintmap[] = IPints_IPint_map;

#define	MP(x)	checkIPint((x))

void
ipintsmodinit(void)
{
	/* can be called from modinit, Keyring or Crypt */
	if(TIPint == nil)
		TIPint = dtype(freeIPint, sizeof(IPint), IPintmap, sizeof(IPintmap));
	builtinmod("$IPints", IPintsmodtab, IPintsmodlen);
}

//IPints_IPint*
void*
newIPint(mpint* b)
{
	Heap *h;
	IPint *ip;

	if(b == nil)
		error(exHeap);
	h = heap(TIPint);	/* TO DO: caller might lose other values if heap raises error here */
	ip = H2D(IPint*, h);
	ip->b = b;
	return (IPints_IPint*)ip;
}

mpint*
checkIPint(void *a)
{
	IPints_IPint *v;
	IPint *ip;

	v = a;
	ip = (IPint*)v;
	if(ip == H || ip == nil)
		error(exNilref);
	if(D2H(ip)->t != TIPint)
		error(exType);
	return ip->b;	/* non-nil by construction */
}

void
freeIPint(Heap *h, int swept)
{
	IPint *ip;

	USED(swept);
	ip = H2D(IPint*, h);
	if(ip->b)
		mpfree(ip->b);
	freeheap(h, 0);
}

void
IPint_iptob64z(void *fp)
{
	F_IPint_iptob64 *f;
	mpint *b;
	char buf[MaxBigBytes];	/* TO DO: should allocate these */
	uchar *p;
	int n, o;
	void *v;
	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	b = MP(f->i);
	n = (b->top+1)*Dbytes;
	p = malloc(n+1);
	if(p == nil)
		error(exHeap);
	n = mptobe(b, p+1, n, nil);
	if(n < 0){
		free(p);
		return;
	}
	p[0] = 0;
	if(n != 0 && (p[1]&0x80)){
		/* force leading 0 byte for compatibility with older representation */
		o = 0;
		n++;
	}else
		o = 1;
	enc64(buf, sizeof(buf), p+o, n);
	retstr(buf, f->ret);
	free(p);
}

void
IPint_iptob64(void *fp)
{
	F_IPint_iptob64 *f;
	char buf[MaxBigBytes];
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	mptoa(MP(f->i), 64, buf, sizeof(buf));
	retstr(buf, f->ret);
}

void
IPint_iptobytes(void *fp)
{
	F_IPint_iptobytes *f;
	uchar buf[MaxBigBytes];
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	/* TO DO: two's complement or have ipmagtobe? */
	*f->ret = mem2array(buf, mptobe(MP(f->i), buf, sizeof(buf), nil));	/* for now we'll ignore sign */
}

void
IPint_iptobebytes(void *fp)
{
	F_IPint_iptobebytes *f;
	uchar buf[MaxBigBytes];
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	*f->ret = mem2array(buf, mptobe(MP(f->i), buf, sizeof(buf), nil));
}

void
IPint_iptostr(void *fp)
{
	F_IPint_iptostr *f;
	char buf[MaxBigBytes];
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	mptoa(MP(f->i), f->base, buf, sizeof(buf));
	retstr(buf, f->ret);
}

void
ipinttostr(void *ip, int base, char *buf, int buflen)
{
	mptoa(MP(ip), base, buf, buflen);
}

static IPints_IPint*
strtoipint(String *s, int base)
{
	char *p, *q;
	mpint *b;

	p = string2c(s);
	b = strtomp(p, &q, base, nil);
	if(b == nil)
		return H;
	while(*q == '=')
		q++;
	if(q == p || *q != 0){
		mpfree(b);
		return H;
	}
	return newIPint(b);
}

void
IPint_b64toip(void *fp)
{
	F_IPint_b64toip *f;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	*f->ret = strtoipint(f->str, 64);
}

void
IPint_bytestoip(void *fp)
{
	F_IPint_bytestoip *f;
	mpint *b;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	if(f->buf == H)
		error(exNilref);

	b = betomp(f->buf->data, f->buf->len, nil);	/* for now we'll ignore sign */
	*f->ret = newIPint(b);
}

void
IPint_bebytestoip(void *fp)
{
	F_IPint_bebytestoip *f;
	mpint *b;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	if(f->mag == H)
		error(exNilref);

	b = betomp(f->mag->data, f->mag->len, nil);
	*f->ret = newIPint(b);
}

void
IPint_strtoip(void *fp)
{
	F_IPint_strtoip *f;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	*f->ret = strtoipint(f->str, f->base);
}

/* create a random integer */
void
IPint_random(void *fp)
{
	F_IPint_random *f;
	mpint *b;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	release();
	b = mprand(f->nbits, genrandom, nil);
	acquire();
	*f->ret = newIPint(b);
}

/* number of bits in number */
void
IPint_bits(void *fp)
{
	F_IPint_bits *f;
	int n;

	f = fp;
	*f->ret = 0;
	if(f->i == H)
		return;

	n = mpsignif(MP(f->i));
	if(n == 0)
		n = 1;	/* compatibility */
	*f->ret = n;
}

/* create a new IP from an int */
void
IPint_inttoip(void *fp)
{
	F_IPint_inttoip *f;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	*f->ret = newIPint(itomp(f->i, nil));
}

void
IPint_iptoint(void *fp)
{
	F_IPint_iptoint *f;

	f = fp;
	*f->ret = 0;
	if(f->i == H)
		return;
	*f->ret = mptoi(MP(f->i));
}

/*
 * Two of libmp's failures are things a Limbo program can ask for, so
 * they are raised rather than fatal; the strings are this module's own,
 * since the interpreter has no name for either.
 */
static char exNegexp[] = "negative exponent";
static char exNoinverse[] = "no inverse";

/*
 * libmp answers a division by zero with sysfatal, which on a native
 * kernel is a panic: one line of Limbo could stop the machine.  Every
 * builtin here that divides checks first and raises the same exception
 * the Dis instruction set raises for integer division by zero, so a
 * program can catch it.
 */
static void
nonzero(mpint *m)
{
	if(m->top == 0)
		error(exZdiv);
}

/* modular exponentiation */
void
IPint_expmod(void *fp)
{
	F_IPint_expmod *f;
	mpint *ret, *mod, *base, *exp;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	base = MP(f->base);
	exp = MP(f->exp);
	if(f->mod != H){
		mod = MP(f->mod);
		nonzero(mod);
	}else
		mod = nil;
	/*
	 * mpexp answers a negative exponent with sysfatal; see nonzero.
	 * The test is mpexp's own -- a sign field alone would differ
	 * from it for a negative zero.
	 */
	if(mpcmp(exp, mpzero) < 0)
		error(exNegexp);
	ret = mpnew(0);
	if(ret != nil)
		mpexp(base, exp, mod, ret);
	*f->ret = newIPint(ret);
}

/*
 * multiplicative inverse.  The extended gcd is done here rather than in
 * mpinvert because mpinvert answers "no inverse" with sysfatal, and a
 * base sharing a factor with the modulus is something a Limbo program
 * can arrive at by arithmetic rather than by a bug -- it should get an
 * exception it can catch, not a stopped machine.
 */
void
IPint_invert(void *fp)
{
	F_IPint_invert *f;
	mpint *b, *m, *ret, *g, *dc;
	void *v;
	int r;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	b = MP(f->base);
	m = MP(f->mod);
	nonzero(m);
	ret = mpnew(0);
	if(ret != nil){
		g = mpnew(0);
		dc = mpnew(0);
		if(g == nil || dc == nil){
			mpfree(g);
			mpfree(dc);
			mpfree(ret);
			error(exHeap);
		}
		mpextendedgcd(b, m, g, ret, dc);
		r = mpcmp(g, mpone);
		mpfree(g);
		mpfree(dc);
		if(r != 0){
			mpfree(ret);
			error(exNoinverse);
		}
		mpmod(ret, m, ret);
	}
	*f->ret = newIPint(ret);
}

/* basic math */
void
IPint_add(void *fp)
{
	F_IPint_add *f;
	mpint *i1, *i2, *ret;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	i1 = MP(f->i1);
	i2 = MP(f->i2);
	ret = mpnew(0);
	if(ret != nil)
		mpadd(i1, i2, ret);

	*f->ret = newIPint(ret);
}
void
IPint_sub(void *fp)
{
	F_IPint_sub *f;
	mpint *i1, *i2, *ret;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	i1 = MP(f->i1);
	i2 = MP(f->i2);
	ret = mpnew(0);
	if(ret != nil)
		mpsub(i1, i2, ret);

	*f->ret = newIPint(ret);
}
void
IPint_mul(void *fp)
{
	F_IPint_mul *f;
	mpint *i1, *i2, *ret;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	i1 = MP(f->i1);
	i2 = MP(f->i2);
	ret = mpnew(0);
	if(ret != nil)
		mpmul(i1, i2, ret);

	*f->ret = newIPint(ret);
}
/*
 * i1 op i2 mod m, for op in multiply, add, subtract.  Separately from
 * mul, add, sub and mod because a field operation is what
 * elliptic-curve arithmetic spends itself on, and done as two calls it
 * pays twice to leave interpreted Dis and allocates an unreduced
 * intermediate the caller never reads.  Measured: a 256-bit multiply
 * and reduction is 10.25 us as two calls and 6.50 us as one.
 *
 * mpmod reduces into the range [0,m) whatever the sign, so subtract
 * needs nothing else to keep a field element canonical.
 */
static void
modop(IPints_IPint **retp, IPints_IPint *a1, IPints_IPint *a2, IPints_IPint *am,
	void (*op)(mpint*, mpint*, mpint*))
{
	mpint *i1, *i2, *m, *t, *ret;
	void *v;

	v = *retp;
	*retp = H;
	destroy(v);

	i1 = MP(a1);
	i2 = MP(a2);
	m = MP(am);
	nonzero(m);
	ret = mpnew(0);
	if(ret != nil){
		/*
		 * the unreduced value goes in a temporary rather than in
		 * ret: mpmod is mpdiv, which writes its remainder from a
		 * copy of the dividend and then takes that dividend's
		 * sign, so handing it the same mpint twice depends on an
		 * aliasing rule libmp does not state.
		 */
		t = mpnew(0);
		if(t == nil){
			mpfree(ret);
			error(exHeap);
		}
		(*op)(i1, i2, t);
		mpmod(t, m, ret);
		mpfree(t);
	}

	*retp = newIPint(ret);
}

void
IPint_mulmod(void *fp)
{
	F_IPint_mulmod *f;

	f = fp;
	modop(f->ret, f->i1, f->i2, f->m, mpmul);
}

void
IPint_addmod(void *fp)
{
	F_IPint_addmod *f;

	f = fp;
	modop(f->ret, f->i1, f->i2, f->m, mpadd);
}

void
IPint_submod(void *fp)
{
	F_IPint_submod *f;

	f = fp;
	modop(f->ret, f->i1, f->i2, f->m, mpsub);
}

void
IPint_div(void *fp)
{
	F_IPint_div *f;
	mpint *i1, *i2, *quo, *rem;
	void *v;

	f = fp;
	v = f->ret->t0;
	f->ret->t0 = H;
	destroy(v);
	v = f->ret->t1;
	f->ret->t1 = H;
	destroy(v);

	i1 = MP(f->i1);
	i2 = MP(f->i2);
	nonzero(i2);
	quo = mpnew(0);
	if(quo == nil)
		error(exHeap);
	rem = mpnew(0);
	if(rem == nil){
		mpfree(quo);
		error(exHeap);
	}
	mpdiv(i1, i2, quo, rem);

	f->ret->t0 = newIPint(quo);
	f->ret->t1 = newIPint(rem);
}
void
IPint_mod(void *fp)
{
	F_IPint_mod *f;
	mpint *i1, *i2, *ret;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	i1 = MP(f->i1);
	i2 = MP(f->i2);
	nonzero(i2);
	ret = mpnew(0);
	if(ret != nil)
		mpmod(i1, i2, ret);

	*f->ret = newIPint(ret);
}
void
IPint_neg(void *fp)
{
	F_IPint_neg *f;
	mpint *ret;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	ret = mpcopy(MP(f->i));
	if(ret == nil)
		error(exHeap);
	ret->sign = -ret->sign;

	*f->ret = newIPint(ret);
}

/* copy */
void
IPint_copy(void *fp)
{
	F_IPint_copy *f;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	*f->ret = newIPint(mpcopy(MP(f->i)));
}


/* equality */
void
IPint_eq(void *fp)
{
	F_IPint_eq *f;

	f = fp;
	*f->ret = mpcmp(MP(f->i1), MP(f->i2)) == 0;
}

/* compare */
void
IPint_cmp(void *fp)
{
	F_IPint_eq *f;

	f = fp;
	*f->ret = mpcmp(MP(f->i1), MP(f->i2));
}

/* shifts */
void
IPint_shl(void *fp)
{
	F_IPint_shl *f;
	mpint *ret, *i;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	i = MP(f->i);
	ret = mpnew(0);
	if(ret != nil)
		mpleft(i, f->n, ret);
	*f->ret = newIPint(ret);
}
void
IPint_shr(void *fp)
{
	F_IPint_shr *f;
	mpint *ret, *i;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	i = MP(f->i);
	ret = mpnew(0);
	if(ret != nil)
		mpright(i, f->n, ret);
	*f->ret = newIPint(ret);
}

/* bits */
void
IPint_and(void *fp)
{
	F_IPint_and *f;
	mpint *ret, *i1, *i2;
	void *v;
print("IPint_and fp 0x%p\n", fp);

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	i1 = MP(f->i1);
	i2 = MP(f->i2);
	ret = mpnew(0);
	if(ret != nil)
		mpand(i1, i2, ret);
	*f->ret = newIPint(ret);
}

void
IPint_ori(void *fp)
{
	F_IPint_ori *f;
	mpint *ret, *i1, *i2;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	i1 = MP(f->i1);
	i2 = MP(f->i2);
	ret = mpnew(0);
	if(ret != nil)
		mpor(i1, i2, ret);
	*f->ret = newIPint(ret);
}

void
IPint_xor(void *fp)
{
	F_IPint_xor *f;
	mpint *ret, *i1, *i2;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	i1 = MP(f->i1);
	i2 = MP(f->i2);
	ret = mpnew(0);
	if(ret != nil)
		mpxor(i1, i2, ret);
	*f->ret = newIPint(ret);
}

void
IPint_not(void *fp)
{
	F_IPint_not *f;
	mpint *ret, *i1;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	i1 = MP(f->i1);
	ret = mpnew(0);
	if(ret != nil)
		mpnot(i1, ret);
	*f->ret = newIPint(ret);
}

/*
 * primes
 */

void
IPints_probably_prime(void *fp)
{
	F_IPints_probably_prime *f;

	f = fp;
	release();
	*f->ret = probably_prime(checkIPint(f->n), f->nrep);
	acquire();
}

void
IPints_genprime(void *fp)
{
	F_IPints_genprime *f;
	mpint *p;
	void *r;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);
	p = mpnew(0);
	release();
	genprime(p, f->nbits, f->nrep);
	acquire();
	*f->ret = newIPint(p);
}

void
IPints_genstrongprime(void *fp)
{
	F_IPints_genstrongprime *f;
	mpint *p;
	void *r;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);
	p = mpnew(0);
	release();
	genstrongprime(p, f->nbits, f->nrep);
	acquire();
	*f->ret = newIPint(p);
}

void
IPints_gensafeprime(void *fp)
{
	F_IPints_gensafeprime *f;
	mpint *p, *alpha;
	void *v;

	f = fp;
	v = f->ret->t0;
	f->ret->t0 = H;
	destroy(v);
	v = f->ret->t1;
	f->ret->t1 = H;
	destroy(v);

	p = mpnew(0);
	alpha = mpnew(0);
	release();
	gensafeprime(p, alpha, f->nbits, f->nrep);
	acquire();
	f->ret->t0 = newIPint(p);
	f->ret->t1 = newIPint(alpha);
}

void
IPints_DSAprimes(void *fp)
{
	F_IPints_DSAprimes *f;
	mpint *p, *q;
	Heap *h;
	void *v;

	f = fp;
	v = f->ret->t0;
	f->ret->t0 = H;
	destroy(v);
	v = f->ret->t1;
	f->ret->t1 = H;
	destroy(v);
	v = f->ret->t2;
	f->ret->t2 = H;
	destroy(v);

	h = heaparray(&Tbyte, SHA1dlen);
	f->ret->t2 = H2D(Array*, h);

	p = mpnew(0);
	q = mpnew(0);
	release();
	DSAprimes(q, p, f->ret->t2->data);
	acquire();
	f->ret->t0 = newIPint(q);
	f->ret->t1 = newIPint(p);
}
