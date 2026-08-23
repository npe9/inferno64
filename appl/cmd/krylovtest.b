implement Command;

#
# Tests krylov(2)'s two solvers against systems whose answers are known in
# advance, including the number of iterations they must take.
#
# The iteration count is the point. Both solvers build a basis and rely on it
# staying orthogonal, and the vector updates that maintain it happen in place
# through math(2)'s axpby - so a mistake there damages a basis vector rather
# than crashing. That does not show up as a wrong answer: GMRES with a damaged
# basis usually still converges, just slower. A residual check alone would
# pass. The iteration count is what moves.
#
# What this does NOT catch, established by trying it: an Apply that returns a
# reused buffer instead of a fresh array. Every count and residual here is
# unchanged by that, because the basis vector GMRES keeps is a copy rather than
# the array Apply handed back. The solver does modify that array, so reusing
# one is still a bad idea - but it is a documented caution in krylov(2), not
# something this test can detect.
#
# Textbook fact both cases use: a Krylov method converges in at most as many
# iterations as the matrix has distinct eigenvalues, and for these matrices it
# takes exactly that many.
#
include "sys.m";
	sys: Sys;
	print, sprint: import sys;
include "math.m";
	math: Math;
include "krylov.m";
	krylov: Krylov;
	Solver: import krylov;
include "draw.m";

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

fail := 0;

bad(s: string)
{
	print("FAIL: %s\n", s);
	fail = 1;
}

# Dense matvec, so this tests krylov(2) and not sparse(2).
#
# Krylov->Apply is a bare function reference and Limbo has no closures, so the
# matrix has to be reachable from a plain function - the same arrangement
# pde(2) uses and for the same reason.
curm: array of array of real;

applym(x: array of real): array of real
{
	n := len curm;
	y := array[n] of real;
	for(i := 0; i < n; i++){
		s := 0.0;
		for(j := 0; j < n; j++)
			s += curm[i][j]*x[j];
		y[i] = s;
	}
	# A fresh array each call, as krylov(2) requires of any Apply.
	return y;
}

mk(a: array of array of real): Krylov->Apply
{
	curm = a;
	return applym;
}

resid(a: array of array of real, x, b: array of real): real
{
	n := len a;
	nb := 0.0;
	nr := 0.0;
	for(i := 0; i < n; i++){
		s := 0.0;
		for(j := 0; j < n; j++)
			s += a[i][j]*x[j];
		d := s - b[i];
		nr += d*d;
		nb += b[i]*b[i];
	}
	if(nb == 0.0)
		nb = 1.0;
	return math->sqrt(nr/nb);
}

zero(n: int): array of array of real
{
	a := array[n] of array of real;
	for(i := 0; i < n; i++)
		a[i] = array[n] of {* => 0.0};
	return a;
}

# Diagonal with k distinct values, so a Krylov method needs exactly k
# iterations - the sharpest statement available about a solver's basis.
distinct(n, k: int): array of array of real
{
	a := zero(n);
	for(i := 0; i < n; i++)
		a[i][i] = real (1 + i % k);
	return a;
}

check(name: string, method: string, a: array of array of real,
	b: array of real, wantiter: int)
{
	s := krylov->new();
	e := s.cmd("method " + method + "\ntolerance 1e-12\nmaxiter 200\nrestart 60");
	if(e != nil){
		bad(sprint("%s: cmd: %s", name, e));
		return;
	}
	x := s.solve(mk(a), b, nil);
	if(x == nil){
		bad(sprint("%s: no solution", name));
		return;
	}
	r := resid(a, x, b);
	if(!s.converged)
		bad(sprint("%s: did not converge, residual %g after %d iterations",
			name, r, s.iterations));
	else if(r > 1e-9)
		bad(sprint("%s: converged but true residual is %g", name, r));
	if(wantiter > 0 && s.iterations != wantiter)
		bad(sprint("%s: took %d iterations, expected exactly %d - the basis is not orthogonal",
			name, s.iterations, wantiter));
	if(!fail)
		print("  %-28s %2d iterations, residual %8.2e\n", name, s.iterations, r);
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	krylov = load Krylov Krylov->PATH;
	if(krylov == nil || math == nil){
		print("krylovtest: load: %r\n");
		raise "fail:load";
	}

	n := 40;
	b := array[n] of real;
	for(i := 0; i < n; i++)
		b[i] = 1.0 + real (i % 7);

	# Symmetric positive definite, five distinct eigenvalues.
	spd := distinct(n, 5);
	check("cg, 5 distinct eigenvalues", "cg", spd, b, 5);
	check("gmres, 5 distinct", "gmres", spd, b, 5);
	check("gmres, 9 distinct", "gmres", distinct(n, 9), b, 9);

	# Non-symmetric: CG has no business converging here and GMRES must.
	# Without this the whole test could pass on symmetric problems alone,
	# and the Arnoldi recurrence - the part that actually uses a stored
	# basis, and the part changed when the updates became in place - would
	# never be exercised on anything CG could not have done.
	ns := distinct(n, 6);
	for(i = 0; i < n-1; i++)
		ns[i][i+1] = 0.5;
	check("gmres, non-symmetric", "gmres", ns, b, 0);

	# A restart shorter than the iterations needed, so the basis is rebuilt
	# rather than grown once: the outer loop of GMRES(m), which the inner
	# one hides.
	s := krylov->new();
	s.cmd("method gmres\ntolerance 1e-12\nmaxiter 400\nrestart 4");
	x := s.solve(mk(distinct(n, 9)), b, nil);
	if(x == nil || !s.converged)
		bad("gmres with restart 4 did not converge");
	else {
		r := resid(distinct(n, 9), x, b);
		if(r > 1e-9)
			bad(sprint("gmres restart 4: true residual %g", r));
		else
			print("  %-28s %2d iterations, residual %8.2e\n",
				"gmres, restart 4", s.iterations, r);
	}

	if(fail)
		raise "fail:test";
	print("PASS\n");
}
