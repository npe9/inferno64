implement Signaltest;

# signaltest - check signal(2) against the definitions
#
# The transform is checked against the O(n^2) sum it is an accelerated
# form of, at lengths that are powers of two and lengths that are not,
# which is an oracle and not a property: if the two disagree the fast
# one is wrong, and no argument about which is more likely applies.
#
# Everything else is checked against a closed form too - Parseval, the
# shift theorem, the convolution theorem, the exact height a sinusoid
# must reach in a periodogram, the exact magnitude of a Butterworth
# response - and the last of these is checked against circuit(2), since
# an RC circuit and a one-pole filter are the same object arrived at
# from two directions.

include "sys.m";
	sys: Sys;
include "draw.m";
include "math.m";
	math: Math;
include "signal.m";
	sig: Signal;
	Biquad: import sig;
include "circuit.m";
	ckt: Circuit;

Signaltest: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

nfail := 0;
verbose := 0;

fail(s: string)
{
	sys->print("FAIL %s\n", s);
	nfail++;
}

near(what: string, got, want, tol: real)
{
	d := got-want;
	if(d < 0.0)
		d = -d;
	if(math->isnan(got) || d > tol)
		fail(sys->sprint("%s: got %.10g want %.10g", what, got, want));
	else if(verbose)
		sys->print("     %s: %.8g\n", what, got);
}

# The amplitude of a sinusoid of frequency f in y[from:from+count],
# by projecting onto that frequency.  Taking the largest sample instead
# measures low by however much the sampling misses the crest - at
# f = 0.45 the samples are 2.2 apart in a period and the peak is missed
# by 3% - which is a property of the measurement and not of the filter.
# f must be a whole number of cycles in count samples for this to be
# exact, and every f used here is.
ampat(y: array of real, from, count: int, f: real): real
{
	(re, im) := (0.0, 0.0);
	for(i := 0; i < count; i++){
		a := -2.0*math->Pi*f*real i;
		re += y[from+i]*math->cos(a);
		im += y[from+i]*math->sin(a);
	}
	return 2.0*math->sqrt(re*re+im*im)/real count;
}

# the definition, as an oracle for the fast one
dft(re, im: array of real, sign: int): (array of real, array of real)
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

seed := 12345;
rnd(): real
{
	seed = (seed*1103515245 + 12345) & 16r7fffffff;
	return real(seed%20000 - 10000)/10000.0;
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	sig = load Signal Signal->PATH;
	ckt = load Circuit Circuit->PATH;
	if(sig == nil || ckt == nil || math == nil){
		sys->print("FAIL load: %r\n");
		raise "fail:load";
	}
	sig->init();
	ckt->init();
	for(a := tl argv; a != nil; a = tl a)
		if(hd a == "-v")
			verbose = 1;

	transform();
	windows();
	convolution();
	firs();
	iirs();
	rcandfilter();
	refusals();

	if(nfail == 0)
		sys->print("OK   signal(2) against the definitions\n");
	else {
		sys->print("%d failures\n", nfail);
		raise "fail:signaltest";
	}
}

transform()
{
	# against the direct sum, at powers of two and at lengths that are
	# not: the second kind go through Bluestein, which is a different
	# piece of code entirely and would otherwise never be reached
	ns := array[] of {2, 3, 4, 5, 6, 7, 8, 12, 15, 16, 17, 31, 32, 64, 100, 105, 128};
	for(t := 0; t < len ns; t++){
		n := ns[t];
		(re, im) := (array[n] of real, array[n] of real);
		(kr, ki) := (array[n] of real, array[n] of real);
		for(i := 0; i < n; i++){
			re[i] = kr[i] = rnd();
			im[i] = ki[i] = rnd();
		}
		(wr, wi) := dft(kr, ki, -1);
		sig->fft(re, im);
		worst := 0.0;
		for(i = 0; i < n; i++){
			d := math->fabs(re[i]-wr[i]);
			if(d > worst) worst = d;
			d = math->fabs(im[i]-wi[i]);
			if(d > worst) worst = d;
		}
		if(worst > 1.0e-11)
			fail(sys->sprint("fft n=%d disagrees with the direct sum by %g", n, worst));
		# and back again
		sig->ifft(re, im);
		rt := 0.0;
		for(i = 0; i < n; i++){
			d := math->fabs(re[i]-kr[i]);
			if(d > rt) rt = d;
			d = math->fabs(im[i]-ki[i]);
			if(d > rt) rt = d;
		}
		if(rt > 1.0e-12)
			fail(sys->sprint("fft n=%d then ifft is off by %g", n, rt));
		if(verbose)
			sys->print("     n=%-4d vs direct sum %.3g, round trip %.3g\n", n, worst, rt);
	}

	# Parseval: the energy is the same counted either way
	n := 64;
	(x, z) := (array[n] of real, array[n] of real);
	e1 := 0.0;
	for(i := 0; i < n; i++){
		x[i] = rnd();
		z[i] = 0.0;
		e1 += x[i]*x[i];
	}
	sig->fft(x, z);
	e2 := 0.0;
	for(i = 0; i < n; i++)
		e2 += x[i]*x[i] + z[i]*z[i];
	near("Parseval", e2/real n, e1, 1.0e-12);

	# a sinusoid exactly on a bin is one bin and nothing else
	n = 64;
	k := 7;
	amp := 3.0;
	xs := array[n] of real;
	for(i = 0; i < n; i++)
		xs[i] = amp*math->cos(2.0*math->Pi*real(k*i)/real n);
	(re, im) := sig->rfft(xs);
	m := sig->magnitude(re, im);
	near("a tone on a bin, its own bin", m[k], amp*real n/2.0, 1.0e-10);
	near("a tone on a bin, its mirror", m[n-k], amp*real n/2.0, 1.0e-10);
	leak := 0.0;
	for(i = 0; i < n; i++)
		if(i != k && i != n-k && m[i] > leak)
			leak = m[i];
	if(leak > 1.0e-10)
		fail(sys->sprint("a tone exactly on a bin leaked %g into the others", leak));

	# the shift theorem: a delay of d multiplies bin k by exp(-2i pi k d/n)
	d := 5;
	ys := array[n] of real;
	for(i = 0; i < n; i++)
		ys[i] = xs[(i-d+n)%n];
	(yr, yi) := sig->rfft(ys);
	worst := 0.0;
	for(i = 0; i < n; i++){
		a := -2.0*math->Pi*real(i*d)/real n;
		(c, s) := (math->cos(a), math->sin(a));
		(er, ei) := (re[i]*c - im[i]*s, re[i]*s + im[i]*c);
		dd := math->fabs(yr[i]-er) + math->fabs(yi[i]-ei);
		if(dd > worst)
			worst = dd;
	}
	if(worst > 1.0e-10)
		fail(sys->sprint("the shift theorem is off by %g", worst));
	else if(verbose)
		sys->print("     shift theorem to %g\n", worst);

	# bin 33 of 64 is a NEGATIVE frequency, which is the thing everyone
	# gets wrong when they label an axis
	near("bin 0 is DC", sig->binfreq(0, 64), 0.0, 0.0);
	near("bin 16 of 64 is a quarter", sig->binfreq(16, 64), 0.25, 0.0);
	# at bin n/2 the two signs are the same frequency; the library
	# reports +0.5 and says so
	near("bin 32 of 64 is Nyquist", sig->binfreq(32, 64), 0.5, 0.0);
	near("bin 33 of 64 is negative", sig->binfreq(33, 64), -31.0/64.0, 1.0e-15);
	if(sig->realbins(64) != 33)
		fail("a real signal of 64 samples has 33 distinct bins, not " +
			string sig->realbins(64));
	if(sig->realbins(65) != 33)
		fail("an odd length has (n+1)/2 distinct bins");
}

windows()
{
	n := 32;
	# the rectangular window is all ones, and the others are not
	w := sig->window(sig->RECT, n);
	for(i := 0; i < n; i++)
		if(w[i] != 1.0){
			fail("the rectangular window is not all ones");
			break;
		}
	# the periodic form starts at zero for Hann and is symmetric about
	# its middle sample
	h := sig->window(sig->HANN, n);
	near("Hann starts at zero", h[0], 0.0, 1.0e-15);
	worst := 0.0;
	for(i = 1; i < n; i++){
		d := math->fabs(h[i] - h[n-i]);
		if(d > worst)
			worst = d;
	}
	if(worst > 1.0e-15)
		fail(sys->sprint("the Hann window is not symmetric, by %g", worst));

	# A window's whole point is what it does to a tone that is NOT on a
	# bin: the rectangular one smears it across the spectrum and the
	# others do not.  Measured, at half a bin off, as the worst leak
	# ten bins away or further.
	k := 10.5;
	x := array[n] of real;
	for(i = 0; i < n; i++)
		x[i] = math->cos(2.0*math->Pi*k*real i/real n);
	kinds := array[] of {sig->RECT, sig->HAMMING, sig->HANN, sig->BLACKMAN};
	leaks := array[len kinds] of real;
	for(t := 0; t < len kinds; t++){
		p := sig->periodogram(x, kinds[t]);
		worst = 0.0;
		for(i = 0; i < len p; i++){
			d := real i - k;
			if(d < 0.0)
				d = -d;
			if(d >= 4.0 && p[i] > worst)
				worst = p[i];
		}
		leaks[t] = worst;
		if(verbose)
			sys->print("     %-12s leaks %.3g four bins out\n",
				sig->windowname(kinds[t]), worst);
	}
	for(t = 1; t < len kinds; t++)
		if(leaks[t] >= leaks[t-1])
			fail(sys->sprint("%s should leak less than %s, but %g is not below %g",
				sig->windowname(kinds[t]), sig->windowname(kinds[t-1]),
				leaks[t], leaks[t-1]));

	# and the height is right whatever the window: a sinusoid of
	# amplitude A reads A*A/2 in its own bin.  Without the scaling in
	# periodogram() a Hann window would halve it and the reader would
	# conclude the signal got quieter.
	amp := 2.5;
	kb := 9;
	for(i = 0; i < n; i++)
		x[i] = amp*math->cos(2.0*math->Pi*real(kb*i)/real n);
	for(t = 0; t < len kinds; t++){
		p := sig->periodogram(x, kinds[t]);
		near("a tone reads A*A/2 under a " + sig->windowname(kinds[t]) + " window",
			p[kb], amp*amp/2.0, 1.0e-12);
	}
}

convolution()
{
	# a small case worked out by hand
	a := array[] of {1.0, 2.0, 3.0};
	b := array[] of {4.0, 5.0};
	c := sig->convolve(a, b);
	want := array[] of {4.0, 13.0, 22.0, 15.0};
	if(len c != len want)
		fail("convolution length is len x + len h - 1");
	else
		for(q := 0; q < len want; q++)
			near(sys->sprint("convolve by hand [%d]", q), c[q], want[q], 1.0e-15);

	# the convolution theorem: the two routes must agree
	(nx, nh) := (100, 17);
	x := array[nx] of real;
	h := array[nh] of real;
	for(i := 0; i < nx; i++)
		x[i] = rnd();
	for(i = 0; i < nh; i++)
		h[i] = rnd();
	d := sig->convolve(x, h);
	f := sig->fftconvolve(x, h);
	worst := 0.0;
	for(i = 0; i < len d; i++){
		e := math->fabs(d[i]-f[i]);
		if(e > worst)
			worst = e;
	}
	if(worst > 1.0e-12)
		fail(sys->sprint("the two convolutions disagree by %g", worst));
	else if(verbose)
		sys->print("     direct and transform convolution agree to %g\n", worst);

	# autocorrelation peaks at lag zero, at the energy
	r := sig->correlate(x, x);
	e := 0.0;
	for(i = 0; i < nx; i++)
		e += x[i]*x[i];
	near("autocorrelation at lag zero", r[nx-1], e, 1.0e-10);
	for(i = 0; i < len r; i++)
		if(i != nx-1 && r[i] > r[nx-1]){
			fail("autocorrelation exceeded its lag-zero value");
			break;
		}
	# and it is symmetric
	worst = 0.0;
	for(i = 0; i < len r; i++){
		dd := math->fabs(r[i] - r[len r - 1 - i]);
		if(dd > worst)
			worst = dd;
	}
	if(worst > 1.0e-10)
		fail(sys->sprint("autocorrelation is not symmetric, by %g", worst));
}

firs()
{
	ntaps := 63;
	fc := 0.1;
	(h, e) := sig->firdesign(sig->LOWPASS, ntaps, fc, 0.0, sig->HAMMING);
	if(e != nil){
		fail("lowpass design: " + e);
		return;
	}
	# symmetric, which is what makes the phase linear
	worst := 0.0;
	for(i := 0; i < ntaps; i++){
		d := math->fabs(h[i] - h[ntaps-1-i]);
		if(d > worst)
			worst = d;
	}
	if(worst > 1.0e-16)
		fail(sys->sprint("the taps are not symmetric, by %g - the phase is not linear", worst));

	(m, nil) := sig->firresponse(h, 257);
	near("the passband gain at DC is exactly one", m[0], 1.0, 1.0e-12);
	# well into the stopband it is small, and the number is the design's
	stop := 0.0;
	for(i = 0; i < 257; i++){
		f := 0.5*real i/256.0;
		if(f > fc + 0.06 && m[i] > stop)
			stop = m[i];
	}
	if(stop > 0.01)
		fail(sys->sprint("the stopband reaches %g, which is not stopped", stop));
	else if(verbose)
		sys->print("     lowpass stopband %.4g (%.1f dB)\n", stop,
			20.0*math->log10(stop));

	# the response computed from the taps and the response MEASURED by
	# putting sinusoids through the filter must be the same thing
	worst = 0.0;
	fs := array[] of {0.02, 0.05, 0.09, 0.2, 0.3, 0.45};
	for(t := 0; t < len fs; t++){
		f := fs[t];
		n := 4000;
		x := array[n] of real;
		for(i = 0; i < n; i++)
			x[i] = math->cos(2.0*math->Pi*f*real i);
		y := sig->fir(x, h);
		# measure away from both ends, where the filter is running on
		# real data rather than on the zeros outside
		peak := ampat(y, 1000, 2000, f);
		# the design's own answer at that frequency
		(re, im) := (0.0, 0.0);
		for(k := 0; k < ntaps; k++){
			a := -2.0*math->Pi*f*real k;
			re += h[k]*math->cos(a);
			im += h[k]*math->sin(a);
		}
		wantm := math->sqrt(re*re+im*im);
		d := math->fabs(peak - wantm);
		if(d > worst)
			worst = d;
		if(verbose)
			sys->print("     f=%.2f measured %.6f, from the taps %.6f\n",
				f, peak, wantm);
	}
	if(worst > 1.0e-6)
		fail(sys->sprint("the filter does not do what its own coefficients say, by %g", worst));

	# fir() lines the output up with the input: an impulse in comes out
	# at the same place, not (ntaps-1)/2 later
	n := 200;
	imp := array[n] of real;
	for(i = 0; i < n; i++)
		imp[i] = 0.0;
	imp[100] = 1.0;
	y := sig->fir(imp, h);
	(best, at) := (0.0, -1);
	for(i = 0; i < n; i++)
		if(math->fabs(y[i]) > best){
			best = math->fabs(y[i]);
			at = i;
		}
	if(at != 100)
		fail(sys->sprint("an impulse at 100 came out at %d: the design delay is not removed", at));

	# a high pass is the complement: one at Nyquist, nothing at DC
	(hh, e2) := sig->firdesign(sig->HIGHPASS, ntaps, fc, 0.0, sig->HAMMING);
	if(e2 != nil)
		fail("highpass design: " + e2);
	else {
		(mh, nil) := sig->firresponse(hh, 257);
		near("the high pass at Nyquist", mh[256], 1.0, 1.0e-12);
		if(mh[0] > 0.01)
			fail(sys->sprint("the high pass passes %g at DC", mh[0]));
	}
	# a band pass passes its middle and stops both sides
	(hb, e3) := sig->firdesign(sig->BANDPASS, 129, 0.1, 0.2, sig->BLACKMAN);
	if(e3 != nil)
		fail("bandpass design: " + e3);
	else {
		(mb, nil) := sig->firresponse(hb, 257);
		near("the band pass in its middle", mb[int(0.15*512.0)], 1.0, 1.0e-3);
		if(mb[int(0.05*512.0)] > 0.01 || mb[int(0.35*512.0)] > 0.01)
			fail("the band pass does not stop both sides");
	}
}

iirs()
{
	# The bilinear transform maps frequency f to the analogue
	# frequency W = 2 tan(pi f), so the digital filter's magnitude
	# must equal the analogue Butterworth's at that W - EXACTLY, not
	# approximately, because the transform is exact and only the
	# frequency axis is bent.  That is a closed form for every point
	# of the response, which is a stronger statement than "it is
	# -3 dB at the cutoff".
	fc := 0.1;
	wc := 2.0*math->tan(math->Pi*fc);
	for(order := 1; order <= 6; order++){
		(bq, e) := sig->butterworth(sig->LOWPASS, order, fc);
		if(e != nil){
			fail(sys->sprint("butterworth order %d: %s", order, e));
			continue;
		}
		(m, nil) := sig->iirresponse(bq, 201);
		worst := 0.0;
		for(i := 0; i < 201; i++){
			f := 0.5*real i/200.0;
			if(f >= 0.5)
				continue;
			w := 2.0*math->tan(math->Pi*f);
			r := w/wc;
			p := 1.0;
			for(k := 0; k < 2*order; k++)
				p *= r;
			want := 1.0/math->sqrt(1.0 + p);
			d := math->fabs(m[i] - want);
			if(d > worst)
				worst = d;
		}
		if(worst > 1.0e-12)
			fail(sys->sprint("butterworth order %d is not maximally flat: off the "+
				"closed form by %g", order, worst));
		else if(verbose)
			sys->print("     butterworth order %d matches 1/sqrt(1+(W/Wc)^%d) to %g\n",
				order, 2*order, worst);
		# and the defining property, at the cutoff
		near(sys->sprint("order %d is -3 dB at the cutoff", order),
			magat(bq, fc), 1.0/math->sqrt(2.0), 1.0e-12);
		near(sys->sprint("order %d passes DC", order), magat(bq, 0.0), 1.0, 1.0e-12);
	}
	# a high pass is the mirror image
	(bh, eh) := sig->butterworth(sig->HIGHPASS, 4, fc);
	if(eh != nil)
		fail("butterworth highpass: " + eh);
	else {
		near("the high pass is -3 dB at its cutoff", magat(bh, fc),
			1.0/math->sqrt(2.0), 1.0e-12);
		near("the high pass passes Nyquist", magat(bh, 0.49999), 1.0, 1.0e-4);
		if(magat(bh, 0.0) > 1.0e-12)
			fail("the high pass passes DC");
	}
	# running it must agree with its own response: put a sinusoid
	# through and measure, after the start-up has decayed
	(bq, nil) := sig->butterworth(sig->LOWPASS, 4, 0.1);
	fs := array[] of {0.02, 0.05, 0.09, 0.15, 0.3};
	for(t := 0; t < len fs; t++){
		f := fs[t];
		n := 6000;
		x := array[n] of real;
		for(i := 0; i < n; i++)
			x[i] = math->cos(2.0*math->Pi*f*real i);
		for(k := 0; k < len bq; k++)
			bq[k].reset();
		y := sig->runiir(bq, x);
		peak := ampat(y, 3000, 2500, f);
		near(sys->sprint("the running filter at f=%.2f", f), peak, magat(bq, f), 1.0e-6);
	}
}

magat(bq: array of ref Biquad, f: real): real
{
	a := -2.0*math->Pi*f;
	(c1, s1) := (math->cos(a), math->sin(a));
	(c2, s2) := (math->cos(2.0*a), math->sin(2.0*a));
	(tr, ti) := (1.0, 0.0);
	for(k := 0; k < len bq; k++){
		b := bq[k];
		nr := b.b0 + b.b1*c1 + b.b2*c2;
		ni := b.b1*s1 + b.b2*s2;
		dr := 1.0 + b.a1*c1 + b.a2*c2;
		di := b.a1*s1 + b.a2*s2;
		dd := dr*dr + di*di;
		hr := (nr*dr + ni*di)/dd;
		hi := (ni*dr - nr*di)/dd;
		t := tr*hr - ti*hi;
		ti = tr*hi + ti*hr;
		tr = t;
	}
	return math->sqrt(tr*tr + ti*ti);
}

# An RC circuit and a one-pole low-pass filter are the same object
# reached from two directions, and this tree now has both.  circuit(2)
# integrates i = C dv/dt with the trapezoidal rule; signal(2) maps the
# pole through the bilinear transform.  Those are the SAME
# approximation - the bilinear transform IS trapezoidal integration -
# so the two must agree to rounding, not merely closely.  If they ever
# stop agreeing, one of the two libraries has changed underneath.
rcandfilter()
{
	# Two things differ and both are understood.  circuit(2) closes the
	# switch at t=0 with the source already on at both ends of its
	# first interval; the filter, fed a step, sees zero at the sample
	# before the first and takes half a step.  Priming the filter's
	# memory with the input it has been seeing is how you say the
	# source was already on, and makes both solve the same problem.
	#
	# The other difference is the pre-warping, which moves the pole by
	# tan(pi*fc)/(pi*fc).  That does not go away; it goes to zero with
	# the sample period, like h squared.  So the right check is not a
	# tolerance plucked from the air but the RATE: halve the step and
	# the disagreement must fall by four.
	(r, c) := (1000.0, 1.0e-6);
	tau := r*c;
	ds := array[3] of real;
	hs := array[] of {tau/10.0, tau/20.0, tau/40.0};
	for(t := 0; t < len hs; t++){
		h := hs[t];
		fc := h/(2.0*math->Pi*tau);
		(bq, e) := sig->onepole(fc);
		if(e != nil){
			fail("onepole: " + e);
			return;
		}
		bq[0].x1 = 1.0;			# the source was already on
		n := 100;
		step := array[n] of real;
		for(i := 0; i < n; i++)
			step[i] = 1.0;
		y := sig->runiir(bq, step);

		nl := build("V1 in 0 1\nR1 in out 1k\nC1 out 0 1u\n.tran 1u 1m\n");
		if(nl == nil)
			return;
		if(ckt->begin(nl) != nil){
			fail("rc and filter: begin");
			return;
		}
		# With the memory primed, the filter's sample 0 is already the
		# result of one step, so it stands for t=h and not t=0.  Step
		# the circuit first and the two are lined up.
		worst := 0.0;
		wexp := 0.0;
		for(i = 0; i < n; i++){
			if(ckt->step(nl, h) != nil){
				fail("rc and filter: step");
				return;
			}
			d := math->fabs(y[i] - ckt->nodev(nl, "out"));
			if(d > worst)
				worst = d;
			d = math->fabs(y[i] - (1.0 - math->exp(-real(i+1)*h/tau)));
			if(d > wexp)
				wexp = d;
		}
		ds[t] = worst;
		if(verbose)
			sys->print("     h=tau/%-3d circuit vs filter %.4g, filter vs exp %.4g\n",
				int(tau/h), worst, wexp);
		if(wexp > 0.02)
			fail(sys->sprint("the one-pole filter is %g away from 1-exp(-t/RC) "+
				"at h=tau/%d", wexp, int(tau/h)));
	}
	for(t = 1; t < len ds; t++){
		ratio := ds[t-1]/ds[t];
		if(ratio < 3.5 || ratio > 4.5)
			fail(sys->sprint("halving the step should divide the disagreement "+
				"between circuit(2) and signal(2) by four, and it divided it "+
				"by %.3f (%g then %g)", ratio, ds[t-1], ds[t]));
		else if(verbose)
			sys->print("     halving the step divided the disagreement by %.3f\n",
				ratio);
	}
	if(ds[0] < 1.0e-9)
		fail(sys->sprint("the disagreement at the coarsest step is only %g, so "+
			"watching it shrink proves nothing", ds[0]));
}

build(spec: string): ref Circuit->Net
{
	(n, err) := ckt->parse(spec);
	if(err != nil){
		fail("parse: " + err);
		return nil;
	}
	return n;
}

# What the design refuses, which is the half that says the checks above
# mean something.
refusals()
{
	(nil, e) := sig->firdesign(sig->LOWPASS, 64, 0.1, 0.0, sig->HANN);
	if(e == nil)
		fail("an even number of taps has no whole-sample delay and should be refused");
	(nil, e2) := sig->firdesign(sig->LOWPASS, 63, 0.6, 0.0, sig->HANN);
	if(e2 == nil)
		fail("a cutoff above Nyquist should be refused");
	(nil, e3) := sig->firdesign(sig->BANDPASS, 63, 0.3, 0.2, sig->HANN);
	if(e3 == nil)
		fail("an upper cutoff below the lower one should be refused");
	(nil, e4) := sig->firdesign(sig->LOWPASS, 63, 0.1, 0.0, sig->HANN);
	if(e4 != nil)
		fail("a good design was refused: " + e4);
	(nil, e5) := sig->butterworth(sig->LOWPASS, 0, 0.1);
	if(e5 == nil)
		fail("an order of zero should be refused");
	(nil, e6) := sig->butterworth(sig->LOWPASS, 99, 0.1);
	if(e6 == nil)
		fail("an order of 99 should be refused, not attempted");
	(nil, e7) := sig->onepole(0.5);
	if(e7 == nil)
		fail("a cutoff at Nyquist should be refused");
	(nil, e8) := sig->butterworth(sig->LOWPASS, 4, 0.1);
	if(e8 != nil)
		fail("a good butterworth was refused: " + e8);
}
