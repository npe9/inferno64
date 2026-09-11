implement Signal;

# Signals: the transform, windows, convolution and filters.  See
# signal.m for the conventions - cycles per sample, and where the 1/n
# goes - both of which are choices no test can discover for you.

include "sys.m";
	sys: Sys;
include "math.m";
	math: Math;
include "signal.m";

init()
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
}

# ---------------------------------------------------------------- the
# transform.
#
# A power of two is done by Cooley-Tukey, decimation in time, iterative
# rather than recursive.  Anything else is done by Bluestein, which is
# not an approximation: it rewrites jk as (j*j + k*k - (k-j)^2)/2, which
# turns the transform into a convolution, and a convolution can be done
# with transforms of any convenient longer length.  So every n is exact
# and no length is refused - which matters, because the length of a
# recording is whatever it is, and a library that silently padded to the
# next power of two would be answering about a different signal.

ispow2(n: int): int
{
	return n > 0 && (n & (n-1)) == 0;
}

fft(re, im: array of real)
{
	transform(re, im, -1);
}

ifft(re, im: array of real)
{
	n := len re;
	transform(re, im, 1);
	if(n == 0)
		return;
	s := 1.0/real n;
	for(i := 0; i < n; i++){
		re[i] *= s;
		im[i] *= s;
	}
}

# sign is -1 for the forward transform, +1 for the inverse; the inverse
# scaling is the caller's
transform(re, im: array of real, sign: int)
{
	n := len re;
	if(n != len im)
		return;
	if(n < 2)
		return;
	if(ispow2(n))
		radix2(re, im, sign);
	else
		bluestein(re, im, sign);
}

radix2(re, im: array of real, sign: int)
{
	n := len re;
	# bit-reversal permutation
	j := 0;
	for(i := 1; i < n; i++){
		bit := n >> 1;
		for(; j & bit; bit >>= 1)
			j ^= bit;
		j |= bit;
		if(i < j){
			(re[i], re[j]) = (re[j], re[i]);
			(im[i], im[j]) = (im[j], im[i]);
		}
	}
	for(l := 2; l <= n; l <<= 1){
		ang := real sign * 2.0*math->Pi/real l;
		(wr, wi) := (math->cos(ang), math->sin(ang));
		for(i = 0; i < n; i += l){
			(cr, ci) := (1.0, 0.0);
			for(k := 0; k < l/2; k++){
				(ur, ui) := (re[i+k], im[i+k]);
				(vr, vi) := (re[i+k+l/2]*cr - im[i+k+l/2]*ci,
					     re[i+k+l/2]*ci + im[i+k+l/2]*cr);
				re[i+k] = ur+vr;
				im[i+k] = ui+vi;
				re[i+k+l/2] = ur-vr;
				im[i+k+l/2] = ui-vi;
				t := cr*wr - ci*wi;
				ci = cr*wi + ci*wr;
				cr = t;
			}
		}
	}
}

bluestein(re, im: array of real, sign: int)
{
	n := len re;
	# the chirp, with the angle taken on j*j mod 2n rather than j*j:
	# j*j overflows the exact range of a real long before n does, and
	# the angle only ever mattered modulo 2*Pi
	(cr, ci) := (array[n] of real, array[n] of real);
	for(j := 0; j < n; j++){
		jj := (j*j) % (2*n);
		a := real sign * math->Pi * real jj / real n;
		cr[j] = math->cos(a);
		ci[j] = math->sin(a);
	}
	m := 1;
	while(m < 2*n - 1)
		m <<= 1;
	(ar, ai) := (array[m] of real, array[m] of real);
	(br, bi) := (array[m] of real, array[m] of real);
	for(j = 0; j < m; j++){
		ar[j] = ai[j] = br[j] = bi[j] = 0.0;
	}
	for(j = 0; j < n; j++){
		ar[j] = re[j]*cr[j] - im[j]*ci[j];
		ai[j] = re[j]*ci[j] + im[j]*cr[j];
		# b is the conjugate chirp, laid out so that the cyclic
		# convolution of length m computes the linear one
		br[j] = cr[j];
		bi[j] = -ci[j];
		if(j > 0){
			br[m-j] = cr[j];
			bi[m-j] = -ci[j];
		}
	}
	radix2(ar, ai, -1);
	radix2(br, bi, -1);
	for(j = 0; j < m; j++){
		t := ar[j]*br[j] - ai[j]*bi[j];
		ai[j] = ar[j]*bi[j] + ai[j]*br[j];
		ar[j] = t;
	}
	radix2(ar, ai, 1);
	s := 1.0/real m;
	for(j = 0; j < n; j++){
		(xr, xi) := (ar[j]*s, ai[j]*s);
		re[j] = xr*cr[j] - xi*ci[j];
		im[j] = xr*ci[j] + xi*cr[j];
	}
}

rfft(x: array of real): (array of real, array of real)
{
	n := len x;
	(re, im) := (array[n] of real, array[n] of real);
	for(i := 0; i < n; i++){
		re[i] = x[i];
		im[i] = 0.0;
	}
	fft(re, im);
	return (re, im);
}

# A real signal's spectrum repeats itself: bin n-k is the conjugate of
# bin k, so only these are new.
realbins(n: int): int
{
	return n/2 + 1;
}

binfreq(k, n: int): real
{
	if(n == 0)
		return 0.0;
	if(k > n/2)
		k -= n;			# the bins above Nyquist are negative
	return real k / real n;
}

magnitude(re, im: array of real): array of real
{
	n := len re;
	m := array[n] of real;
	for(i := 0; i < n; i++)
		m[i] = math->sqrt(re[i]*re[i] + im[i]*im[i]);
	return m;
}

phase(re, im: array of real): array of real
{
	n := len re;
	p := array[n] of real;
	for(i := 0; i < n; i++)
		p[i] = math->atan2(im[i], re[i]);
	return p;
}

# ---------------------------------------------------------------- windows

windowname(kind: int): string
{
	case kind {
	RECT =>		return "rectangular";
	HANN =>		return "Hann";
	HAMMING =>	return "Hamming";
	BLACKMAN =>	return "Blackman";
	}
	return "unknown";
}

# The periodic form (divide by n, not n-1), which is the one to use when
# the window is applied before a transform: it makes the windowed tone
# land on one bin instead of two.
window(kind, n: int): array of real
{
	return win(kind, n, real n);
}

# The symmetric form (divide by n-1), for designing a filter: the first
# and last taps come out equal, and that symmetry is exactly what makes
# a windowed-sinc filter's phase linear.  Designing with the periodic
# form instead costs the symmetry, and the only sign of it is that the
# phase quietly stops being linear.
windowsym(kind, n: int): array of real
{
	if(n < 2)
		return window(kind, n);
	return win(kind, n, real(n-1));
}

win(kind, n: int, den: real): array of real
{
	w := array[n] of real;
	for(i := 0; i < n; i++){
		t := 2.0*math->Pi*real i/den;
		case kind {
		HANN =>		w[i] = 0.5 - 0.5*math->cos(t);
		HAMMING =>	w[i] = 0.54 - 0.46*math->cos(t);
		BLACKMAN =>	w[i] = 0.42 - 0.5*math->cos(t) + 0.08*math->cos(2.0*t);
		* =>		w[i] = 1.0;
		}
	}
	return w;
}

# Scaled so that a sinusoid of amplitude A reads A*A/2 in its bin
# whatever the window is.  Without that a Hann window halves every
# height and the reader concludes the signal got quieter.
periodogram(x: array of real, win: int): array of real
{
	n := len x;
	if(n == 0)
		return array[0] of real;
	w := window(win, n);
	sum := 0.0;
	for(i := 0; i < n; i++)
		sum += w[i];
	(re, im) := (array[n] of real, array[n] of real);
	for(i = 0; i < n; i++){
		re[i] = x[i]*w[i];
		im[i] = 0.0;
	}
	fft(re, im);
	nb := realbins(n);
	p := array[nb] of real;
	s := 2.0/(sum*sum);
	for(i = 0; i < nb; i++){
		v := (re[i]*re[i] + im[i]*im[i])*s;
		# DC and Nyquist are not halves of a conjugate pair, so the
		# factor of two that accounts for the mirrored half is wrong
		# for them
		if(i == 0 || (n%2 == 0 && i == n/2))
			v /= 2.0;
		p[i] = v;
	}
	return p;
}

# ---------------------------------------------------------- convolution

convolve(x, h: array of real): array of real
{
	(nx, nh) := (len x, len h);
	if(nx == 0 || nh == 0)
		return array[0] of real;
	y := array[nx+nh-1] of real;
	for(i := 0; i < len y; i++)
		y[i] = 0.0;
	for(i = 0; i < nx; i++){
		xi := x[i];
		if(xi == 0.0)
			continue;
		for(j := 0; j < nh; j++)
			y[i+j] += xi*h[j];
	}
	return y;
}

fftconvolve(x, h: array of real): array of real
{
	(nx, nh) := (len x, len h);
	if(nx == 0 || nh == 0)
		return array[0] of real;
	n := nx+nh-1;
	m := 1;
	while(m < n)
		m <<= 1;
	(ar, ai) := (array[m] of real, array[m] of real);
	(br, bi) := (array[m] of real, array[m] of real);
	for(i := 0; i < m; i++)
		ar[i] = ai[i] = br[i] = bi[i] = 0.0;
	ar[0:] = x;
	br[0:] = h;
	fft(ar, ai);
	fft(br, bi);
	for(i = 0; i < m; i++){
		t := ar[i]*br[i] - ai[i]*bi[i];
		ai[i] = ar[i]*bi[i] + ai[i]*br[i];
		ar[i] = t;
	}
	ifft(ar, ai);
	y := array[n] of real;
	y[0:] = ar[0:n];
	return y;
}

# Cross-correlation: y[lag + (len b - 1)] = sum a[i] b[i-lag].  It is the
# convolution of a with b reversed, which is how it is computed, because
# writing the sum twice is how the two drift apart.
correlate(x, y: array of real): array of real
{
	ny := len y;
	r := array[ny] of real;
	for(i := 0; i < ny; i++)
		r[i] = y[ny-1-i];
	return convolve(x, r);
}

# ----------------------------------------------------------------- FIR

# The ideal low pass is a sinc, which is infinitely long; cutting it off
# is what makes the ripple, and multiplying the cut-off piece by a
# window is what controls it.  That is the whole of this method, and the
# window choice is the entire design decision.
firdesign(kind, ntaps: int, f1, f2: real, win: int): (array of real, string)
{
	if(ntaps < 3)
		return (nil, "a filter needs at least three taps");
	if(ntaps % 2 == 0)
		return (nil, "an even number of taps has no whole-sample delay and so no exactly linear phase; use an odd number");
	if(f1 <= 0.0 || f1 >= 0.5)
		return (nil, "a cutoff is in cycles per sample and must be between 0 and 0.5, which is Nyquist");
	if(kind == BANDPASS || kind == BANDSTOP){
		if(f2 <= f1 || f2 >= 0.5)
			return (nil, "the upper cutoff must be above the lower one and below Nyquist");
	}
	w := windowsym(win, ntaps);
	h := array[ntaps] of real;
	mid := (ntaps-1)/2;
	for(i := 0; i < ntaps; i++){
		m := i - mid;
		case kind {
		LOWPASS =>
			h[i] = 2.0*f1*sinc(2.0*f1*real m);
		HIGHPASS =>
			# all-pass minus low-pass: the impulse at the centre
			# is the all-pass
			h[i] = -2.0*f1*sinc(2.0*f1*real m);
			if(m == 0)
				h[i] += 1.0;
		BANDPASS =>
			h[i] = 2.0*f2*sinc(2.0*f2*real m) - 2.0*f1*sinc(2.0*f1*real m);
		BANDSTOP =>
			h[i] = 2.0*f1*sinc(2.0*f1*real m) - 2.0*f2*sinc(2.0*f2*real m);
			if(m == 0)
				h[i] += 1.0;
		* =>
			return (nil, "no such kind of filter");
		}
		h[i] *= w[i];
	}
	# make the gain exactly one where it is meant to be one, since
	# windowing the sinc changes it slightly and a reader checking the
	# passband gain should find 1 and not 0.9994
	(fr, fi) := (0.0, 0.0);
	fref := 0.0;
	case kind {
	LOWPASS or BANDSTOP =>	fref = 0.0;
	HIGHPASS =>		fref = 0.5;
	BANDPASS =>		fref = 0.5*(f1+f2);
	}
	for(i = 0; i < ntaps; i++){
		a := -2.0*math->Pi*fref*real i;
		fr += h[i]*math->cos(a);
		fi += h[i]*math->sin(a);
	}
	g := math->sqrt(fr*fr + fi*fi);
	if(g > 0.0)
		for(i = 0; i < ntaps; i++)
			h[i] /= g;
	return (h, nil);
}

sinc(x: real): real
{
	if(x == 0.0)
		return 1.0;
	a := math->Pi*x;
	return math->sin(a)/a;
}

# The filtered signal, the same length as the input and lined up with
# it: a linear-phase FIR delays everything by (ntaps-1)/2 samples and
# that delay is removed here, so a plot of the two can be read together.
fir(x, h: array of real): array of real
{
	y := convolve(x, h);
	n := len x;
	d := (len h - 1)/2;
	out := array[n] of real;
	for(i := 0; i < n; i++)
		if(i+d < len y)
			out[i] = y[i+d];
		else
			out[i] = 0.0;
	return out;
}

# ----------------------------------------------------------------- IIR

Biquad.reset(s: self ref Biquad)
{
	s.x1 = s.x2 = s.y1 = s.y2 = 0.0;
}

Biquad.run(s: self ref Biquad, x: real): real
{
	y := s.b0*x + s.b1*s.x1 + s.b2*s.x2 - s.a1*s.y1 - s.a2*s.y2;
	s.x2 = s.x1;
	s.x1 = x;
	s.y2 = s.y1;
	s.y1 = y;
	return y;
}

runiir(bq: array of ref Biquad, x: array of real): array of real
{
	n := len x;
	y := array[n] of real;
	for(i := 0; i < n; i++){
		v := x[i];
		for(k := 0; k < len bq; k++)
			v = bq[k].run(v);
		y[i] = v;
	}
	return y;
}

# The bilinear transform maps the whole imaginary axis onto the unit
# circle, so it bends frequency: a pole meant for w lands at
# 2*atan(w*T/2).  Pre-warping is undoing that bend at the one frequency
# that matters, the cutoff, so the -3 dB point comes out where it was
# asked for.  Everything above it is still bent, which is why a digital
# filter's stopband is not its analogue one.
prewarp(fc: real): real
{
	return 2.0*math->tan(math->Pi*fc);	# with the sample period taken as 1
}

# One pole, placed by the bilinear transform with its cutoff pre-warped
# so the -3 dB point lands exactly at fc.  This is the shape an RC
# circuit has; it is not the bilinear transform of one particular RC,
# because the pre-warping moves the pole by tan(pi*fc)/(pi*fc), which
# goes to 1 as the sample period shrinks and is the difference
# signaltest(1) measures against circuit(2).
onepole(fc: real): (array of ref Biquad, string)
{
	if(fc <= 0.0 || fc >= 0.5)
		return (nil, "a cutoff is in cycles per sample and must be between 0 and 0.5, which is Nyquist");
	w := prewarp(fc);
	# H(s) = w/(s+w), s -> 2(z-1)/(z+1)
	k := w/2.0;
	d := 1.0 + k;
	b := ref Biquad;
	b.b0 = k/d;
	b.b1 = k/d;
	b.b2 = 0.0;
	b.a1 = (1.0 - k)/d * -1.0;
	b.a2 = 0.0;
	b.reset();
	return (array[1] of {b}, nil);
}

butterworth(kind, order: int, fc: real): (array of ref Biquad, string)
{
	if(kind != LOWPASS && kind != HIGHPASS)
		return (nil, "butterworth here is a low pass or a high pass; a band filter is a cascade of the two");
	if(order < 1 || order > 8)
		return (nil, "the order must be between 1 and 8");
	if(fc <= 0.0 || fc >= 0.5)
		return (nil, "a cutoff is in cycles per sample and must be between 0 and 0.5, which is Nyquist");
	w := prewarp(fc);
	nsec := (order+1)/2;
	bq := array[nsec] of ref Biquad;
	si := 0;
	# The poles of a Butterworth filter sit on a half circle of radius
	# w, evenly spaced; taking them in conjugate pairs gives one
	# quadratic section each, and an odd order leaves one real pole
	# over.
	if(order % 2 == 1){
		(b, e) := onepole1(kind, w);
		if(e != nil)
			return (nil, e);
		bq[si++] = b;
	}
	for(k := 0; k < order/2; k++){
		# the pair's angle from the imaginary axis
		th := math->Pi*(2.0*real k + 1.0)/(2.0*real order);
		if(order % 2 == 1)
			th = math->Pi*(2.0*real(k+1))/(2.0*real order);
		q := 1.0/(2.0*math->cos(th));
		bq[si++] = section(kind, w, q);
	}
	return (bq, nil);
}

# a single real pole at w, bilinear-transformed
onepole1(kind: int, w: real): (ref Biquad, string)
{
	k := w/2.0;
	d := 1.0 + k;
	b := ref Biquad;
	if(kind == HIGHPASS){
		b.b0 = 1.0/d;
		b.b1 = -1.0/d;
	} else {
		b.b0 = k/d;
		b.b1 = k/d;
	}
	b.b2 = 0.0;
	b.a1 = (k - 1.0)/d;
	b.a2 = 0.0;
	b.reset();
	return (b, nil);
}

# one conjugate pair: H(s) = w^2/(s^2 + s*w/q + w^2) for a low pass
section(kind: int, w, q: real): ref Biquad
{
	# s -> 2(z-1)/(z+1); write the numerator and denominator in z^-1
	k := w/2.0;
	kk := k*k;
	d := kk + k/q + 1.0;
	b := ref Biquad;
	if(kind == HIGHPASS){
		b.b0 = 1.0/d;
		b.b1 = -2.0/d;
		b.b2 = 1.0/d;
	} else {
		b.b0 = kk/d;
		b.b1 = 2.0*kk/d;
		b.b2 = kk/d;
	}
	b.a1 = 2.0*(kk - 1.0)/d;
	b.a2 = (kk - k/q + 1.0)/d;
	b.reset();
	return b;
}

# ------------------------------------------------------------ response

firresponse(h: array of real, nf: int): (array of real, array of real)
{
	(m, p) := (array[nf] of real, array[nf] of real);
	for(i := 0; i < nf; i++){
		f := 0.5*real i/real(nf-1);
		(re, im) := (0.0, 0.0);
		for(k := 0; k < len h; k++){
			a := -2.0*math->Pi*f*real k;
			re += h[k]*math->cos(a);
			im += h[k]*math->sin(a);
		}
		m[i] = math->sqrt(re*re + im*im);
		p[i] = math->atan2(im, re);
	}
	return (m, p);
}

iirresponse(bq: array of ref Biquad, nf: int): (array of real, array of real)
{
	(m, p) := (array[nf] of real, array[nf] of real);
	for(i := 0; i < nf; i++){
		f := 0.5*real i/real(nf-1);
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
		m[i] = math->sqrt(tr*tr + ti*ti);
		p[i] = math->atan2(ti, tr);
	}
	return (m, p);
}
