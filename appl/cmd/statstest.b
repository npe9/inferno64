implement Statstest;

# statstest - check stats(2) against answers worked out by hand
#
# Most of what a statistics library does has an exact answer on a small
# enough data set, and those are used here rather than numbers copied
# from a run: the mean and variance of eight integers, a least-squares
# line through points that lie exactly on a line, a polynomial of degree
# n-1 through n points, which interpolates them exactly.
#
# The distributions are checked at the values everyone knows - 1.96 is
# the 97.5th percentile of the normal, 2.086 the 97.5th of t with 20
# degrees of freedom - and by round trip, which is stronger: the
# quantile put back through the distribution must return what went in,
# at forty different probabilities.
#
# And by Anscombe's quartet, which is the point of the subject: four
# data sets with the SAME mean, variance, regression line and
# correlation, and utterly different shapes.  A library that got any of
# the four summaries wrong would break the coincidence.

include "sys.m";
	sys: Sys;
include "draw.m";
include "math.m";
	math: Math;
include "stats.m";
	st: Stats;
	Line: import st;

Statstest: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

nfail := 0;
verbose := 0;

fail(s: string)
{
	sys->print("FAIL %s\n", s);
	nfail++;
}

near(what: string, got, want, tol: real)
{
	d := got-want;
	if(d < 0.0)
		d = -d;
	if(math->isnan(got) || d > tol)
		fail(sys->sprint("%s: got %.12g want %.12g", what, got, want));
	else if(verbose)
		sys->print("     %s: %.10g\n", what, got);
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	st = load Stats Stats->PATH;
	if(st == nil || math == nil){
		sys->print("FAIL load: %r\n");
		raise "fail:load";
	}
	st->init();
	for(a := tl argv; a != nil; a = tl a)
		if(hd a == "-v")
			verbose = 1;

	descriptive();
	regression();
	distributions();
	tests();
	anscombe();
	refusals();

	if(nfail == 0)
		sys->print("OK   stats(2) against the hand answers\n");
	else {
		sys->print("%d failures\n", nfail);
		raise "fail:statstest";
	}
}

descriptive()
{
	# 2 4 4 4 5 5 7 9: the set every textbook uses, because its
	# population standard deviation is exactly 2
	x := array[] of {2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0};
	near("the total", st->total(x), 40.0, 0.0);
	near("the mean", st->mean(x), 5.0, 0.0);
	near("the population variance", st->popvariance(x), 4.0, 1.0e-14);
	near("the population standard deviation", st->popstddev(x), 2.0, 1.0e-14);
	# the sample variance divides by 7, not 8: 32/7
	near("the sample variance", st->variance(x), 32.0/7.0, 1.0e-14);
	near("and they are not the same number", st->variance(x) - st->popvariance(x),
		32.0/7.0 - 4.0, 1.0e-14);
	near("the smallest", st->minimum(x), 2.0, 0.0);
	near("the largest", st->maximum(x), 9.0, 0.0);
	# eight values, so the median is between the fourth and fifth: 4.5
	near("the median", st->median(x), 4.5, 1.0e-14);
	# 0, 1/7, 2/7 ... of the way along the sorted values
	near("the 0th quantile", st->quantile(x, 0.0), 2.0, 0.0);
	near("the 100th", st->quantile(x, 1.0), 9.0, 0.0);
	# at p = 1/7 exactly the second value, since h = p*(n-1) = 1
	near("the 1/7th quantile is the second value", st->quantile(x, 1.0/7.0),
		4.0, 1.0e-12);
	# halfway between the 2nd and 3rd
	near("and halfway on is interpolated", st->quantile(x, 1.5/7.0), 4.0, 1.0e-12);
	# sorting must not disturb the caller's array
	y := array[] of {3.0, 1.0, 2.0};
	st->sorted(y);
	if(y[0] != 3.0 || y[1] != 1.0 || y[2] != 2.0)
		fail("sorted() sorted the caller's own array");
	s := st->sorted(y);
	if(s[0] != 1.0 || s[1] != 2.0 || s[2] != 3.0)
		fail("sorted() did not sort");
	# a bigger one, in the worst order for a naive quicksort
	n := 2000;
	ramp := array[n] of real;
	for(i := 0; i < n; i++)
		ramp[i] = real i;			# already sorted
	b := st->sorted(ramp);
	for(i = 1; i < n; i++)
		if(b[i] < b[i-1]){
			fail("sorting an already sorted array broke it");
			break;
		}
	near("the median of 0..1999", st->median(ramp), 999.5, 1.0e-12);

	# the two-pass variance, on numbers where the one-pass formula
	# fails: a million plus a small spread.  The sum of squares is
	# about 1e12 apart from a difference of a few, and subtracting
	# them loses every figure.
	# A THOUSAND MILLION, not a million: at 1e6 every intermediate of
	# the one-pass formula is still a whole number small enough to hold
	# exactly, so it gives 2.5 as well and the test sees nothing.  At
	# 1e9 the sum of squares is 5e18 and the one-pass answer is
	# exactly ZERO.
	w := array[] of {1.0e9+1.0, 1.0e9+2.0, 1.0e9+3.0, 1.0e9+4.0, 1.0e9+5.0};
	near("variance of a thousand million plus 1..5", st->variance(w), 2.5, 1.0e-9);

	# correlation of something with itself is one, and with its
	# negative is minus one
	near("a thing correlates with itself", st->correlation(x, x), 1.0, 1.0e-14);
	m := array[len x] of real;
	for(i = 0; i < len x; i++)
		m[i] = -x[i];
	near("and against its negative", st->correlation(x, m), -1.0, 1.0e-14);
	near("covariance with itself is the variance", st->covariance(x, x),
		st->variance(x), 1.0e-14);
}

regression()
{
	# points exactly on y = 3x - 7
	n := 9;
	(x, y) := (array[n] of real, array[n] of real);
	for(i := 0; i < n; i++){
		x[i] = real i - 4.0;
		y[i] = 3.0*x[i] - 7.0;
	}
	(l, e) := st->linefit(x, y);
	if(e != nil)
		fail("linefit: " + e);
	else {
		near("the slope of an exact line", l.slope, 3.0, 1.0e-13);
		near("its intercept", l.intercept, -7.0, 1.0e-13);
		near("and it explains everything", l.r2, 1.0, 1.0e-14);
		near("with no residual", l.resid, 0.0, 1.0e-12);
		near("and no uncertainty in the slope", l.slopeerr, 0.0, 1.0e-12);
	}
	# now spoil one point: the slope must move in the direction it was
	# pushed, and r2 must fall below one
	y[4] += 9.0;
	(l2, nil) := st->linefit(x, y);
	if(l2 != nil){
		if(l2.r2 >= 1.0)
			fail("a point off the line must cost some of the r squared");
		# the middle point is at x=0, so it lifts the intercept by 1
		# (9 spread over 9 points) and leaves the slope alone
		near("a point moved at the centre lifts the intercept", l2.intercept,
			-7.0 + 1.0, 1.0e-12);
		near("and does not tilt the line", l2.slope, 3.0, 1.0e-12);
		if(l2.slopeerr <= 0.0)
			fail("with a point off the line the slope has an uncertainty");
	}

	# a polynomial of degree n-1 through n points passes through all of
	# them: the fit is an interpolation and the residual is zero
	px := array[] of {-2.0, -1.0, 0.0, 1.0, 2.0, 3.0};
	py := array[len px] of real;
	want := array[] of {2.0, -1.0, 0.5, 3.0, -4.0, 1.0};	# 5th degree
	for(i = 0; i < len px; i++)
		py[i] = st->polyat(want, px[i]);
	(c, e2) := st->polyfit(px, py, 5);
	if(e2 != nil)
		fail("polyfit: " + e2);
	else {
		worst := 0.0;
		for(i = 0; i < len px; i++){
			d := math->fabs(st->polyat(c, px[i]) - py[i]);
			if(d > worst)
				worst = d;
		}
		if(worst > 1.0e-8)
			fail(sys->sprint("a degree-5 polynomial through 6 points misses "+
				"one by %g", worst));
		else if(verbose)
			sys->print("     degree 5 through 6 points, worst miss %g\n", worst);
		# and the coefficients themselves, highest power first
		for(i = 0; i < 6; i++)
			near(sys->sprint("coefficient of x^%d", 5-i), c[i], want[i], 1.0e-6);
	}
	# a quadratic fitted to exactly quadratic data
	qx := array[] of {0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0};
	qy := array[len qx] of real;
	for(i = 0; i < len qx; i++)
		qy[i] = 2.0 + 3.0*qx[i] - qx[i]*qx[i];
	(qc, nil) := st->polyfit(qx, qy, 2);
	if(qc != nil){
		near("the quadratic's x^2 coefficient", qc[0], -1.0, 1.0e-11);
		near("its x coefficient", qc[1], 3.0, 1.0e-11);
		near("its constant", qc[2], 2.0, 1.0e-11);
	}

	# several predictors: y = 5 + 2a - 3b, recovered exactly
	nn := 12;
	xs := array[nn] of array of real;
	yy := array[nn] of real;
	for(i = 0; i < nn; i++){
		a := real(i%4) + 0.5*real(i/4);
		b := real(i/3) - 0.25*real(i%3);
		xs[i] = array[] of {a, b};
		yy[i] = 5.0 + 2.0*a - 3.0*b;
	}
	(mc, e3) := st->multifit(xs, yy);
	if(e3 != nil)
		fail("multifit: " + e3);
	else {
		near("the intercept of a plane", mc[0], 5.0, 1.0e-10);
		near("the first coefficient", mc[1], 2.0, 1.0e-10);
		near("the second", mc[2], -3.0, 1.0e-10);
		pred := array[nn] of real;
		for(i = 0; i < nn; i++)
			pred[i] = mc[0] + mc[1]*xs[i][0] + mc[2]*xs[i][1];
		near("and it explains all of it", st->rsquared(yy, pred), 1.0, 1.0e-12);
	}
	# a line fitted by multifit must agree with linefit exactly: two
	# routes to the same least-squares answer
	xs2 := array[n] of array of real;
	for(i = 0; i < n; i++)
		xs2[i] = array[] of {x[i]};
	(mc2, nil) := st->multifit(xs2, y);
	(l3, nil) := st->linefit(x, y);
	if(mc2 != nil && l3 != nil){
		near("multifit finds the same slope as linefit", mc2[1], l3.slope, 1.0e-10);
		near("and the same intercept", mc2[0], l3.intercept, 1.0e-10);
	}
}

distributions()
{
	near("the normal is a half at zero", st->normalcdf(0.0), 0.5, 1.0e-15);
	near("and symmetric", st->normalcdf(-1.3) + st->normalcdf(1.3), 1.0, 1.0e-15);
	# the numbers everyone knows
	near("1.959963985 is the 97.5th percentile", st->normalcdf(1.959963984540054),
		0.975, 1.0e-12);
	near("1.644853627 is the 95th", st->normalcdf(1.6448536269514722), 0.95, 1.0e-12);
	near("one sigma holds 68.27%", st->normalcdf(1.0)-st->normalcdf(-1.0),
		0.682689492137086, 1.0e-14);
	near("two sigma 95.45%", st->normalcdf(2.0)-st->normalcdf(-2.0),
		0.954499736103642, 1.0e-14);
	near("three sigma 99.73%", st->normalcdf(3.0)-st->normalcdf(-3.0),
		0.997300203936740, 1.0e-14);
	near("the density at zero", st->normalpdf(0.0), 0.3989422804014327, 1.0e-15);
	# FAR out in the tail, which is where building the cdf from erf
	# instead of erfc shows: 1+erf(x) for x below about -6 is one minus
	# a number that rounds to one, and the answer comes out zero.
	# These are small but they are not zero, and a library that said
	# they were would be saying a six-sigma event is impossible.
	tails := array[] of {
		(-10.0, 7.619853024160593e-24),
		(-15.0, 3.6709661993128582e-51),
		(-20.0, 2.7536241186063314e-89),
	};
	for(ti := 0; ti < len tails; ti++){
		(tx, tw) := tails[ti];
		got := st->normalcdf(tx);
		if(got <= 0.0)
			fail(sys->sprint("normalcdf(%g) came out %g: the tail has been "+
				"rounded away entirely", tx, got));
		else if(math->fabs(got-tw)/tw > 1.0e-12)
			fail(sys->sprint("normalcdf(%g): got %.17g want %.17g", tx, got, tw));
		else if(verbose)
			sys->print("     normalcdf(%g) = %.10g\n", tx, got);
	}

	# the round trip, which is stronger than any table: at forty
	# probabilities, and out into the tail where a fitted approximation
	# would show
	worst := 0.0;
	for(i := 1; i <= 40; i++){
		p := real i/41.0;
		(q, e) := st->normalquantile(p);
		if(e != nil){
			fail("normalquantile: " + e);
			break;
		}
		d := math->fabs(st->normalcdf(q) - p);
		if(d > worst)
			worst = d;
	}
	if(worst > 1.0e-15)
		fail(sys->sprint("the normal quantile round trip is off by %g", worst));
	else if(verbose)
		sys->print("     normal quantile round trip to %g\n", worst);
	for(i = 1; i <= 6; i++){
		p := math->pow(10.0, -real i);
		(q, nil) := st->normalquantile(p);
		d := math->fabs(st->normalcdf(q) - p)/p;
		if(d > 1.0e-10)
			fail(sys->sprint("in the tail at p=%g the round trip is off by %g "+
				"relative", p, d));
	}

	# Student's t
	near("t with 1 degree of freedom is a half at zero", st->tcdf(0.0, 1.0), 0.5, 1.0e-14);
	near("and symmetric", st->tcdf(-2.0, 7.0) + st->tcdf(2.0, 7.0), 1.0, 1.0e-14);
	# the table values a course hands out
	(t20, nil) := st->tquantile(0.975, 20.0);
	near("t(20) at 97.5% is 2.086", t20, 2.085963447, 1.0e-6);
	(t1, nil) := st->tquantile(0.975, 1.0);
	near("t(1) at 97.5% is 12.706", t1, 12.70620474, 1.0e-6);
	(t10, nil) := st->tquantile(0.95, 10.0);
	near("t(10) at 95% is 1.812", t10, 1.812461123, 1.0e-6);
	# with one degree of freedom t is the Cauchy distribution, whose
	# cdf is exactly 1/2 + atan(t)/pi - a closed form, not a table
	for(i = -3; i <= 3; i++){
		tt := real i * 0.7;
		near(sys->sprint("t(1) at %.1f is the Cauchy", tt), st->tcdf(tt, 1.0),
			0.5 + math->atan(tt)/math->Pi, 1.0e-12);
	}
	# With two degrees of freedom the t distribution has a closed form
	# too: 1/2 + t/(2 sqrt(2+t^2)).  It is used here because it crosses
	# BOTH branches of the incomplete beta function - small t puts the
	# argument near 1, large t puts it near 0 - and the branch taken is
	# otherwise invisible, since the continued fraction converges on
	# the wrong side of the symmetry as well, only slowly.  With this
	# it has to be right to twelve figures rather than merely close.
	ts := array[] of {0.05, 0.2, 0.5, 1.0, 2.0, 5.0, 20.0};
	for(k := 0; k < len ts; k++){
		tt2 := ts[k];
		cf := 0.5 + tt2/(2.0*math->sqrt(2.0 + tt2*tt2));
		near(sys->sprint("t(2) at %g", tt2), st->tcdf(tt2, 2.0), cf, 1.0e-13);
		near(sys->sprint("t(2) at %g, the other side", -tt2),
			st->tcdf(-tt2, 2.0), 1.0-cf, 1.0e-13);
	}

	# and with many degrees of freedom it becomes the normal.  A LARGE
	# df with a SMALL t is the case that needs the incomplete beta's
	# other branch: it puts the argument a hair under 1, where the
	# continued fraction on the near side converges so slowly that 300
	# iterations are nowhere near enough.  Taking the wrong branch
	# there returns 0.988 where the answer is 0.5004 - and every other
	# check in this program passes while it does.
	# Only small t: the genuine difference between t and the normal
	# grows with t - at t=1 and df=100000 it is 1.2e-6, which is real
	# and not error - so a tight comparison is only meaningful near
	# zero.  That is where the branch matters anyway.
	for(k = 0; k < 3; k++){
		small := math->pow(10.0, -3.0 + real k);
		got := st->tcdf(small, 100000.0);
		nrm := st->normalcdf(small);
		if(math->fabs(got - nrm) > 1.0e-6)
			fail(sys->sprint("t with 100000 degrees of freedom at t=%g should be "+
				"the normal to within a millionth, and it is %.15g against %.15g",
				small, got, nrm));
		else if(verbose)
			sys->print("     t(100000) at %g: %.12g, normal %.12g\n", small, got, nrm);
	}
	near("t(20000) is the normal", st->tcdf(1.5, 20000.0), st->normalcdf(1.5), 1.0e-4);
	if(math->fabs(st->tcdf(1.5, 3.0) - st->normalcdf(1.5)) < 1.0e-3)
		fail("t with 3 degrees of freedom is NOT the normal, and if it looks "+
			"like it the comparison above proves nothing");
}

tests()
{
	# a sample whose mean is exactly 5, tested against 5: t is zero and
	# p is one
	x := array[] of {2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0};
	(t, e) := st->ttest1(x, 5.0);
	if(e != nil)
		fail("ttest1: " + e);
	else {
		near("t against its own mean is zero", t.statistic, 0.0, 1.0e-14);
		near("and p is one", t.p, 1.0, 1.0e-14);
		near("with n-1 degrees of freedom", t.df, 7.0, 0.0);
	}
	# against a mean two standard errors away
	se := st->stddev(x)/math->sqrt(8.0);
	(t2, nil) := st->ttest1(x, 5.0 - 2.0*se);
	if(t2 != nil){
		near("two standard errors out gives t = 2", t2.statistic, 2.0, 1.0e-12);
		near("and the p a t table gives", t2.p, 2.0*st->tcdf(-2.0, 7.0), 1.0e-14);
	}
	# two identical samples cannot differ
	(t3, nil) := st->ttest2(x, x);
	if(t3 != nil){
		near("two identical samples give t = 0", t3.statistic, 0.0, 1.0e-14);
		near("and p = 1", t3.p, 1.0, 1.0e-14);
	}
	# shift one and the difference shows
	y := array[len x] of real;
	for(i := 0; i < len x; i++)
		y[i] = x[i] + 10.0;
	(t4, nil) := st->ttest2(x, y);
	if(t4 != nil){
		if(t4.p > 0.001)
			fail(sys->sprint("two samples ten apart with this spread should be "+
				"clearly different, and p is %g", t4.p));
		# shifting BOTH by the same amount changes nothing
		z := array[len x] of real;
		for(i = 0; i < len x; i++)
			z[i] = x[i] + 10.0;
		(t5, nil) := st->ttest2(y, z);
		near("and two samples shifted alike are identical again",
			t5.statistic, 0.0, 1.0e-13);
	}
	# Welch's degrees of freedom are not n1+n2-2 unless the variances
	# and sizes match; with very different spreads they must not be
	a := array[] of {1.0, 2.0, 3.0, 4.0, 5.0};
	b := array[] of {10.0, 200.0, 3000.0, 4.0, 50000.0};
	(t6, nil) := st->ttest2(a, b);
	if(t6 != nil){
		if(math->fabs(t6.df - 8.0) < 0.5)
			fail(sys->sprint("with spreads this different Welch's degrees of "+
				"freedom are far below n1+n2-2 = 8, and they came to %g", t6.df));
		if(t6.df < 1.0 || t6.df > 8.0)
			fail(sys->sprint("Welch's degrees of freedom must lie between 1 and "+
				"n1+n2-2, and they are %g", t6.df));
		else if(verbose)
			sys->print("     Welch: t=%.4g df=%.4g p=%.4g\n",
				t6.statistic, t6.df, t6.p);
	}

	# a confidence interval: its half-width is t times the standard
	# error, and it must contain the mean
	(lo, hi, e2) := st->meanci(x, 0.95);
	if(e2 != nil)
		fail("meanci: " + e2);
	else {
		m := st->mean(x);
		if(lo >= m || hi <= m)
			fail("the interval does not contain the mean");
		(tc, nil) := st->tquantile(0.975, 7.0);
		near("the interval is t times the standard error wide",
			(hi-lo)/2.0, tc*st->stddev(x)/math->sqrt(8.0), 1.0e-12);
		# a wider confidence gives a wider interval
		(lo2, hi2, nil) := st->meanci(x, 0.99);
		if(hi2-lo2 <= hi-lo)
			fail("99% confidence must be a wider interval than 95%");
	}
}

# Anscombe's quartet.  Four data sets with the same mean, variance,
# regression line and correlation and utterly different shapes - which
# is the whole argument for looking at data and not only at its
# summaries.  As a test it is unusually good: the four agreeing is a
# coincidence that a wrong formula would break.
anscombe()
{
	x1 := array[] of {10.0,8.0,13.0,9.0,11.0,14.0,6.0,4.0,12.0,7.0,5.0};
	x4 := array[] of {8.0,8.0,8.0,8.0,8.0,8.0,8.0,19.0,8.0,8.0,8.0};
	ys := array[] of {
		array[] of {8.04,6.95,7.58,8.81,8.33,9.96,7.24,4.26,10.84,4.82,5.68},
		array[] of {9.14,8.14,8.74,8.77,9.26,8.10,6.13,3.10,9.13,7.26,4.74},
		array[] of {7.46,6.77,12.74,7.11,7.81,8.84,6.08,5.39,8.15,6.42,5.73},
		array[] of {6.58,5.76,7.71,8.84,8.47,7.04,5.25,12.50,5.56,7.91,6.89},
	};
	for(k := 0; k < 4; k++){
		x := x1;
		if(k == 3)
			x = x4;
		y := ys[k];
		near(sys->sprint("set %d: the mean of x", k+1), st->mean(x), 9.0, 1.0e-12);
		near(sys->sprint("set %d: the variance of x", k+1), st->variance(x), 11.0, 1.0e-12);
		# The quartet's agreement in y is not exact and was never
		# claimed to be: the means agree to two decimal places (7.50)
		# and the variances to about three (4.125 give or take 0.003).
		# Asserting more than that is asserting something about
		# Anscombe's arithmetic rather than about this library.
		near(sys->sprint("set %d: the mean of y", k+1), st->mean(y), 7.50, 5.0e-3);
		near(sys->sprint("set %d: the variance of y", k+1), st->variance(y),
			4.125, 5.0e-3);
		(l, e) := st->linefit(x, y);
		if(e != nil){
			fail("anscombe: " + e);
			continue;
		}
		near(sys->sprint("set %d: the slope", k+1), l.slope, 0.5, 1.0e-3);
		near(sys->sprint("set %d: the intercept", k+1), l.intercept, 3.0, 1.0e-2);
		near(sys->sprint("set %d: r squared", k+1), l.r2, 0.666, 1.0e-3);
		near(sys->sprint("set %d: the correlation", k+1), st->correlation(x, y),
			0.816, 1.0e-3);
	}
	if(verbose)
		sys->print("     Anscombe: four different data sets, one regression line\n");
}

refusals()
{
	(nil, e1) := st->linefit(array[] of {1.0, 1.0, 1.0}, array[] of {1.0, 2.0, 3.0});
	if(e1 == nil)
		fail("there is no line of y against x when every x is the same");
	(nil, e2) := st->linefit(array[] of {1.0}, array[] of {1.0});
	if(e2 == nil)
		fail("one point does not determine a line");
	(nil, e3) := st->linefit(array[] of {1.0, 2.0}, array[] of {1.0});
	if(e3 == nil)
		fail("mismatched lengths should be refused");
	(nil, e4) := st->linefit(array[] of {1.0, 2.0}, array[] of {1.0, 2.0});
	if(e4 != nil)
		fail("two points do determine a line: " + e4);
	(nil, e5) := st->polyfit(array[] of {1.0, 2.0, 3.0}, array[] of {1.0, 2.0, 3.0}, 5);
	if(e5 == nil)
		fail("a degree-5 polynomial cannot be found from three points");
	# two predictors that are the same predictor
	xs := array[4] of array of real;
	for(i := 0; i < 4; i++)
		xs[i] = array[] of {real i, 2.0*real i};
	(nil, e6) := st->multifit(xs, array[] of {1.0, 2.0, 3.0, 4.0});
	if(e6 == nil)
		fail("two predictors that are multiples of each other leave the "+
			"coefficients undetermined, and should be refused");
	(nil, e7) := st->normalquantile(0.0);
	if(e7 == nil)
		fail("there is no 0th quantile of the normal");
	(nil, e8) := st->normalquantile(1.0);
	if(e8 == nil)
		fail("nor a 100th");
	(nil, e9) := st->tquantile(0.5, -1.0);
	if(e9 == nil)
		fail("negative degrees of freedom should be refused");
	(nil, e10) := st->ttest1(array[] of {3.0, 3.0, 3.0}, 2.0);
	if(e10 == nil)
		fail("a sample that does not vary has no standard error to divide by");
	(nil, nil, e11) := st->meanci(array[] of {1.0, 2.0, 3.0}, 1.5);
	if(e11 == nil)
		fail("a confidence above 1 should be refused");
}
