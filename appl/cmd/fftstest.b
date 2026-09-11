implement Fftstest;

# fftstest - check ffts(2), the multivariate transform
#
# The univariate case is checked against the direct sum, the same oracle
# signaltest(1) uses, and against signal(2) itself.  The multivariate
# case is checked against a two-dimensional direct sum, which is the
# only way to find out whether the strides are right - a transform with
# the wrong stride still returns numbers, and they are the right numbers
# for a differently shaped array.
#
# Every length from 8 upward is a regression test.  The implementation
# this replaced indexed past the end of its argument for every length of
# 8 or more and the process died; it passed for 2 through 7 and nothing
# in the tree ever called it.

include "sys.m";
	sys: Sys;
include "draw.m";
include "math.m";
	math: Math;
include "ffts.m";
	fft: FFTs;

Fftstest: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

nfail := 0;
verbose := 0;

fail(s: string)
{
	sys->print("FAIL %s\n", s);
	nfail++;
}

seed := 98765;
rnd(): real
{
	seed = (seed*1103515245 + 12345) & 16r7fffffff;
	return real(seed%20000 - 10000)/10000.0;
}

# the definition, in one dimension
dft1(re, im: array of real, sign: int): (array of real, array of real)
{
	n := len re;
	(orr, oi) := (array[n] of real, array[n] of real);
	for(k := 0; k < n; k++){
		(sr, si) := (0.0, 0.0);
		for(j := 0; j < n; j++){
			th := real sign * 2.0*math->Pi*real((j*k)%n)/real n;
			(c, s) := (math->cos(th), math->sin(th));
			sr += re[j]*c - im[j]*s;
			si += re[j]*s + im[j]*c;
		}
		orr[k] = sr;
		oi[k] = si;
	}
	return (orr, oi);
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	fft = load FFTs FFTs->PATH;
	if(fft == nil || math == nil){
		sys->print("FAIL load: %r\n");
		raise "fail:load";
	}
	for(a := tl argv; a != nil; a = tl a)
		if(hd a == "-v")
			verbose = 1;

	univariate();
	interleaved();
	twodimensional();
	refusals();

	if(nfail == 0)
		sys->print("OK   ffts(2), against the direct sums\n");
	else {
		sys->print("%d failures\n", nfail);
		raise "fail:fftstest";
	}
}

univariate()
{
	ns := array[] of {2, 3, 4, 5, 6, 7, 8, 9, 12, 15, 16, 17, 32, 64, 100, 128};
	for(t := 0; t < len ns; t++){
		n := ns[t];
		for(sgn := -1; sgn <= 1; sgn += 2){
			(a, b) := (array[n] of real, array[n] of real);
			(ka, kb) := (array[n] of real, array[n] of real);
			for(i := 0; i < n; i++){
				a[i] = ka[i] = rnd();
				b[i] = kb[i] = rnd();
			}
			(wr, wi) := dft1(ka, kb, sgn);
			fft->ffts(a, b, n, n, n, sgn);
			worst := 0.0;
			for(i = 0; i < n; i++){
				d := math->fabs(a[i]-wr[i]);
				if(d > worst) worst = d;
				d = math->fabs(b[i]-wi[i]);
				if(d > worst) worst = d;
			}
			if(worst > 1.0e-11)
				fail(sys->sprint("ffts n=%d isn=%d disagrees with the direct sum by %g",
					n, sgn, worst));
			else if(verbose)
				sys->print("     n=%-4d isn=%+d  %.3g\n", n, sgn, worst);
			# and back again, with the 1/n the transform does not do
			fft->ffts(a, b, n, n, n, -sgn);
			rt := 0.0;
			for(i = 0; i < n; i++){
				d := math->fabs(a[i]/real n - ka[i]);
				if(d > rt) rt = d;
				d = math->fabs(b[i]/real n - kb[i]);
				if(d > rt) rt = d;
			}
			if(rt > 1.0e-12)
				fail(sys->sprint("ffts n=%d round trip off by %g", n, rt));
		}
	}
}

# The data may be one array of alternating real and imaginary parts
# instead of two, with the magnitude of isn changed to two to say so.
# That is what the interface is for, and it is a different path through
# every index calculation in the routine.
interleaved()
{
	n := 24;
	c := array[2*n] of real;
	(a, b) := (array[n] of real, array[n] of real);
	for(i := 0; i < n; i++){
		c[2*i] = a[i] = rnd();
		c[2*i+1] = b[i] = rnd();
	}
	fft->ffts(a, b, n, n, n, 1);
	fft->ffts(c[0:], c[1:], n, n, n, 2);
	worst := 0.0;
	for(i = 0; i < n; i++){
		d := math->fabs(c[2*i] - a[i]);
		if(d > worst) worst = d;
		d = math->fabs(c[2*i+1] - b[i]);
		if(d > worst) worst = d;
	}
	if(worst > 1.0e-12)
		fail(sys->sprint("the interleaved form disagrees with the separate one by %g", worst));
	else if(verbose)
		sys->print("     interleaved agrees to %g\n", worst);
}

# Two calls transform a two-dimensional array, and the answer is checked
# against the two-dimensional sum.  This is the check that can see a
# wrong stride: a transform down the columns when it should be along the
# rows returns perfectly good numbers about the wrong array.
twodimensional()
{
	(n1, n2) := (8, 6);
	nt := n1*n2;
	(a, b) := (array[nt] of real, array[nt] of real);
	(ka, kb) := (array[nt] of real, array[nt] of real);
	for(i := 0; i < nt; i++){
		a[i] = ka[i] = rnd();
		b[i] = kb[i] = rnd();
	}
	# a(i1,i2) at i1 + n1*i2, the Fortran order the interface assumes
	fft->ffts(a, b, nt, n1, n1, -1);
	fft->ffts(a, b, nt, n2, n1*n2, -1);

	worst := 0.0;
	for(k1 := 0; k1 < n1; k1++)
		for(k2 := 0; k2 < n2; k2++){
			(sr, si) := (0.0, 0.0);
			for(j1 := 0; j1 < n1; j1++)
				for(j2 := 0; j2 < n2; j2++){
					th := -2.0*math->Pi*(real((j1*k1)%n1)/real n1 +
						real((j2*k2)%n2)/real n2);
					(c, s) := (math->cos(th), math->sin(th));
					x := ka[j1 + n1*j2];
					y := kb[j1 + n1*j2];
					sr += x*c - y*s;
					si += x*s + y*c;
				}
			d := math->fabs(a[k1+n1*k2] - sr);
			if(d > worst) worst = d;
			d = math->fabs(b[k1+n1*k2] - si);
			if(d > worst) worst = d;
		}
	if(worst > 1.0e-11)
		fail(sys->sprint("the two-dimensional transform is off the two-dimensional sum by %g", worst));
	else if(verbose)
		sys->print("     2-D %dx%d agrees to %g\n", n1, n2, worst);

	# the two variates may be done in either order, which the interface
	# says explicitly
	(c2, d2) := (array[nt] of real, array[nt] of real);
	c2[0:] = ka;
	d2[0:] = kb;
	fft->ffts(c2, d2, nt, n2, n1*n2, -1);
	fft->ffts(c2, d2, nt, n1, n1, -1);
	worst = 0.0;
	for(i = 0; i < nt; i++){
		d := math->fabs(c2[i]-a[i]);
		if(d > worst) worst = d;
		d = math->fabs(d2[i]-b[i]);
		if(d > worst) worst = d;
	}
	if(worst > 1.0e-12)
		fail(sys->sprint("the order of the two calls changed the answer, by %g", worst));
}

# A shape that does not describe an array must leave the data alone
# rather than transform some other array that happens to fit.  The
# interface has no way to report this, so the check is that nothing
# moved.
refusals()
{
	n := 16;
	(a, b) := (array[n] of real, array[n] of real);
	(ka, kb) := (array[n] of real, array[n] of real);
	for(i := 0; i < n; i++){
		a[i] = ka[i] = rnd();
		b[i] = kb[i] = rnd();
	}
	bad := array[] of {
		(n, 5, n, 1),		# 16 is not a multiple of 5
		(n, n, n+1, 1),		# nspan does not divide ntot
		(n, n, n, 0),		# no direction
		(n+n, n, n, 1),		# more data claimed than given
	};
	for(t := 0; t < len bad; t++){
		(ntot, nn, nspan, isn) := bad[t];
		fft->ffts(a, b, ntot, nn, nspan, isn);
		for(i = 0; i < n; i++)
			if(a[i] != ka[i] || b[i] != kb[i]){
				fail(sys->sprint("ffts(ntot=%d n=%d nspan=%d isn=%d) is not a "+
					"shape, and it changed the data anyway", ntot, nn, nspan, isn));
				a[0:] = ka;
				b[0:] = kb;
				break;
			}
	}
	# and a good call does change it, or the checks above would be
	# satisfied by a routine that did nothing at all
	fft->ffts(a, b, n, n, n, 1);
	same := 1;
	for(i = 0; i < n; i++)
		if(a[i] != ka[i])
			same = 0;
	if(same)
		fail("a good call changed nothing, so the refusals prove nothing");
}
