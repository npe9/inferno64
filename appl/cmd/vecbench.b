implement Vecbench;

#
# Times the vector operations a Krylov solve spends its time in, comparing
# what Limbo generates against math(2)'s C builtins.
#
# This exists because the obvious explanation for those operations costing 40%
# of a GPU-backed solve was wrong. Every one of them allocated a fresh array,
# so the cost looked like Limbo heap traffic - and it is not: an in-place axpy
# costs the same as an allocating one, and a bare array[n] is under a
# microsecond. The cost is the generated code, which is why a C builtin helps
# and removing allocations does not.
#
# The JIT is on by default and matters enormously here; run with -c0 to see
# the interpreter instead. Comparing the two is the point of keeping this.
#
include "sys.m";
	sys: Sys;
	print: import sys;
include "math.m";
	math: Math;
include "draw.m";
Vecbench: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

dot(x, y: array of real): real
{
	sum := 0.0;
	for(i := 0; i < len x; i++)
		sum += x[i]*y[i];
	return sum;
}

axpy(a: real, x, y: array of real): array of real
{
	z := array[len x] of real;
	for(i := 0; i < len x; i++)
		z[i] = a*x[i]+y[i];
	return z;
}

axpyinto(a: real, x, y, z: array of real)
{
	for(i := 0; i < len x; i++)
		z[i] = a*x[i]+y[i];
}

alloconly(n: int): int
{
	z := array[n] of real;
	return len z;
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	n := 13824;
	reps := 2000;
	argv = tl argv;
	if(argv != nil){
		n = int hd argv;
		argv = tl argv;
	}
	x := array[n] of real;
	y := array[n] of real;
	z := array[n] of real;
	for(i := 0; i < n; i++){ x[i] = real i; y[i] = 1.0; }

	t0 := sys->millisec();
	s := 0.0;
	for(i = 0; i < reps; i++)
		s += dot(x, y);
	tdot := sys->millisec()-t0;

	t0 = sys->millisec();
	s2 := 0.0;
	for(i = 0; i < reps; i++)
		s2 += math->dot(x, y);
	tcdot := sys->millisec()-t0;

	t0 = sys->millisec();
	for(i = 0; i < reps; i++)
		s2 += math->norm2(x);
	tcnorm := sys->millisec()-t0;

	t0 = sys->millisec();
	for(i = 0; i < reps; i++)
		y = axpy(1.0, x, y);
	talloc := sys->millisec()-t0;

	t0 = sys->millisec();
	for(i = 0; i < reps; i++)
		axpyinto(1.0, x, y, z);
	tinto := sys->millisec()-t0;

	t0 = sys->millisec();
	for(i = 0; i < reps; i++)
		math->axpby(1.0, x, 1.0, z);
	tcaxpy := sys->millisec()-t0;

	t0 = sys->millisec();
	k := 0;
	for(i = 0; i < reps; i++)
		k += alloconly(n);
	tjustalloc := sys->millisec()-t0;

	print("n=%d reps=%d  (us per call)\n", n, reps);
	print("  dot   (Limbo)  %7.1f\n", real tdot*1000.0/real reps);
	print("  dot   (math2)  %7.1f   %.1fx\n", real tcdot*1000.0/real reps,
		real tdot/real tcdot);
	print("  norm2 (math2)  %7.1f\n", real tcnorm*1000.0/real reps);
	print("  axpy (alloc)   %7.1f\n", real talloc*1000.0/real reps);
	print("  axpy (in place)%7.1f\n", real tinto*1000.0/real reps);
	print("  axpby (math2)  %7.1f   %.1fx\n", real tcaxpy*1000.0/real reps,
		real tinto/real tcaxpy);
	print("  bare array[n]  %7.1f\n", real tjustalloc*1000.0/real reps);
	print("  alloc share of axpy: %.0f%%\n",
		100.0*(real talloc - real tinto)/real talloc);
	print("  (checksum %g %g %d)\n", s, s2, k);
}
