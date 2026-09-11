# optim - root finding, minimisation, curve fitting and linear programming
#
# The objective is a function reference, not a stored table, which is
# the only shape that works for a thing being searched: the search
# decides where to look next.  Limbo has no closures, so a caller
# needing extra data puts it in a variable of its own module and reads
# it inside the function - the same arrangement krylov(2) uses.
#
# EVERY METHOD HERE IS SAFEGUARDED OR SAYS IT IS NOT.  Newton's method
# is the one everybody writes and it fails on ordinary functions - a
# flat spot throws it to the far side of the world and it never comes
# back.  root() brackets first and never leaves the bracket, so it
# always converges or says the bracket was wrong; newton() is here too,
# because it is what a course teaches, and its man page says what it
# does when it fails.

Optim: module
{
	PATH: con "/dis/lib/optim.dis";

	init:	fn();

	# a function of one variable, and of several
	Fn1:	type ref fn(x: real): real;
	Fnn:	type ref fn(x: array of real): real;
	# a model: its parameters, and where to evaluate it
	Model:	type ref fn(p: array of real, x: real): real;

	# Where a function crosses zero, between a and b.  Brent's method:
	# bisection so that it cannot fail, with interpolation so that it
	# is not slow.  a and b must straddle a root, which is checked.
	root:	fn(f: Fn1, a, b, tol: real): (real, string);
	# The unsafeguarded one, for comparison and because it is what is
	# taught.  Returns an error if it leaves the world or runs out of
	# iterations.
	newton:	fn(f, df: Fn1, x0, tol: real, maxit: int): (real, string);
	# Widen an interval until it straddles a root, so that root() can
	# be given something to work with.
	bracket: fn(f: Fn1, a, b: real): (real, real, string);

	# The least value of a function of one variable between a and b,
	# by Brent's method: golden section with parabolic interpolation
	# where that helps.  The interval must contain the minimum; nothing
	# can tell whether it does, and if it does not the answer is an end.
	minimise1: fn(f: Fn1, a, b, tol: real): (real, real, string);

	# The least value of a function of several, by Nelder and Mead's
	# simplex - which needs no derivative at all, and is what to reach
	# for when the function is measured rather than written down.
	Result: adt {
		x:	array of real;
		value:	real;
		iterations: int;
		converged: int;
	};
	minimise: fn(f: Fnn, start, step: array of real, tol: real,
			maxit: int): (ref Result, string);

	# Fit a model's parameters to data by least squares, by
	# Levenberg-Marquardt: Gauss-Newton where that works and gradient
	# descent where it does not, sliding between them as it goes.  The
	# derivatives are taken numerically, so a caller supplies only the
	# model.  This is the nonlinear counterpart of stats(2)'s linefit.
	fit:	fn(m: Model, xs, ys, start: array of real, tol: real,
			maxit: int): (ref Result, string);

	# Maximise c.x subject to a x <= b and x >= 0, by the simplex
	# method.  Returns the values of x and the value of c.x.
	#
	# Only <= constraints with a non-negative right-hand side, which is
	# the form every textbook problem is in and needs no second phase.
	# A problem not in that form is refused rather than silently
	# mangled.
	linprog: fn(c: array of real, a: array of array of real,
			b: array of real): (ref Result, string);
};
