#include "lib9.h"
#include "draw.h"

/*
 * ceil(a/bitsperunit) for a positive divisor.  C division truncates
 * towards zero, so for a negative a that is already the ceiling; the
 * (a+b-1)/b form is the ceiling only when a is not negative, and using
 * it on both was the bug below.
 */
static
int
ceildiv(int a, int b)
{
	if(a >= 0)
		return (a + b - 1) / b;
	return -((-a) / b);
}

/*
 * A row runs from the unit boundary at or left of r.min.x up to the unit
 * holding r.max.x-1, so its length is ceil(r.max.x*d/bits) measured from
 * that boundary.
 *
 * This used to add bitsperunit-1 before dividing on the right-hand term
 * as well, which overcounts by one unit when r.max.x is negative - a
 * rectangle lying entirely left of the origin.  It was invisible because
 * the variables were u32 and the negative term wrapped around to the
 * same answer for every other shape, and because such a rectangle is
 * rare: exactly one image in this tree has one.  It was not harmless,
 * though.  libdraw/loadimage.c computes its own per-row length with a
 * shift, which floors, so the two disagreed by a byte a row and every
 * load of that image failed with "bad writeimage call".
 */
static
int
unitsperline(Rectangle r, int d, int bitsperunit)
{
	int l, t;

	if(r.min.x >= 0){
		l = ceildiv(r.max.x*d, bitsperunit);
		l -= (r.min.x*d)/bitsperunit;
	}else{			/* make positive before divide */
		t = ceildiv(-r.min.x*d, bitsperunit);
		l = t + ceildiv(r.max.x*d, bitsperunit);
	}
	return l;
}

int
wordsperline(Rectangle r, int d)
{
	return unitsperline(r, d, 8*sizeof(u32));
}

int
bytesperline(Rectangle r, int d)
{
	return unitsperline(r, d, 8);
}
