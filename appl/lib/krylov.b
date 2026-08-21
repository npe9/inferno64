implement Krylov;

include "sys.m";
	sys: Sys;
include "math.m";
	math: Math;
include "string.m";
	str: String;
include "krylov.m";

init()
{
	if(sys == nil){
		sys = load Sys Sys->PATH;
		math = load Math Math->PATH;
		str = load String String->PATH;
	}
}

new(): ref Solver
{
	init();
	return ref Solver("gmres", 1.0e-8, 200, 30, 0, 0.0, 0);
}

words(s: string): array of string
{
	l := str->fields(s);
	a := array[len l] of string;
	for(i := 0; l != nil; (i,l) = (i+1,tl l))
		a[i] = hd l;
	return a;
}

Solver.cmd(s: self ref Solver, command: string): string
{
	(nil, after) := str->splitl(command, "\n");
	if(after != nil){
		for(rest := command; rest != nil;){
			(line, tail) := str->splitl(rest, "\n");
			if(tail != nil)
				tail = tail[1:];
			if(str->fields(line) != nil){
				err := s.cmd(line);
				if(err != nil)
					return err;
			}
			rest = tail;
		}
		return nil;
	}
	a := words(command);
	if(len a == 0)
		return nil;
	case a[0] {
	"method" =>
		if(len a != 2 || (a[1] != "gmres" && a[1] != "cg"))
			return "usage: method gmres|cg";
		s.method = a[1];
		return nil;
	"tolerance" =>
		if(len a != 2)
			return "usage: tolerance t";
		s.tolerance = real a[1];
		return nil;
	"maxiter" =>
		if(len a != 2)
			return "usage: maxiter n";
		s.maxiter = int a[1];
		return nil;
	"restart" =>
		if(len a != 2)
			return "usage: restart k";
		s.restart = int a[1];
		return nil;
	}
	return "unknown krylov command: " + a[0];
}

# --- vector helpers; none mutate their array arguments ---

dot(x, y: array of real): real
{
	sum := 0.0;
	for(i := 0; i < len x; i++)
		sum += x[i]*y[i];
	return sum;
}

norm(x: array of real): real
{
	return math->sqrt(dot(x,x));
}

zeros(n: int): array of real
{
	return array[n] of {* => 0.0};
}

copyvec(x: array of real): array of real
{
	y := array[len x] of real;
	y[0:] = x;
	return y;
}

scale(a: real, x: array of real): array of real
{
	y := array[len x] of real;
	for(i := 0; i < len x; i++)
		y[i] = a*x[i];
	return y;
}

sub(x, y: array of real): array of real
{
	z := array[len x] of real;
	for(i := 0; i < len x; i++)
		z[i] = x[i]-y[i];
	return z;
}

# a*x + y, a new array.
axpy(a: real, x, y: array of real): array of real
{
	z := array[len x] of real;
	for(i := 0; i < len x; i++)
		z[i] = a*x[i]+y[i];
	return z;
}

givens(a, b: real): (real, real)
{
	if(b == 0.0)
		return (1.0, 0.0);
	if(absreal(b) > absreal(a)){
		tau := a/b;
		sn := 1.0/math->sqrt(1.0+tau*tau);
		return (sn*tau, sn);
	}
	tau := b/a;
	cs := 1.0/math->sqrt(1.0+tau*tau);
	return (cs, cs*tau);
}

absreal(x: real): real
{
	if(x < 0.0)
		return -x;
	return x;
}

Solver.solve(s: self ref Solver, apply: Apply, b: array of real,
		x0: array of real): array of real
{
	if(s.method == "cg")
		return cgsolve(s, apply, b, x0);
	return gmressolve(s, apply, b, x0);
}

startingpoint(b, x0: array of real): array of real
{
	if(x0 == nil)
		return zeros(len b);
	return copyvec(x0);
}

tolerance(s: ref Solver): real
{
	if(s.tolerance <= 0.0)
		return 1.0e-8;
	return s.tolerance;
}

maxiterations(s: ref Solver): int
{
	if(s.maxiter < 1)
		return 200;
	return s.maxiter;
}

# GMRES(m) with restart: standard modified Gram-Schmidt Arnoldi process,
# a Givens-rotation QR of the Hessenberg matrix maintained incrementally
# (one rotation per new column, the textbook way to avoid re-solving a
# growing least-squares problem from scratch every step), and a triangular
# back-substitution for the coefficients once the residual estimate meets
# tolerance or the restart length is reached.
gmressolve(s: ref Solver, apply: Apply, b: array of real,
		x0: array of real): array of real
{
	n := len b;
	x := startingpoint(b, x0);
	normb := norm(b);
	if(normb == 0.0)
		normb = 1.0;
	m := s.restart;
	if(m < 1)
		m = 1;
	if(m > n)
		m = n;
	tol := tolerance(s);
	maxiter := maxiterations(s);
	total := 0;
	for(;;){
		r := sub(b, apply(x));
		beta := norm(r);
		resid := beta/normb;
		if(resid <= tol || total >= maxiter){
			s.iterations = total;
			s.residual = resid;
			s.converged = resid <= tol;
			return x;
		}
		v := array[m+1] of array of real;
		h := array[m+1] of array of real;
		for(row := 0; row <= m; row++)
			h[row] = zeros(m);
		cs := zeros(m);
		sn := zeros(m);
		g := zeros(m+1);
		v[0] = scale(1.0/beta, r);
		g[0] = beta;
		used := 0;
		for(j := 0; j < m && total < maxiter; j++){
			total++;
			w := apply(v[j]);
			for(i := 0; i <= j; i++){
				h[i][j] = dot(w, v[i]);
				w = axpy(-h[i][j], v[i], w);
			}
			hnext := norm(w);
			h[j+1][j] = hnext;
			if(hnext > 1.0e-14)
				v[j+1] = scale(1.0/hnext, w);
			else
				v[j+1] = zeros(n);
			for(i = 0; i < j; i++){
				temp := cs[i]*h[i][j] + sn[i]*h[i+1][j];
				h[i+1][j] = -sn[i]*h[i][j] + cs[i]*h[i+1][j];
				h[i][j] = temp;
			}
			(c, sk) := givens(h[j][j], h[j+1][j]);
			cs[j] = c;
			sn[j] = sk;
			h[j][j] = c*h[j][j] + sk*h[j+1][j];
			h[j+1][j] = 0.0;
			g[j+1] = -sk*g[j];
			g[j] = c*g[j];
			used = j+1;
			resid = absreal(g[j+1])/normb;
			if(resid <= tol)
				break;
		}
		y := zeros(used);
		for(bi := used-1; bi >= 0; bi--){
			sum := g[bi];
			for(bk := bi+1; bk < used; bk++)
				sum -= h[bi][bk]*y[bk];
			if(h[bi][bi] != 0.0)
				y[bi] = sum/h[bi][bi];
		}
		for(bi = 0; bi < used; bi++)
			x = axpy(y[bi], v[bi], x);
	}
}

# Conjugate Gradient: only mathematically valid for a symmetric positive
# definite operator, but half the work per iteration of GMRES and needs
# no restart/basis storage - the right choice whenever the caller knows
# their operator actually is SPD (a self-adjoint diffusion/Poisson
# operator with symmetric boundary conditions is; most anything else
# isn't, and CG can fail silently or diverge if handed one that isn't -
# a real, sharp-edged distinction, not a formality).
cgsolve(s: ref Solver, apply: Apply, b: array of real,
		x0: array of real): array of real
{
	x := startingpoint(b, x0);
	normb := norm(b);
	if(normb == 0.0)
		normb = 1.0;
	tol := tolerance(s);
	maxiter := maxiterations(s);
	r := sub(b, apply(x));
	resid := norm(r)/normb;
	if(resid <= tol){
		s.iterations = 0;
		s.residual = resid;
		s.converged = 1;
		return x;
	}
	p := copyvec(r);
	rsold := dot(r,r);
	iter := 0;
	for(; iter < maxiter; iter++){
		ap := apply(p);
		denom := dot(p,ap);
		if(denom == 0.0)
			break;
		alpha := rsold/denom;
		x = axpy(alpha, p, x);
		r = axpy(-alpha, ap, r);
		rsnew := dot(r,r);
		resid = math->sqrt(rsnew)/normb;
		if(resid <= tol){
			iter++;
			break;
		}
		p = axpy(rsnew/rsold, p, r);
		rsold = rsnew;
	}
	s.iterations = iter;
	s.residual = resid;
	s.converged = resid <= tol;
	return x;
}
