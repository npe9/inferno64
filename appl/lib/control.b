implement Control;

# Linear systems as transfer functions.  See control.m for the
# coefficient order (highest power first) and why stability is asked two
# independent ways.

include "sys.m";
	sys: Sys;
include "math.m";
	math: Math;
include "control.m";

init()
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
}

# ---------------------------------------------------------- polynomials

trim(a: array of real): array of real
{
	i := 0;
	while(i < len a - 1 && a[i] == 0.0)
		i++;
	b := array[len a - i] of real;
	b[0:] = a[i:];
	return b;
}

polymul(a, b: array of real): array of real
{
	if(len a == 0 || len b == 0)
		return array[0] of real;
	c := array[len a + len b - 1] of real;
	for(i := 0; i < len c; i++)
		c[i] = 0.0;
	for(i = 0; i < len a; i++)
		for(j := 0; j < len b; j++)
			c[i+j] += a[i]*b[j];
	return c;
}

# highest power first, so the arrays are added from the RIGHT
polyadd(a, b: array of real): array of real
{
	n := len a;
	if(len b > n)
		n = len b;
	c := array[n] of real;
	for(i := 0; i < n; i++)
		c[i] = 0.0;
	for(i = 0; i < len a; i++)
		c[n - len a + i] += a[i];
	for(i = 0; i < len b; i++)
		c[n - len b + i] += b[i];
	return c;
}

polyeval(a: array of real, x: real): real
{
	v := 0.0;
	for(i := 0; i < len a; i++)
		v = v*x + a[i];
	return v;
}

# The polynomial with these roots, monic.  A complex root must be given
# with its conjugate or the result is not real, and it is built by
# multiplying out the quadratic for each pair rather than doing complex
# arithmetic and throwing the imaginary part away.
polyfromroots(re, im: array of real): array of real
{
	p := array[] of {1.0};
	used := array[len re] of int;
	for(i := 0; i < len re; i++)
		used[i] = 0;
	for(i = 0; i < len re; i++){
		if(used[i])
			continue;
		if(im[i] == 0.0){
			p = polymul(p, array[] of {1.0, -re[i]});
			used[i] = 1;
			continue;
		}
		# find the conjugate
		j := -1;
		for(k := i+1; k < len re; k++)
			if(!used[k] && re[k] == re[i] && im[k] == -im[i]){
				j = k;
				break;
			}
		if(j < 0){
			# no conjugate: use the pair it would make anyway, which
			# is the best a real polynomial can do
			p = polymul(p, array[] of {1.0, -2.0*re[i], re[i]*re[i]+im[i]*im[i]});
			used[i] = 1;
			continue;
		}
		p = polymul(p, array[] of {1.0, -2.0*re[i], re[i]*re[i]+im[i]*im[i]});
		used[i] = used[j] = 1;
	}
	return p;
}

# ---------------------------------------------------- transfer functions

tf(num, den: array of real): (ref Tf, string)
{
	if(len den == 0)
		return (nil, "a transfer function needs a denominator");
	d := trim(den);
	if(len d == 1 && d[0] == 0.0)
		return (nil, "the denominator is zero");
	n: array of real;
	if(len num == 0)
		n = array[] of {0.0};
	else
		n = trim(num);
	if(len n > len d)
		return (nil, "the numerator's degree is above the denominator's, which is a system that answers before it is asked");
	t := ref Tf;
	t.num = n;
	t.den = d;
	return (t, nil);
}

Tf.order(t: self ref Tf): int
{
	return len t.den - 1;
}

Tf.proper(t: self ref Tf): int
{
	return len t.num <= len t.den;
}

Tf.dcgain(t: self ref Tf): real
{
	# the value at s = 0, which is the last coefficient of each
	d := t.den[len t.den - 1];
	if(d == 0.0)
		return 0.0;		# a pole at the origin: no finite DC gain
	return t.num[len t.num - 1]/d;
}

Tf.text(t: self ref Tf): string
{
	return polytext(t.num) + " / " + polytext(t.den);
}

polytext(a: array of real): string
{
	s := "";
	n := len a - 1;
	for(i := 0; i < len a; i++){
		p := n - i;
		if(a[i] == 0.0)
			continue;
		if(s != nil && a[i] > 0.0)
			s += " + ";
		else if(a[i] < 0.0)
			s += " - ";
		v := a[i];
		if(v < 0.0)
			v = -v;
		if(v != 1.0 || p == 0)
			s += sys->sprint("%g", v);
		if(p > 0){
			if(v != 1.0)
				s += " ";
			s += "s";
			if(p > 1)
				s += sys->sprint("^%d", p);
		}
	}
	if(s == nil)
		s = "0";
	return s;
}

series(a, b: ref Tf): ref Tf
{
	t := ref Tf;
	t.num = polymul(a.num, b.num);
	t.den = polymul(a.den, b.den);
	return t;
}

parallel(a, b: ref Tf): ref Tf
{
	t := ref Tf;
	t.num = polyadd(polymul(a.num, b.den), polymul(b.num, a.den));
	t.den = polymul(a.den, b.den);
	return t;
}

# g/(1 - sign*g*h); sign = -1 is the negative feedback of a control loop
feedback(g, h: ref Tf, sign: int): (ref Tf, string)
{
	if(sign != 1 && sign != -1)
		return (nil, "the feedback sign is 1 or -1");
	gh := polymul(g.num, h.num);
	if(sign == -1)
		;
	else
		for(i := 0; i < len gh; i++)
			gh[i] = -gh[i];
	num := polymul(g.num, h.den);
	den := polyadd(polymul(g.den, h.den), gh);
	return tf(num, den);
}

# ---------------------------------------------------------------- roots

# Durand-Kerner: start every root somewhere on a circle and let them
# repel each other into place.  All of them at once, rather than one at
# a time with deflation - deflation bakes each root's error into the
# polynomial the next one is found from, and the last roots of a
# high-order polynomial come out visibly wrong.
roots(a: array of real): (array of real, array of real, string)
{
	p := trim(a);
	n := len p - 1;
	if(n < 1){
		# a nonzero constant has no roots, which is an answer; the
		# zero polynomial has every number as a root, which is not
		if(len p == 1 && p[0] == 0.0)
			return (nil, nil, "the polynomial is identically zero, so every number is a root");
		return (array[0] of real, array[0] of real, nil);
	}
	if(p[0] == 0.0)
		return (nil, nil, "the leading coefficient is zero");
	# monic
	c := array[len p] of real;
	for(i := 0; i < len p; i++)
		c[i] = p[i]/p[0];
	(re, im) := (array[n] of real, array[n] of real);
	# the classic starting point, 0.4+0.9i to the kth power: off the
	# real axis, so a real polynomial's symmetry cannot trap them all
	# on it
	(sr, si) := (1.0, 0.0);
	for(i = 0; i < n; i++){
		re[i] = sr;
		im[i] = si;
		t := sr*0.4 - si*0.9;
		si = sr*0.9 + si*0.4;
		sr = t;
	}
	for(iter := 0; iter < 500; iter++){
		moved := 0.0;
		for(i = 0; i < n; i++){
			# p(x_i)
			(nr, ni) := (0.0, 0.0);
			for(k := 0; k < len c; k++){
				t := nr*re[i] - ni*im[i] + c[k];
				ni = nr*im[i] + ni*re[i];
				nr = t;
			}
			# divided by the product of (x_i - x_j), j != i
			(dr, di) := (1.0, 0.0);
			for(j := 0; j < n; j++){
				if(j == i)
					continue;
				(ar, ai) := (re[i]-re[j], im[i]-im[j]);
				t := dr*ar - di*ai;
				di = dr*ai + di*ar;
				dr = t;
			}
			dd := dr*dr + di*di;
			if(dd == 0.0)
				continue;		# two roots on top of each other
			(qr, qi) := ((nr*dr + ni*di)/dd, (ni*dr - nr*di)/dd);
			re[i] -= qr;
			im[i] -= qi;
			m := math->fabs(qr) + math->fabs(qi);
			if(m > moved)
				moved = m;
		}
		if(moved < 1.0e-15)
			break;
	}
	# a real polynomial's roots are real or in conjugate pairs; the
	# iteration leaves a real root with a tiny imaginary part, and
	# reporting 1e-17i as a complex root would make stable() and every
	# plot of them wrong in a way no one would question
	for(i = 0; i < n; i++)
		if(math->fabs(im[i]) < 1.0e-10*(1.0 + math->fabs(re[i])))
			im[i] = 0.0;
	return (re, im, nil);
}

poles(t: ref Tf): (array of real, array of real, string)
{
	return roots(t.den);
}

zeros(t: ref Tf): (array of real, array of real, string)
{
	return roots(t.num);
}

stable(t: ref Tf): (int, string)
{
	(re, nil, e) := poles(t);
	if(e != nil)
		return (0, e);
	for(i := 0; i < len re; i++)
		if(re[i] >= 0.0)
			return (0, nil);
	return (1, nil);
}

# The Routh array.  The number of sign changes in the first column is
# the number of roots with positive real part - which is Routh's
# theorem, and is arrived at without finding a root.
#
# The two degenerate cases are the whole difficulty.  A zero in the
# first column with a nonzero row beside it is replaced by a small
# number of the same sign as what came before, which is the standard
# dodge and gives the right count.  A whole row of zeros means the
# polynomial has roots symmetric about the origin - a conjugate pair on
# the imaginary axis, or a pair at +a and -a - and the row is replaced
# by the derivative of the polynomial the row above stands for.
routh(den: array of real): (int, string)
{
	p := trim(den);
	n := len p - 1;
	if(n < 1)
		return (0, nil);
	if(p[0] == 0.0)
		return (0, "the leading coefficient is zero");
	sign := 1.0;
	if(p[0] < 0.0)
		sign = -1.0;
	rows := n+1;
	cols := (n+2)/2;
	t := array[rows] of array of real;
	for(i := 0; i < rows; i++){
		t[i] = array[cols+1] of real;
		for(j := 0; j < cols+1; j++)
			t[i][j] = 0.0;
	}
	for(i = 0; i <= n; i++)
		t[i%2][i/2] = sign*p[i];
	eps := 1.0e-12;
	for(i = 2; i < rows; i++){
		if(allzero(t[i-1])){
			# the row above stands for a polynomial; differentiate it
			deg := n - (i-2);
			any := 0;
			for(j := 0; j < cols; j++){
				d := real(deg - 2*j);
				t[i-1][j] = t[i-2][j]*d;
				if(t[i-1][j] != 0.0)
					any = 1;
			}
			if(!any)
				return (0, "the polynomial is identically zero from some row on");
		}
		if(t[i-1][0] == 0.0){
			# a zero where a divisor is wanted
			t[i-1][0] = eps;
		}
		for(j := 0; j < cols; j++)
			t[i][j] = (t[i-1][0]*t[i-2][j+1] - t[i-2][0]*t[i-1][j+1])/t[i-1][0];
	}
	changes := 0;
	prev := t[0][0];
	for(i = 1; i < rows; i++){
		v := t[i][0];
		if(v == 0.0)
			v = eps;
		if((v < 0.0) != (prev < 0.0))
			changes++;
		prev = v;
	}
	return (changes, nil);
}

allzero(r: array of real): int
{
	for(i := 0; i < len r; i++)
		if(r[i] != 0.0)
			return 0;
	return 1;
}

# ------------------------------------------------------- time responses
#
# The system is put into controllable canonical form and integrated with
# fourth-order Runge-Kutta.  Not the bilinear transform, which would
# bend the frequency axis, and not a matrix exponential, which would
# need one: the answer wanted here is a curve in time and the error of
# RK4 at a sensible step is far below anything a reader would see.

statespace(t: ref Tf): (array of array of real, array of real, array of real, real, string)
{
	if(!t.proper())
		return (nil, nil, nil, 0.0, "the system is not proper and has no state-space form");
	n := len t.den - 1;
	if(n < 1)
		return (nil, nil, nil, t.num[len t.num-1]/t.den[0], nil);
	a0 := t.den[0];
	a := array[n] of array of real;
	for(i := 0; i < n; i++){
		a[i] = array[n] of real;
		for(j := 0; j < n; j++)
			a[i][j] = 0.0;
	}
	for(i = 0; i < n-1; i++)
		a[i][i+1] = 1.0;
	for(i = 0; i < n; i++)
		a[n-1][i] = -t.den[len t.den - 1 - i]/a0;
	b := array[n] of real;
	for(i = 0; i < n; i++)
		b[i] = 0.0;
	b[n-1] = 1.0;
	# the numerator, padded to the denominator's length, gives c and d
	num := array[len t.den] of real;
	for(i = 0; i < len num; i++)
		num[i] = 0.0;
	num[len num - len t.num:] = t.num;
	d := num[0]/a0;
	c := array[n] of real;
	for(i = 0; i < n; i++)
		c[i] = (num[len num - 1 - i] - d*t.den[len t.den - 1 - i])/a0;
	return (a, b, c, d, nil);
}

deriv(a: array of array of real, b: array of real, x: array of real, u: real): array of real
{
	n := len x;
	dx := array[n] of real;
	for(i := 0; i < n; i++){
		s := b[i]*u;
		for(j := 0; j < n; j++)
			s += a[i][j]*x[j];
		dx[i] = s;
	}
	return dx;
}

# u is sampled at dt; between samples it is taken as its value at the
# left end held constant, which is what a zero-order hold does and what
# a computer driving a plant actually does
lsim(t: ref Tf, u: array of real, dt: real): (array of real, string)
{
	(a, b, c, d, e) := statespace(t);
	if(e != nil)
		return (nil, e);
	np := len u;
	y := array[np] of real;
	if(a == nil){
		for(i := 0; i < np; i++)
			y[i] = d*u[i];
		return (y, nil);
	}
	n := len b;
	x := array[n] of real;
	for(i := 0; i < n; i++)
		x[i] = 0.0;
	for(k := 0; k < np; k++){
		s := d*u[k];
		for(i = 0; i < n; i++)
			s += c[i]*x[i];
		y[k] = s;
		if(k == np-1)
			break;
		# ten RK4 sub-steps a sample, so that the sampling of the
		# answer and the accuracy of the integration are separate
		# questions: a coarse plot is still an accurate one
		h := dt/10.0;
		uu := u[k];
		for(sub := 0; sub < 10; sub++){
			k1 := deriv(a, b, x, uu);
			k2 := deriv(a, b, addv(x, k1, h/2.0), uu);
			k3 := deriv(a, b, addv(x, k2, h/2.0), uu);
			k4 := deriv(a, b, addv(x, k3, h), uu);
			for(i = 0; i < n; i++)
				x[i] += h/6.0*(k1[i] + 2.0*k2[i] + 2.0*k3[i] + k4[i]);
		}
	}
	return (y, nil);
}

addv(x, d: array of real, h: real): array of real
{
	n := len x;
	r := array[n] of real;
	for(i := 0; i < n; i++)
		r[i] = x[i] + h*d[i];
	return r;
}

stepresponse(t: ref Tf, dt: real, n: int): (array of real, string)
{
	u := array[n] of real;
	for(i := 0; i < n; i++)
		u[i] = 1.0;
	return lsim(t, u, dt);
}

# The impulse response is the step response's derivative, and is
# computed that way rather than by hitting the system with a tall
# narrow pulse, whose height and width would then be in the answer.
impulseresponse(t: ref Tf, dt: real, n: int): (array of real, string)
{
	(a, b, c, d, e) := statespace(t);
	if(e != nil)
		return (nil, e);
	if(d != 0.0)
		return (nil, "the numerator's degree equals the denominator's, so the "+
			"impulse response contains a delta at t=0 that samples cannot "+
			"hold; ask for the step response instead");
	y := array[n] of real;
	if(a == nil){
		for(i := 0; i < n; i++)
			y[i] = 0.0;
		return (y, nil);
	}
	# an impulse at t=0 leaves the state at b and the input at zero
	ns := len b;
	x := array[ns] of real;
	for(i := 0; i < ns; i++)
		x[i] = b[i];
	for(k := 0; k < n; k++){
		s := 0.0;
		for(i = 0; i < ns; i++)
			s += c[i]*x[i];
		y[k] = s;
		if(k == n-1)
			break;
		h := dt/10.0;
		for(sub := 0; sub < 10; sub++){
			k1 := deriv(a, b, x, 0.0);
			k2 := deriv(a, b, addv(x, k1, h/2.0), 0.0);
			k3 := deriv(a, b, addv(x, k2, h/2.0), 0.0);
			k4 := deriv(a, b, addv(x, k3, h), 0.0);
			for(i = 0; i < ns; i++)
				x[i] += h/6.0*(k1[i] + 2.0*k2[i] + 2.0*k3[i] + k4[i]);
		}
	}
	return (y, nil);
}

# ------------------------------------------------------------ frequency

bode(t: ref Tf, w: array of real): (array of real, array of real)
{
	nf := len w;
	(m, p) := (array[nf] of real, array[nf] of real);
	off := 0.0;
	prev := 0.0;
	for(i := 0; i < nf; i++){
		(nr, ni) := polyevalj(t.num, w[i]);
		(dr, di) := polyevalj(t.den, w[i]);
		dd := dr*dr + di*di;
		if(dd == 0.0){
			m[i] = math->Infinity;
			p[i] = 0.0;
			continue;
		}
		hr := (nr*dr + ni*di)/dd;
		hi := (ni*dr - nr*di)/dd;
		m[i] = math->sqrt(hr*hr + hi*hi);
		a := math->atan2(hi, hr);
		# unwrap, so a roll-off does not jump by 2 pi in the middle
		if(i > 0){
			while(a + off - prev > math->Pi)
				off -= 2.0*math->Pi;
			while(a + off - prev < -math->Pi)
				off += 2.0*math->Pi;
		}
		p[i] = a + off;
		prev = p[i];
	}
	return (m, p);
}

# the polynomial at s = jw
polyevalj(a: array of real, w: real): (real, real)
{
	(re, im) := (0.0, 0.0);
	for(i := 0; i < len a; i++){
		# multiply by jw, then add the coefficient
		t := -im*w;
		im = re*w;
		re = t + a[i];
	}
	return (re, im);
}

margins(t: ref Tf): (ref Margins, string)
{
	mm := ref Margins;
	mm.hasgain = mm.hasphase = 0;
	mm.gain = math->Infinity;
	mm.phase = math->Infinity;
	# sweep six decades around where the interesting frequencies are
	(pre, nil, e) := poles(t);
	if(e != nil)
		return (nil, e);
	scale := 1.0;
	for(i := 0; i < len pre; i++){
		v := math->fabs(pre[i]);
		if(v > scale)
			scale = v;
	}
	nf := 20000;
	w := array[nf] of real;
	for(i = 0; i < nf; i++)
		w[i] = scale*math->pow(10.0, -4.0 + 8.0*real i/real(nf-1));
	(m, p) := bode(t, w);
	# the phase crossover: where the phase passes -pi
	for(i = 1; i < nf; i++){
		if(crossed(p[i-1], p[i], -math->Pi)){
			f := (-math->Pi - p[i-1])/(p[i]-p[i-1]);
			mg := m[i-1] + f*(m[i]-m[i-1]);
			if(mg > 0.0){
				mm.gain = 1.0/mg;
				mm.gainw = w[i-1] + f*(w[i]-w[i-1]);
				mm.hasgain = 1;
			}
			break;
		}
	}
	# the gain crossover: where the magnitude passes 1
	for(i = 1; i < nf; i++){
		if(crossed(m[i-1], m[i], 1.0)){
			f := (1.0 - m[i-1])/(m[i]-m[i-1]);
			ph := p[i-1] + f*(p[i]-p[i-1]);
			mm.phase = math->Pi + ph;
			mm.phasew = w[i-1] + f*(w[i]-w[i-1]);
			mm.hasphase = 1;
			break;
		}
	}
	return (mm, nil);
}

crossed(a, b, v: real): int
{
	return (a < v && b >= v) || (a > v && b <= v);
}

# -------------------------------------------------------------- metrics

metrics(y: array of real, dt: real): ref Metrics
{
	m := ref Metrics;
	n := len y;
	if(n == 0)
		return m;
	# the final value is what it has settled to, taken as the last
	# tenth averaged, so that a little ripple does not decide it
	s := 0.0;
	c := 0;
	for(i := n - n/10 - 1; i < n; i++){
		if(i < 0)
			continue;
		s += y[i];
		c++;
	}
	if(c > 0)
		m.final = s/real c;
	m.peak = y[0];
	m.peakt = 0.0;
	for(i = 0; i < n; i++)
		if(y[i] > m.peak){
			m.peak = y[i];
			m.peakt = real i*dt;
		}
	if(m.final != 0.0)
		m.overshoot = (m.peak - m.final)/m.final;
	if(m.overshoot < 0.0)
		m.overshoot = 0.0;
	# rise time, 10% to 90%, by interpolating between samples rather
	# than to the nearest one: at a coarse dt the nearest sample is the
	# answer to the nearest dt and nothing better
	t10 := crosstime(y, dt, 0.1*m.final);
	t90 := crosstime(y, dt, 0.9*m.final);
	if(t10 >= 0.0 && t90 >= 0.0)
		m.rise = t90 - t10;
	# settling: the last time it was outside 2% of the final value
	band := 0.02*math->fabs(m.final);
	m.settle = 0.0;
	for(i = 0; i < n; i++)
		if(math->fabs(y[i] - m.final) > band)
			m.settle = real i*dt;
	return m;
}

crosstime(y: array of real, dt, v: real): real
{
	for(i := 1; i < len y; i++)
		if((y[i-1] < v && y[i] >= v) || (y[i-1] > v && y[i] <= v)){
			f := (v - y[i-1])/(y[i]-y[i-1]);
			return (real(i-1) + f)*dt;
		}
	return -1.0;
}

# ----------------------------------------------------------- controllers

pid(kp, ki, kd, taud: real): (ref Tf, string)
{
	if(taud <= 0.0 && kd != 0.0)
		return (nil, "a derivative term needs a filter time constant: a bare kd*s is not proper, cannot be built, and amplifies noise in preference to signal");
	if(kd == 0.0){
		if(ki == 0.0)
			return tf(array[] of {kp}, array[] of {1.0});
		# (kp s + ki)/s
		return tf(array[] of {kp, ki}, array[] of {1.0, 0.0});
	}
	# kp + ki/s + kd s/(taud s + 1), over the common denominator
	# s(taud s + 1)
	den := array[] of {taud, 1.0, 0.0};
	num := polyadd(polymul(array[] of {kp}, array[] of {taud, 1.0, 0.0}),
		polymul(array[] of {ki}, array[] of {taud, 1.0}));
	num = polyadd(num, array[] of {kd, 0.0, 0.0});
	return tf(num, den);
}
