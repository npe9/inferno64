implement Optim;

# Root finding, minimisation, curve fitting and linear programming.
# See optim.m for why the safeguarded methods are the defaults.

include "sys.m";
	sys: Sys;
include "math.m";
	math: Math;
include "linalg.m";
	la: LinAlg;
include "optim.m";

init()
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	la = load LinAlg LinAlg->PATH;
}

# ----------------------------------------------------------------- roots

bracket(f: Fn1, a, b: real): (real, real, string)
{
	if(a == b)
		return (0.0, 0.0, "an interval of no width cannot be widened usefully");
	if(a > b){
		t := a;
		a = b;
		b = t;
	}
	(fa, fb) := (f(a), f(b));
	for(i := 0; i < 60; i++){
		if(fa == 0.0 || fb == 0.0 || (fa < 0.0) != (fb < 0.0))
			return (a, b, nil);
		# widen the side that is closer to zero, which is the side the
		# root is more likely to be on
		w := 0.5*(b-a);
		if(math->fabs(fa) < math->fabs(fb)){
			a -= w;
			fa = f(a);
		} else {
			b += w;
			fb = f(b);
		}
	}
	return (0.0, 0.0, "no sign change found however far the interval was widened");
}

# Brent: bisection, the secant, and inverse quadratic interpolation,
# choosing whichever of the three has just moved far enough to be worth
# trusting.  It cannot fail to converge, because it falls back to
# bisection whenever the clever step does not help.
root(f: Fn1, a, b, tol: real): (real, string)
{
	(fa, fb) := (f(a), f(b));
	if(fa == 0.0)
		return (a, nil);
	if(fb == 0.0)
		return (b, nil);
	if((fa < 0.0) == (fb < 0.0))
		return (0.0, sys->sprint("f(%g) and f(%g) have the same sign, so "+
			"nothing says there is a root between them", a, b));
	if(tol <= 0.0)
		tol = 1.0e-12;
	(c, fc) := (a, fa);
	(d, e) := (b-a, b-a);
	for(iter := 0; iter < 200; iter++){
		if((fb < 0.0) == (fc < 0.0)){
			(c, fc) = (a, fa);
			(d, e) = (b-a, b-a);
		}
		if(math->fabs(fc) < math->fabs(fb)){
			(a, b, c) = (b, c, b);
			(fa, fb, fc) = (fb, fc, fb);
		}
		tol1 := 2.0e-16*math->fabs(b) + 0.5*tol;
		xm := 0.5*(c-b);
		if(math->fabs(xm) <= tol1 || fb == 0.0)
			return (b, nil);
		if(math->fabs(e) >= tol1 && math->fabs(fa) > math->fabs(fb)){
			s := fb/fa;
			(p, q) := (0.0, 0.0);
			if(a == c){
				p = 2.0*xm*s;
				q = 1.0 - s;
			} else {
				qq := fa/fc;
				r := fb/fc;
				p = s*(2.0*xm*qq*(qq-r) - (b-a)*(r-1.0));
				q = (qq-1.0)*(r-1.0)*(s-1.0);
			}
			if(p > 0.0)
				q = -q;
			p = math->fabs(p);
			min1 := 3.0*xm*q - math->fabs(tol1*q);
			min2 := math->fabs(e*q);
			m := min1;
			if(min2 < m)
				m = min2;
			if(2.0*p < m){
				e = d;
				d = p/q;
			} else {
				d = xm;
				e = d;
			}
		} else {
			d = xm;
			e = d;
		}
		(a, fa) = (b, fb);
		if(math->fabs(d) > tol1)
			b += d;
		else if(xm > 0.0)
			b += tol1;
		else
			b -= tol1;
		fb = f(b);
	}
	return (b, "the root did not settle in two hundred steps");
}

# The one everybody writes.  It is here because it is what a course
# teaches and because its failures are worth being able to show.
newton(f, df: Fn1, x0, tol: real, maxit: int): (real, string)
{
	if(maxit <= 0)
		maxit = 100;
	if(tol <= 0.0)
		tol = 1.0e-12;
	x := x0;
	for(i := 0; i < maxit; i++){
		d := df(x);
		if(d == 0.0)
			return (x, sys->sprint("the slope is zero at %g, and Newton's method "+
				"divides by it", x));
		step := f(x)/d;
		x -= step;
		if(math->isnan(x))
			return (x, "the iteration left the real numbers");
		if(math->fabs(step) <= tol*(1.0 + math->fabs(x)))
			return (x, nil);
	}
	return (x, sys->sprint("no root after %d steps", maxit));
}

# ---------------------------------------------------------- minimisation

GOLD: con 0.3819660112501051;		# 2 - golden ratio

minimise1(f: Fn1, a, b, tol: real): (real, real, string)
{
	if(a > b){
		t := a;
		a = b;
		b = t;
	}
	if(tol <= 0.0)
		tol = 1.0e-10;
	(x, w, v) := (a + GOLD*(b-a), 0.0, 0.0);
	w = v = x;
	(fx, fw, fv) := (f(x), 0.0, 0.0);
	fw = fv = fx;
	(d, e) := (0.0, 0.0);
	for(iter := 0; iter < 200; iter++){
		xm := 0.5*(a+b);
		tol1 := tol*math->fabs(x) + 1.0e-12;
		tol2 := 2.0*tol1;
		if(math->fabs(x-xm) <= tol2 - 0.5*(b-a))
			return (x, fx, nil);
		used := 0;
		if(math->fabs(e) > tol1){
			# fit a parabola through the three best points so far
			r := (x-w)*(fx-fv);
			q := (x-v)*(fx-fw);
			p := (x-v)*q - (x-w)*r;
			q = 2.0*(q-r);
			if(q > 0.0)
				p = -p;
			q = math->fabs(q);
			etemp := e;
			e = d;
			if(!(math->fabs(p) >= math->fabs(0.5*q*etemp) ||
			     p <= q*(a-x) || p >= q*(b-x))){
				d = p/q;
				u := x+d;
				if(u-a < tol2 || b-u < tol2){
					d = tol1;
					if(xm < x)
						d = -tol1;
				}
				used = 1;
			}
		}
		if(!used){
			if(x >= xm)
				e = a-x;
			else
				e = b-x;
			d = GOLD*e;
		}
		u := x + d;
		if(math->fabs(d) < tol1){
			if(d >= 0.0)
				u = x + tol1;
			else
				u = x - tol1;
		}
		fu := f(u);
		if(fu <= fx){
			if(u >= x)
				a = x;
			else
				b = x;
			(v, w, x) = (w, x, u);
			(fv, fw, fx) = (fw, fx, fu);
		} else {
			if(u < x)
				a = u;
			else
				b = u;
			if(fu <= fw || w == x){
				(v, fv) = (w, fw);
				(w, fw) = (u, fu);
			} else if(fu <= fv || v == x || v == w){
				(v, fv) = (u, fu);
			}
		}
	}
	return (x, fx, "the minimum did not settle in two hundred steps");
}

# Nelder and Mead.  A simplex of n+1 points crawls downhill by
# reflecting its worst point through the face opposite, stretching when
# that helps and shrinking when it does not.  No derivative anywhere,
# which is the point: a function that is measured rather than written
# down has no derivative to give.
minimise(f: Fnn, start, step: array of real, tol: real, maxit: int): (ref Result, string)
{
	n := len start;
	if(n == 0)
		return (nil, "there is nothing to vary");
	if(step != nil && len step != n)
		return (nil, "there must be one step for each variable");
	if(tol <= 0.0)
		tol = 1.0e-10;
	if(maxit <= 0)
		maxit = 5000;
	np := n+1;
	p := array[np] of array of real;
	fv := array[np] of real;
	for(i := 0; i < np; i++){
		p[i] = array[n] of real;
		p[i][0:] = start;
		if(i > 0){
			s := 0.1*(1.0 + math->fabs(start[i-1]));
			if(step != nil)
				s = step[i-1];
			if(s == 0.0)
				s = 0.1;
			p[i][i-1] += s;
		}
		fv[i] = f(p[i]);
	}
	iter := 0;
	while(iter < maxit){
		# order: lo is best, hi worst, nh next worst
		(lo, hi, nh) := (0, 0, 0);
		for(i = 1; i < np; i++)
			if(fv[i] < fv[lo])
				lo = i;
		hi = lo;
		for(i = 0; i < np; i++)
			if(fv[i] > fv[hi])
				hi = i;
		nh = lo;
		for(i = 0; i < np; i++)
			if(i != hi && fv[i] > fv[nh])
				nh = i;
		# done when the best and worst agree to the tolerance
		d := math->fabs(fv[hi]) + math->fabs(fv[lo]);
		if(d == 0.0)
			d = 1.0;
		if(2.0*math->fabs(fv[hi]-fv[lo])/d < tol)
			break;
		# the centre of the face opposite the worst point
		cen := array[n] of real;
		for(j := 0; j < n; j++){
			s := 0.0;
			for(i = 0; i < np; i++)
				if(i != hi)
					s += p[i][j];
			cen[j] = s/real n;
		}
		refl := combine(cen, p[hi], 2.0);	# reflect
		fr := f(refl);
		iter++;
		if(fr < fv[lo]){
			ext := combine(cen, p[hi], 3.0);	# it helped: go further
			fe := f(ext);
			iter++;
			if(fe < fr){
				p[hi] = ext;
				fv[hi] = fe;
			} else {
				p[hi] = refl;
				fv[hi] = fr;
			}
		} else if(fr < fv[nh]){
			p[hi] = refl;
			fv[hi] = fr;
		} else {
			pull := combine(cen, p[hi], 0.5);	# pull in
			fc := f(pull);
			iter++;
			if(fc < fv[hi]){
				p[hi] = pull;
				fv[hi] = fc;
			} else {
				# nothing worked: shrink the whole simplex onto the best
				for(i = 0; i < np; i++){
					if(i == lo)
						continue;
					for(j = 0; j < n; j++)
						p[i][j] = 0.5*(p[i][j] + p[lo][j]);
					fv[i] = f(p[i]);
					iter++;
				}
			}
		}
	}
	best := 0;
	for(i = 1; i < np; i++)
		if(fv[i] < fv[best])
			best = i;
	r := ref Result;
	r.x = p[best];
	r.value = fv[best];
	r.iterations = iter;
	r.converged = iter < maxit;
	return (r, nil);
}

# cen + t*(cen - worst), so t=2 reflects, t=3 extends, t=0.5 contracts
combine(cen, worst: array of real, t: real): array of real
{
	n := len cen;
	r := array[n] of real;
	for(i := 0; i < n; i++)
		r[i] = cen[i] + (t-1.0)*(cen[i] - worst[i]);
	return r;
}

# ------------------------------------------------------------ curve fit

# Levenberg-Marquardt.  Gauss-Newton is fast and diverges; gradient
# descent is slow and cannot.  This slides between them: a damping
# parameter that grows when a step makes things worse and shrinks when
# it helps, so it behaves like the safe one far away and the fast one
# close in.  Derivatives are taken numerically, so the caller supplies
# only the model.
fit(m: Model, xs, ys, start: array of real, tol: real, maxit: int): (ref Result, string)
{
	if(la == nil)
		return (nil, "linalg is not loaded");
	nd := len xs;
	if(nd != len ys)
		return (nil, "there must be as many y as x");
	np := len start;
	if(np == 0)
		return (nil, "there are no parameters to fit");
	if(nd < np)
		return (nil, sys->sprint("%d parameters cannot be found from %d points",
			np, nd));
	if(tol <= 0.0)
		tol = 1.0e-12;
	if(maxit <= 0)
		maxit = 200;
	p := array[np] of real;
	p[0:] = start;
	chi := sumsq(m, p, xs, ys);
	lambda := 1.0e-3;
	iter := 0;
	converged := 0;
	for(; iter < maxit; iter++){
		# The jacobian of the residuals, by central differences.
		# Second order in the step rather than first, at the cost of
		# one extra evaluation per parameter - but note that on every
		# problem in optimtest(1) a one-sided difference reaches the
		# SAME answer, and that is not an accident: where the model
		# fits exactly the minimum is where the residuals vanish, and
		# an inaccurate jacobian changes the route there and not the
		# destination.  It is kept because it costs little and because
		# it does matter once the residual is not zero, but no test
		# here distinguishes the two and the man page says so.
		jac := array[nd] of array of real;
		for(i := 0; i < nd; i++)
			jac[i] = array[np] of real;
		for(k := 0; k < np; k++){
			h := 1.0e-7*(1.0 + math->fabs(p[k]));
			pk := p[k];
			p[k] = pk + h;
			for(i = 0; i < nd; i++)
				jac[i][k] = m(p, xs[i]);
			p[k] = pk - h;
			for(i = 0; i < nd; i++)
				jac[i][k] = (jac[i][k] - m(p, xs[i]))/(2.0*h);
			p[k] = pk;
		}
		# the normal equations with the damping added to the diagonal
		a := array[np*np] of real;
		g := array[np] of real;
		for(i = 0; i < np*np; i++)
			a[i] = 0.0;
		for(i = 0; i < np; i++)
			g[i] = 0.0;
		for(i = 0; i < nd; i++){
			r := ys[i] - m(p, xs[i]);
			for(j := 0; j < np; j++){
				g[j] += jac[i][j]*r;
				for(k = 0; k < np; k++)
					a[j + np*k] += jac[i][j]*jac[i][k];
			}
		}
		stepped := 0;
		for(try := 0; try < 30; try++){
			ad := array[np*np] of real;
			ad[0:] = a;
			for(i = 0; i < np; i++)
				ad[i + np*i] *= 1.0 + lambda;
			gd := array[np] of real;
			gd[0:] = g;
			ipvt := array[np] of int;
			if(la->dgefa(ad, np, np, ipvt) != 0){
				lambda *= 10.0;
				continue;
			}
			la->dgesl(ad, np, np, ipvt, gd, 0);
			q := array[np] of real;
			for(i = 0; i < np; i++)
				q[i] = p[i] + gd[i];
			nc := sumsq(m, q, xs, ys);
			if(nc < chi){
				rel := (chi - nc)/(1.0 + chi);
				p = q;
				chi = nc;
				lambda /= 10.0;
				if(lambda < 1.0e-12)
					lambda = 1.0e-12;
				stepped = 1;
				if(rel < tol)
					converged = 1;
				break;
			}
			lambda *= 10.0;
			if(lambda > 1.0e12)
				break;
		}
		if(!stepped){
			converged = 1;		# no step helps: this is the bottom
			break;
		}
		if(converged)
			break;
	}
	r := ref Result;
	r.x = p;
	r.value = chi;
	r.iterations = iter;
	r.converged = converged;
	return (r, nil);
}

sumsq(m: Model, p, xs, ys: array of real): real
{
	s := 0.0;
	for(i := 0; i < len xs; i++){
		d := ys[i] - m(p, xs[i]);
		s += d*d;
	}
	return s;
}

# ------------------------------------------------- linear programming

# The simplex method on the standard tableau.  Maximise c.x subject to
# a x <= b, x >= 0, with b >= 0 so that the slack variables are a
# feasible starting point and no first phase is needed.  Bland's rule
# picks the entering column, which is slower than steepest ascent and
# cannot cycle - and a cycling simplex is a program that never returns.
linprog(c: array of real, a: array of array of real, b: array of real): (ref Result, string)
{
	n := len c;
	mrows := len b;
	if(n == 0)
		return (nil, "there is nothing to maximise");
	if(mrows != len a)
		return (nil, "there must be one right-hand side for each constraint");
	for(i := 0; i < mrows; i++){
		if(len a[i] != n)
			return (nil, sys->sprint("constraint %d has %d coefficients and the "+
				"objective has %d variables", i, len a[i], n));
		if(b[i] < 0.0)
			return (nil, sys->sprint("constraint %d has a negative right-hand "+
				"side; this solver needs every b >= 0, so that doing nothing is "+
				"a feasible start", i));
	}
	# the tableau: m rows of (n structural + m slack + 1 rhs), plus the
	# objective row
	w := n + mrows + 1;
	t := array[mrows+1] of array of real;
	for(i = 0; i < mrows+1; i++){
		t[i] = array[w] of real;
		for(j := 0; j < w; j++)
			t[i][j] = 0.0;
	}
	basis := array[mrows] of int;
	for(i = 0; i < mrows; i++){
		for(j := 0; j < n; j++)
			t[i][j] = a[i][j];
		t[i][n+i] = 1.0;
		t[i][w-1] = b[i];
		basis[i] = n+i;
	}
	for(j := 0; j < n; j++)
		t[mrows][j] = -c[j];
	for(iter := 0; iter < 10000; iter++){
		# Bland: the LOWEST-numbered column with a negative cost
		piv := -1;
		for(j = 0; j < w-1; j++)
			if(t[mrows][j] < -1.0e-12){
				piv = j;
				break;
			}
		if(piv < 0){
			# optimal
			r := ref Result;
			r.x = array[n] of real;
			for(j = 0; j < n; j++)
				r.x[j] = 0.0;
			for(i = 0; i < mrows; i++)
				if(basis[i] < n)
					r.x[basis[i]] = t[i][w-1];
			r.value = t[mrows][w-1];
			r.iterations = iter;
			r.converged = 1;
			return (r, nil);
		}
		# the row that runs out first, ties broken by the lowest basis
		# index, which is the other half of Bland's rule
		row := -1;
		best := 0.0;
		for(i = 0; i < mrows; i++){
			if(t[i][piv] <= 1.0e-12)
				continue;
			ratio := t[i][w-1]/t[i][piv];
			if(row < 0 || ratio < best - 1.0e-12 ||
			   (ratio < best + 1.0e-12 && basis[i] < basis[row])){
				row = i;
				best = ratio;
			}
		}
		if(row < 0)
			return (nil, "the objective can be increased without limit: nothing "+
				"in the constraints stops it");
		# pivot
		pv := t[row][piv];
		for(j = 0; j < w; j++)
			t[row][j] /= pv;
		for(i = 0; i < mrows+1; i++){
			if(i == row)
				continue;
			f := t[i][piv];
			if(f == 0.0)
				continue;
			for(j = 0; j < w; j++)
				t[i][j] -= f*t[row][j];
		}
		basis[row] = piv;
	}
	return (nil, "the simplex did not finish in ten thousand pivots");
}
