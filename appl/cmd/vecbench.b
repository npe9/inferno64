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
include "sparse.m";
	sparse: Sparse;
	CSR: import sparse;
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

# What sparse(2)'s matvec was before it called math->spmv, kept here so the
# comparison is against the Limbo loop and not against spmv itself.
limbomatvec(m: ref CSR, x: array of real): array of real
{
	y := array[m.n] of real;
	for(row := 0; row < m.n; row++){
		s := 0.0;
		for(jj := m.rowptr[row]; jj < m.rowptr[row+1]; jj++)
			s += m.val[jj]*x[m.colidx[jj]];
		y[row] = s;
	}
	return y;
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	sparse = load Sparse Sparse->PATH;
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

	# The matvec, which is where a Krylov solve actually spends its time:
	# a 7-point stencil in CSR, the shape fem(2) assembles.
	nz := 7;
	rowptr := array[n+1] of int;
	colidx := array[n*nz] of int;
	val := array[n*nz] of real;
	for(r := 0; r < n; r++){
		rowptr[r] = r*nz;
		for(c := 0; c < nz; c++){
			colidx[r*nz+c] = (r + c*911) % n;
			# Deliberately not exactly representable. With 1.0 and
			# 6.0 here the C and Limbo loops agreed bit for bit and
			# the comparison below proved nothing: the C compiler
			# contracts the multiply-add into an FMA, which only
			# rounds differently when the values actually need
			# rounding.
			val[r*nz+c] = 1.0/real (c+3);
		}
		val[r*nz] = 6.0/7.0;
	}
	rowptr[n] = n*nz;
	m := ref CSR(n, rowptr, colidx, val);
	mreps := reps/10;
	t0 = sys->millisec();
	for(i = 0; i < mreps; i++)
		limbomatvec(m, x);
	tmv := sys->millisec()-t0;

	yy := array[n] of real;
	t0 = sys->millisec();
	for(i = 0; i < mreps; i++)
		math->spmv(m.rowptr, m.colidx, m.val, x, yy);
	tcmv := sys->millisec()-t0;

	# Same answer, not just faster.
	ref2 := limbomatvec(m, x);
	worst := 0.0;
	for(i = 0; i < n; i++){
		d := yy[i] - ref2[i];
		if(d < 0.0)
			d = -d;
		if(ref2[i] != 0.0)
			d /= math->fabs(ref2[i]);
		if(d > worst)
			worst = d;
	}

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
	print("  matvec (Limbo) %7.1f   (%d nonzeros)\n",
		real tmv*1000.0/real mreps, n*nz);
	print("  spmv   (math2) %7.1f   %.1fx, worst relative difference %g\n",
		real tcmv*1000.0/real mreps, real tmv/real tcmv, worst);
	print("  bare array[n]  %7.1f\n", real tjustalloc*1000.0/real reps);
	print("  alloc share of axpy: %.0f%%\n",
		100.0*(real talloc - real tinto)/real talloc);
	print("  (checksum %g %g %d)\n", s, s2, k);
}
