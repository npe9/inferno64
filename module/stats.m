# stats - descriptive statistics, regression, and the two distributions
#
# VARIANCE DIVIDES BY n-1, and so does the standard deviation built on
# it.  That is the sample variance, the estimate of the variance of the
# thing the numbers came from, and it is what is wanted nearly always -
# but the other one exists, is called popvariance here, and the
# difference is invisible in the answer for any n large enough to be
# interesting and glaring for any n small enough to check by hand.  It
# is said here because no test can tell a reader which a library chose.
#
# Regression is by the normal equations through linalg(2).  That is the
# textbook method and is what makes polyfit's answer the same as the one
# a student gets by hand; it is also the numerically worse one, and the
# man page says at what degree that starts to matter.

Stats: module
{
	PATH: con "/dis/lib/stats.dis";

	init:	fn();

	total:	fn(x: array of real): real;
	mean:	fn(x: array of real): real;
	median:	fn(x: array of real): real;
	variance: fn(x: array of real): real;		# divides by n-1
	stddev:	fn(x: array of real): real;
	popvariance: fn(x: array of real): real;	# divides by n
	popstddev: fn(x: array of real): real;
	minimum: fn(x: array of real): real;
	maximum: fn(x: array of real): real;
	# The p-th quantile, 0 to 1, interpolating between the two
	# neighbouring order statistics.  There are nine definitions of
	# this in the literature and they disagree; this is the one R calls
	# type 7 and is the common default.
	quantile: fn(x: array of real, p: real): real;
	sorted:	fn(x: array of real): array of real;

	covariance: fn(x, y: array of real): real;	# divides by n-1
	correlation: fn(x, y: array of real): real;

	# A straight line through points, by least squares.
	Line: adt {
		slope, intercept: real;
		r2:	real;			# the fraction of the variance explained
		slopeerr, intercepterr: real;	# standard errors of the two
		resid:	real;			# the residual standard deviation
		n:	int;

		at:	fn(l: self ref Line, x: real): real;
	};
	linefit: fn(x, y: array of real): (ref Line, string);

	# A polynomial of the given degree, highest power first, to match
	# control(2) and the way a polynomial is written down.
	polyfit: fn(x, y: array of real, degree: int): (array of real, string);
	polyat:	fn(c: array of real, x: real): real;

	# Several predictors at once: xs[i] is the i-th observation's
	# predictors, and the answer is the intercept followed by one
	# coefficient for each predictor.
	multifit: fn(xs: array of array of real, y: array of real): (array of real, string);

	# How much of the variance a set of predictions accounts for.
	rsquared: fn(y, predicted: array of real): real;

	# The normal distribution, from erf, so these are as exact as the
	# library's erf and not a fitted approximation.
	normalpdf: fn(x: real): real;
	normalcdf: fn(x: real): real;
	normalquantile: fn(p: real): (real, string);

	# Student's t, from the incomplete beta function.
	tcdf:	fn(t, df: real): real;
	tquantile: fn(p, df: real): (real, string);

	Test: adt {
		statistic: real;
		df:	real;
		p:	real;		# two-sided
	};
	# One sample against a stated mean, and two samples against each
	# other.  The two-sample test is Welch's, which does NOT assume the
	# two have the same variance - the pooled test that does is the one
	# in the textbook and the one that is wrong whenever they differ.
	ttest1:	fn(x: array of real, mu: real): (ref Test, string);
	ttest2:	fn(x, y: array of real): (ref Test, string);

	# A confidence interval for the mean, at the given confidence
	# (0.95 for the usual one).
	meanci:	fn(x: array of real, conf: real): (real, real, string);
};
