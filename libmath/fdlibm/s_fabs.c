/* derived from /netlib/fdlibm */

/* @(#)s_fabs.c 1.3 95/01/18 */
/*
 * ====================================================
 * Copyright (C) 1993 by Sun Microsystems, Inc. All rights reserved.
 *
 * Developed at SunSoft, a Sun Microsystems, Inc. business.
 * Permission to use, copy, modify, and distribute this
 * software is freely granted, provided that this notice 
 * is preserved.
 * ====================================================
 */

/*
 * fabs(x) returns the absolute value of x.
 *
 * KenC/riscv64: do not clear the sign via __HI(x)&= on a double
 * parameter — the write can hit a stack image while the return
 * still uses the unmodified FP register (atan(-x) then saw NaN).
 */

#include "fdlibm.h"

	double fabs(double x)
{
	if(x < 0)
		return -x;
	return x;
}
