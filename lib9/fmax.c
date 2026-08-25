/*
 * lib9.h #defines fmax to inffmax ("handle conflicts with host os
 * libs", alongside getwd/scalb/div/panic/rint/rcmd/pow10/round/log2)
 * but, unlike those, never got an inffmax to go with it -- nothing
 * called fmax() through lib9.h until libinterp/math.c's Math_fmax did.
 * Deliberately does not include lib9.h: it needs the real, unmangled
 * libc fmax() to delegate to.
 */

#include <math.h>

double
inffmax(double x, double y)
{
	return fmax(x, y);
}
