implement Orbital;

# Hydrogen wave functions.  See orbital.m for what is here and why the
# angular part is the real form rather than the complex one.
#
# Nothing is hard-coded per state: the radial part is the general
# formula with an associated Laguerre polynomial by recurrence, and the
# angular part an associated Legendre by recurrence.  Writing out R_10,
# R_21 and the rest as separate cases is the obvious way and stops at
# whatever n somebody had the patience for; this way n is bounded only
# by the factorials, and orbitaltest(1) can check states nobody thought
# to write down.

include "sys.m";
	sys: Sys;
include "math.m";
	math: Math;
include "orbital.m";

init()
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
}

fact(n: int): real
{
	r := 1.0;
	for(i := 2; i <= n; i++)
		r *= real i;
	return r;
}

# Associated Laguerre L^a_k(x), by the standard three-term recurrence.
laguerre(k, a: int, x: real): real
{
	if(k < 0)
		return 0.0;
	if(k == 0)
		return 1.0;
	lm1 := 1.0;
	l := 1.0 + real a - x;
	for(i := 1; i < k; i++){
		next := ((2.0*real i + 1.0 + real a - x)*l - (real i + real a)*lm1)/real(i+1);
		lm1 = l;
		l = next;
	}
	return l;
}

# Associated Legendre P_l^m(u) for m >= 0, by recurrence from P_m^m.
legendre(l, m: int, u: real): real
{
	if(m < 0 || m > l)
		return 0.0;
	pmm := 1.0;
	if(m > 0){
		s := math->sqrt((1.0-u)*(1.0+u));
		f := 1.0;
		for(i := 1; i <= m; i++){
			pmm *= -f*s;
			f += 2.0;
		}
	}
	if(l == m)
		return pmm;
	pmmp1 := u*(2.0*real m + 1.0)*pmm;
	if(l == m+1)
		return pmmp1;
	pll := 0.0;
	for(ll := m+2; ll <= l; ll++){
		pll = ((2.0*real ll - 1.0)*u*pmmp1 - (real(ll+m) - 1.0)*pmm)/real(ll-m);
		pmm = pmmp1;
		pmmp1 = pll;
	}
	return pll;
}

radial(n, l: int, z, r: real): real
{
	if(n < 1 || l < 0 || l >= n || r < 0.0)
		return 0.0;
	rho := 2.0*z*r/real n;
	# the normalisation that makes the integral of R^2 r^2 dr come to 1
	nrm := math->sqrt((2.0*z/real n)*(2.0*z/real n)*(2.0*z/real n)*
		fact(n-l-1)/(2.0*real n*fact(n+l)));
	return nrm*math->exp(-rho/2.0)*math->pow(rho, real l)*
		laguerre(n-l-1, 2*l+1, rho);
}

# The real spherical harmonic, as a function of a direction given by a
# vector rather than by angles - which is what a caller walking a grid
# has, and saves it computing an arctangent it does not otherwise want.
angular(l, m: int, x, y, zc: real): real
{
	r := math->sqrt(x*x+y*y+zc*zc);
	if(r == 0.0){
		if(l == 0)
			return 0.5/math->sqrt(Math->Pi);
		return 0.0;
	}
	am := m;
	if(am < 0)
		am = -am;
	if(l < 0 || am > l)
		return 0.0;
	u := zc/r;
	nrm := math->sqrt((2.0*real l + 1.0)/(4.0*Math->Pi)*
		fact(l-am)/fact(l+am));
	p := legendre(l, am, u);
	if(m == 0)
		return nrm*p;
	# cos(m phi) and sin(m phi) from the vector, by recurrence on
	# (x + iy)^m, so no atan and no trouble on the axis
	(cx, sy) := (1.0, 0.0);
	rho := math->sqrt(x*x+y*y);
	if(rho > 0.0){
		(c1, s1) := (x/rho, y/rho);
		(cx, sy) = (1.0, 0.0);
		for(i := 0; i < am; i++){
			(cx, sy) = (cx*c1 - sy*s1, cx*s1 + sy*c1);
		}
	}else if(am > 0)
		return 0.0;
	# The Condon-Shortley phase is in legendre() - P_1^1 is MINUS
	# sin(theta) - and it is taken back out here with (-1)^m, which is
	# the usual convention for the real harmonics and the one that puts
	# p_x's positive lobe at positive x.  Which lobe is positive is a
	# convention and not physics, since psi and -psi are the same
	# state; but it is a convention a picture shows, so orbitaltest(1)
	# pins it rather than leaving it to drift.
	k := math->sqrt(2.0)*nrm*p;
	if(am%2 == 1)
		k = -k;
	if(m > 0)
		return k*cx;
	return k*sy;
}

psi(n, l, m: int, z, x, y, zc: real): real
{
	am := m;
	if(am < 0)
		am = -am;
	if(n < 1 || l < 0 || l >= n || am > l)
		return 0.0;
	r := math->sqrt(x*x+y*y+zc*zc);
	return radial(n, l, z, r)*angular(l, m, x, y, zc);
}

extent(n: int, z: real): real
{
	if(z <= 0.0)
		z = 1.0;
	return 2.5*real(n*n)/z + 4.0;
}

peak(n, l, m: int, z, half: real, steps: int): real
{
	if(steps < 2)
		steps = 2;
	d := 2.0*half/real(steps-1);
	best := 0.0;
	for(i := 0; i < steps; i++){
		x := -half + real i*d;
		for(j := 0; j < steps; j++){
			y := -half + real j*d;
			for(k := 0; k < steps; k++){
				zc := -half + real k*d;
				v := psi(n, l, m, z, x, y, zc);
				if(v < 0.0)
					v = -v;
				if(v > best)
					best = v;
			}
		}
	}
	return best;
}
