#include	"cc.h"

enum
{
	Mpscale	= 29,		/* safely smaller than bits in a long */
	Mpprec	= 36,		/* Mpscale*Mpprec sb > largest fp exp */
	Mpbase	= 1L<<Mpscale,
};

typedef
struct
{
	long	a[Mpprec];
	char	ovf;
} Mp;

int	mpatof(char*, double*);
int	mpatov(char *s, vlong *v);
void	mpint(Mp*, int);
void	mppow(Mp*, int, int);
void	mpmul(Mp*, int);
void	mpadd(Mp*, Mp*);
int	mptof(Mp*, double*);

/*
 * convert a string, s, to floating in *d
 * return conversion overflow.
 * required syntax is [+-]d*[.]d*[e[+-]d*]
 */
int
mpatof(char *s, double *d)
{
	char *e;
	double v;

	/*
	 * The value is what strtod makes of it, which is correctly
	 * rounded; what was here rounded three times where once is
	 * wanted.  It took the digits into an exact integer, rounded that
	 * to a double, built five to the power of the digits after the
	 * point, rounded that to a double, and divided -- so a constant
	 * could come out one unit in the last place from the double
	 * nearest it.  Of the six coefficients libkern's exp carries, two
	 * did: one high and one low.  A library of coefficients is
	 * exactly where that shows.
	 *
	 * strtod is lib9's, which every one of these compilers already
	 * links, so this is the same conversion on every host the tree
	 * builds on -- which is the reason the compiler had its own in
	 * the first place, and is met either way.
	 */
	v = strtod(s, &e);
	if(e == s)
		return 1;			/* nothing it would take */
	while(*e == ' ' || *e == '\t')
		e++;
	if(*e != '\0')
		return 1;			/* and something left over */
	*d = v;
	return 0;
}

/*
 * convert a to floating in *d
 * return conversion overflow
 */
int
mptof(Mp *a, double *d)
{
	double f, g;
	long x, *a1;
	int i;

	if(a->ovf)
		return 1;
	a1 = a->a;
	f = ldexp(*a1++, 0);
	for(i=Mpscale; i<Mpprec*Mpscale; i+=Mpscale)
		if(x = *a1++) {
			g = ldexp(x, i);
			/*
			 * NOTE: the test (g==0) is plan9
			 * specific. ansi compliant overflow
			 * is signaled by HUGE and errno==ERANGE.
			 * change this for your particular ldexp.
			 */
			if(g == 0)
				return 1;
			f += g;		/* this could bomb! */
		}
	*d = f;
	return 0;
}

/*
 * return a += b
 */
void
mpadd(Mp *a, Mp *b)
{
	int i, c;
	long x, *a1, *b1;

	if(b->ovf)
		a->ovf = 1;
	if(a->ovf)
		return;
	c = 0;
	a1 = a->a;
	b1 = b->a;
	for(i=0; i<Mpprec; i++) {
		x = *a1 + *b1++ + c;
		c = 0;
		if(x >= Mpbase) {
			x -= Mpbase;
			c = 1;
		}
		*a1++ = x;
	}
	a->ovf = c;
}

/*
 * return a = c
 */
void
mpint(Mp *a, int c)
{

	memset(a, 0, sizeof(*a));
	a->a[0] = c;
}

/*
 * return a *= c
 */
void
mpmul(Mp *a, int c)
{
	Mp p;
	int b;

	memmove(&p, a, sizeof(p));
	if(!(c & 1))
		memset(a, 0, sizeof(*a));
	c &= ~1;
	for(b=2; c; b<<=1) {
		mpadd(&p, &p);
		if(c & b) {
			mpadd(a, &p);
			c &= ~b;
		}
	}
}

/*
 * return a *= b**e
 */
void
mppow(Mp *a, int b, int e)
{
	int b1;

	b1 = b*b;
	b1 = b1*b1;
	while(e >= 4) {
		mpmul(a, b1);
		e -= 4;
		if(a->ovf)
			return;
	}
	while(e > 0) {
		mpmul(a, b);
		e--;
	}
}
