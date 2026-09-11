implement Stats;

# Descriptive statistics, regression and two distributions.  See stats.m
# for where the n-1 goes and why regression is done the textbook way.

include "sys.m";
	sys: Sys;
include "math.m";
	math: Math;
include "linalg.m";
	la: LinAlg;
include "stats.m";

init()
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	la = load LinAlg LinAlg->PATH;
}

total(x: array of real): real
{
	s := 0.0;
	for(i := 0; i < len x; i++)
		s += x[i];
	return s;
}

mean(x: array of real): real
{
	if(len x == 0)
		return 0.0;
	return total(x)/real len x;
}

# Two passes, not the one-pass sum-of-squares formula.  The one-pass
# form subtracts two large nearly equal numbers and loses every figure
# it had: for values around a million with a spread of one, it returns
# zero or a negative variance.  The second pass costs nothing here.
variance(x: array of real): real
{
	n := len x;
	if(n < 2)
		return 0.0;
	m := mean(x);
	s := 0.0;
	for(i := 0; i < n; i++){
		d := x[i] - m;
		s += d*d;
	}
	return s/real(n-1);
}

popvariance(x: array of real): real
{
	n := len x;
	if(n < 1)
		return 0.0;
	return variance(x)*real(n-1)/real n;
}

stddev(x: array of real): real
{
	return math->sqrt(variance(x));
}

popstddev(x: array of real): real
{
	return math->sqrt(popvariance(x));
}

minimum(x: array of real): real
{
	if(len x == 0)
		return 0.0;
	v := x[0];
	for(i := 1; i < len x; i++)
		if(x[i] < v)
			v = x[i];
	return v;
}

maximum(x: array of real): real
{
	if(len x == 0)
		return 0.0;
	v := x[0];
	for(i := 1; i < len x; i++)
		if(x[i] > v)
			v = x[i];
	return v;
}

sorted(x: array of real): array of real
{
	a := array[len x] of real;
	a[0:] = x;
	qsort(a, 0, len a - 1);
	return a;
}

qsort(a: array of real, lo, hi: int)
{
	while(lo < hi){
		# median of three, so that data already in order - which is
		# most data anyone sorts - does not take quadratic time
		mid := lo + (hi-lo)/2;
		if(a[mid] < a[lo])
			swap(a, mid, lo);
		if(a[hi] < a[lo])
			swap(a, hi, lo);
		if(a[hi] < a[mid])
			swap(a, hi, mid);
		p := a[mid];
		(i, j) := (lo, hi);
		while(i <= j){
			while(a[i] < p)
				i++;
			while(a[j] > p)
				j--;
			if(i <= j){
				swap(a, i, j);
				i++;
				j--;
			}
		}
		if(j - lo < hi - i){
			qsort(a, lo, j);
			lo = i;
		} else {
			qsort(a, i, hi);
			hi = j;
		}
	}
}

swap(a: array of real, i, j: int)
{
	t := a[i];
	a[i] = a[j];
	a[j] = t;
}

quantile(x: array of real, p: real): real
{
	n := len x;
	if(n == 0)
		return 0.0;
	if(n == 1)
		return x[0];
	if(p <= 0.0)
		return minimum(x);
	if(p >= 1.0)
		return maximum(x);
	a := sorted(x);
	h := p*real(n-1);
	lo := int h;
	if(real lo > h)
		lo--;			# int rounds in Limbo, and this wants the floor
	if(lo >= n-1)
		return a[n-1];
	f := h - real lo;
	return a[lo] + f*(a[lo+1] - a[lo]);
}

median(x: array of real): real
{
	return quantile(x, 0.5);
}

covariance(x, y: array of real): real
{
	n := len x;
	if(n != len y || n < 2)
		return 0.0;
	(mx, my) := (mean(x), mean(y));
	s := 0.0;
	for(i := 0; i < n; i++)
		s += (x[i]-mx)*(y[i]-my);
	return s/real(n-1);
}

correlation(x, y: array of real): real
{
	(sx, sy) := (stddev(x), stddev(y));
	if(sx == 0.0 || sy == 0.0)
		return 0.0;
	r := covariance(x, y)/(sx*sy);
	# rounding can put it a hair outside, and a correlation above one
	# is a thing a reader would not believe and should not be shown
	if(r > 1.0)
		r = 1.0;
	if(r < -1.0)
		r = -1.0;
	return r;
}

Line.at(l: self ref Line, x: real): real
{
	return l.intercept + l.slope*x;
}

linefit(x, y: array of real): (ref Line, string)
{
	n := len x;
	if(n != len y)
		return (nil, "there must be as many y as x");
	if(n < 2)
		return (nil, "a line needs at least two points");
	(mx, my) := (mean(x), mean(y));
	(sxx, sxy) := (0.0, 0.0);
	for(i := 0; i < n; i++){
		d := x[i]-mx;
		sxx += d*d;
		sxy += d*(y[i]-my);
	}
	if(sxx == 0.0)
		return (nil, "every x is the same, so there is no line through them - only a vertical one, which is not a function");
	l := ref Line;
	l.n = n;
	l.slope = sxy/sxx;
	l.intercept = my - l.slope*mx;
	# how much of the variation the line accounts for
	(sst, sse) := (0.0, 0.0);
	for(i = 0; i < n; i++){
		d := y[i]-my;
		sst += d*d;
		e := y[i] - l.at(x[i]);
		sse += e*e;
	}
	if(sst == 0.0)
		l.r2 = 1.0;		# every y the same: the line explains all of nothing
	else
		l.r2 = 1.0 - sse/sst;
	if(n > 2){
		l.resid = math->sqrt(sse/real(n-2));
		l.slopeerr = l.resid/math->sqrt(sxx);
		l.intercepterr = l.resid*math->sqrt(1.0/real n + mx*mx/sxx);
	}
	return (l, nil);
}

# The normal equations, solved with linalg(2).  Highest power first on
# the way out.
polyfit(x, y: array of real, degree: int): (array of real, string)
{
	n := len x;
	if(n != len y)
		return (nil, "there must be as many y as x");
	if(degree < 0)
		return (nil, "a polynomial's degree is not negative");
	m := degree+1;
	if(n < m)
		return (nil, sys->sprint("a degree-%d polynomial has %d coefficients and "+
			"there are only %d points: more unknowns than equations", degree, m, n));
	xs := array[n] of array of real;
	for(i := 0; i < n; i++){
		xs[i] = array[degree] of real;
		p := 1.0;
		for(k := 0; k < degree; k++){
			p *= x[i];
			xs[i][k] = p;
		}
	}
	(c, e) := multifit(xs, y);
	if(e != nil)
		return (nil, e);
	# multifit gives the intercept first and rising powers after; turn
	# it round, since a polynomial is written with its highest power
	# first everywhere else in this tree
	r := array[m] of real;
	for(i = 0; i < m; i++)
		r[i] = c[m-1-i];
	return (r, nil);
}

polyat(c: array of real, x: real): real
{
	v := 0.0;
	for(i := 0; i < len c; i++)
		v = v*x + c[i];
	return v;
}

multifit(xs: array of array of real, y: array of real): (array of real, string)
{
	if(la == nil)
		return (nil, "linalg is not loaded");
	n := len y;
	if(n != len xs)
		return (nil, "there must be as many rows of predictors as y");
	if(n == 0)
		return (nil, "there is no data");
	k := len xs[0];
	for(i := 1; i < n; i++)
		if(len xs[i] != k)
			return (nil, sys->sprint("row %d has %d predictors and row 0 has %d",
				i, len xs[i], k));
	m := k+1;			# the intercept, then one for each predictor
	if(n < m)
		return (nil, sys->sprint("%d coefficients cannot be found from %d "+
			"observations", m, n));
	# a'a c = a'y, with linalg(2)'s column-major storage
	a := array[m*m] of real;
	b := array[m] of real;
	for(i = 0; i < m*m; i++)
		a[i] = 0.0;
	for(i = 0; i < m; i++)
		b[i] = 0.0;
	row := array[m] of real;
	for(o := 0; o < n; o++){
		row[0] = 1.0;
		for(i = 0; i < k; i++)
			row[i+1] = xs[o][i];
		for(i = 0; i < m; i++){
			b[i] += row[i]*y[o];
			for(j := 0; j < m; j++)
				a[i + m*j] += row[i]*row[j];
		}
	}
	ipvt := array[m] of int;
	if(la->dgefa(a, m, m, ipvt) != 0)
		return (nil, "the predictors are not independent: one of them is a "+
			"combination of the others, so there is no single answer");
	la->dgesl(a, m, m, ipvt, b, 0);
	return (b, nil);
}

rsquared(y, predicted: array of real): real
{
	n := len y;
	if(n == 0 || n != len predicted)
		return 0.0;
	my := mean(y);
	(sst, sse) := (0.0, 0.0);
	for(i := 0; i < n; i++){
		d := y[i]-my;
		sst += d*d;
		e := y[i]-predicted[i];
		sse += e*e;
	}
	if(sst == 0.0)
		return 1.0;
	return 1.0 - sse/sst;
}

# ------------------------------------------------------- distributions

SQRT2: con 1.41421356237309504880168872420969808;
SQRT2PI: con 2.50662827463100050241576528481104525;

normalpdf(x: real): real
{
	return math->exp(-0.5*x*x)/SQRT2PI;
}

# From erfc rather than erf: for a large negative x, 1-erf(x/sqrt2) over
# 2 is the difference of two numbers that are nearly equal and the
# answer comes out zero, while erfc keeps its figures all the way down.
normalcdf(x: real): real
{
	return 0.5*math->erfc(-x/SQRT2);
}

# Bisection to bracket it, then Newton to finish.  A rational
# approximation would be faster and is what most libraries stop at, but
# it is also a fit - its error is whatever its author settled for.
# Bisection cannot diverge and Newton on an exact cdf reaches the last
# bit, so the answer here is as good as erfc is, and statstest(1) checks
# it by putting it back through normalcdf rather than against a table.
normalquantile(p: real): (real, string)
{
	if(p <= 0.0 || p >= 1.0)
		return (0.0, "a quantile is strictly between 0 and 1");
	(lo, hi) := (-40.0, 40.0);		# normalcdf is 0 and 1 well inside this
	for(i := 0; i < 200; i++){
		mid := 0.5*(lo+hi);
		if(normalcdf(mid) < p)
			lo = mid;
		else
			hi = mid;
		if(hi - lo < 1.0e-12*(1.0 + math->fabs(lo)))
			break;
	}
	x := 0.5*(lo+hi);
	for(i = 0; i < 20; i++){
		d := normalpdf(x);
		if(d < 1.0e-300)
			break;
		step := (normalcdf(x) - p)/d;
		x -= step;
		if(math->fabs(step) < 1.0e-16*(1.0 + math->fabs(x)))
			break;
	}
	return (x, nil);
}

# The regularized incomplete beta function, by the continued fraction,
# which is what Student's t is made of.
betacf(a, b, x: real): real
{
	TINY: con 1.0e-300;
	qab := a+b;
	qap := a+1.0;
	qam := a-1.0;
	c := 1.0;
	d := 1.0 - qab*x/qap;
	if(math->fabs(d) < TINY)
		d = TINY;
	d = 1.0/d;
	h := d;
	for(m := 1; m <= 300; m++){
		m2 := 2*m;
		aa := real m*(b - real m)*x/((qam + real m2)*(a + real m2));
		d = 1.0 + aa*d;
		if(math->fabs(d) < TINY)
			d = TINY;
		c = 1.0 + aa/c;
		if(math->fabs(c) < TINY)
			c = TINY;
		d = 1.0/d;
		h *= d*c;
		aa = -(a + real m)*(qab + real m)*x/((a + real m2)*(qap + real m2));
		d = 1.0 + aa*d;
		if(math->fabs(d) < TINY)
			d = TINY;
		c = 1.0 + aa/c;
		if(math->fabs(c) < TINY)
			c = TINY;
		d = 1.0/d;
		del := d*c;
		h *= del;
		if(math->fabs(del - 1.0) < 1.0e-16)
			break;
	}
	return h;
}

ibeta(a, b, x: real): real
{
	if(x <= 0.0)
		return 0.0;
	if(x >= 1.0)
		return 1.0;
	(nil, lga) := math->lgamma(a+b);
	(nil, lgb) := math->lgamma(a);
	(nil, lgc) := math->lgamma(b);
	front := math->exp(lga - lgb - lgc + a*math->log(x) + b*math->log(1.0-x));
	# the fraction converges quickly only on one side of the symmetry
	if(x < (a+1.0)/(a+b+2.0))
		return front*betacf(a, b, x)/a;
	return 1.0 - front*betacf(b, a, 1.0-x)/b;
}

tcdf(t, df: real): real
{
	if(df <= 0.0)
		return 0.0;
	x := df/(df + t*t);
	p := 0.5*ibeta(0.5*df, 0.5, x);
	if(t > 0.0)
		return 1.0 - p;
	return p;
}

tquantile(p, df: real): (real, string)
{
	if(p <= 0.0 || p >= 1.0)
		return (0.0, "a quantile is strictly between 0 and 1");
	if(df <= 0.0)
		return (0.0, "the degrees of freedom must be positive");
	# bisection: the t cdf has no closed-form inverse and bisection
	# cannot diverge, which matters more here than speed
	(lo, hi) := (-1.0e3, 1.0e3);
	for(i := 0; i < 200; i++){
		mid := 0.5*(lo+hi);
		if(tcdf(mid, df) < p)
			lo = mid;
		else
			hi = mid;
		if(hi - lo < 1.0e-13*(1.0 + math->fabs(lo)))
			break;
	}
	return (0.5*(lo+hi), nil);
}

ttest1(x: array of real, mu: real): (ref Test, string)
{
	n := len x;
	if(n < 2)
		return (nil, "a t test needs at least two observations");
	s := stddev(x);
	if(s == 0.0)
		return (nil, "every observation is the same, so the standard error is zero and t is not a number");
	t := ref Test;
	t.df = real(n-1);
	t.statistic = (mean(x) - mu)/(s/math->sqrt(real n));
	t.p = 2.0*tcdf(-math->fabs(t.statistic), t.df);
	return (t, nil);
}

# Welch's, which does not assume the two have the same variance.  The
# pooled test that does is the one in the textbook and is the one that
# is wrong whenever they differ, which is usually.
ttest2(x, y: array of real): (ref Test, string)
{
	(nx, ny) := (len x, len y);
	if(nx < 2 || ny < 2)
		return (nil, "each sample needs at least two observations");
	(vx, vy) := (variance(x)/real nx, variance(y)/real ny);
	if(vx + vy == 0.0)
		return (nil, "neither sample varies at all, so there is no standard error to divide by");
	t := ref Test;
	t.statistic = (mean(x) - mean(y))/math->sqrt(vx + vy);
	# Welch-Satterthwaite
	num := (vx+vy)*(vx+vy);
	den := vx*vx/real(nx-1) + vy*vy/real(ny-1);
	t.df = num/den;
	t.p = 2.0*tcdf(-math->fabs(t.statistic), t.df);
	return (t, nil);
}

meanci(x: array of real, conf: real): (real, real, string)
{
	n := len x;
	if(n < 2)
		return (0.0, 0.0, "an interval needs at least two observations");
	if(conf <= 0.0 || conf >= 1.0)
		return (0.0, 0.0, "a confidence is strictly between 0 and 1");
	(tc, e) := tquantile(0.5 + conf/2.0, real(n-1));
	if(e != nil)
		return (0.0, 0.0, e);
	m := mean(x);
	h := tc*stddev(x)/math->sqrt(real n);
	return (m-h, m+h, nil);
}
