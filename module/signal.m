# signal - the discrete Fourier transform, windows, convolution and filters
#
# A spectrum is two parallel arrays of reals, the real and imaginary
# parts, rather than an array of a complex adt: an array of `ref
# Complex' is an array of pointers, and every loop over it chases one.
# It is also the shape ffts(2) already uses and the shape math(2)'s
# array primitives can be pointed at.
#
# FREQUENCY IS IN CYCLES PER SAMPLE throughout, from 0 to 1/2, and never
# in hertz.  A sampled signal does not know its own sample rate - that
# is the caller's business and belongs in the caller's axis labels - and
# a library that took hertz would have to be told the rate by every
# function in it.  Nyquist is therefore always 0.5.
#
# The forward transform carries no scale factor and the inverse divides
# by n, which is the convention in which the transform of a constant is
# n at bin 0.  It is stated here because the other convention exists and
# nothing in a test can tell you which one a library chose.

Signal: module
{
	PATH: con "/dis/lib/signal.dis";

	init:	fn();

	# The transform, in place, for ANY length - not only a power of
	# two.  A length that is not a power of two is done by Bluestein's
	# method, which turns the transform into a convolution that is,
	# and so is exact for every n rather than approximate or refused.
	fft:	fn(re, im: array of real);
	ifft:	fn(re, im: array of real);

	# A real signal's spectrum, as new arrays.  The result is the full
	# complex spectrum of length n, whose upper half is the conjugate
	# mirror of its lower half; realbins() says how many of them are
	# distinct, which is what to plot.
	rfft:	fn(x: array of real): (array of real, array of real);
	realbins: fn(n: int): int;

	# The frequency each bin stands for, in cycles per sample.  Bins
	# above n/2 stand for NEGATIVE frequencies, which is the thing
	# everyone gets wrong when labelling an axis.  For an even n, bin
	# n/2 is reported as +0.5: it is exactly Nyquist, where +0.5 and
	# -0.5 are the same frequency and nothing distinguishes them.
	binfreq: fn(k, n: int): real;

	magnitude: fn(re, im: array of real): array of real;
	phase:	fn(re, im: array of real): array of real;

	# Windows.  A window is not a detail: the rectangular one leaks a
	# strong tone across the whole spectrum and hides a weak one beside
	# it, and that is what the others are for.
	RECT, HANN, HAMMING, BLACKMAN: con iota;
	# There are two of these and the difference matters.  window() is
	# the PERIODIC form, for use before a transform: it treats the n
	# samples as one period of something that repeats, which is what
	# the transform assumes, and it makes a tone that sits on a bin
	# land on that one bin.  windowsym() is the SYMMETRIC form, for
	# designing a filter: its first and last taps are equal, and that
	# symmetry is the whole reason a windowed-sinc filter has exactly
	# linear phase.  Using the periodic one to design a filter costs
	# the symmetry and with it the linear phase, silently.
	window:	fn(kind, n: int): array of real;
	windowsym: fn(kind, n: int): array of real;
	windowname: fn(kind: int): string;

	# The one-sided power spectrum of a real signal, windowed and
	# scaled so that a sinusoid of amplitude A reads A*A/2 in its bin,
	# whatever the window and whatever the length.
	periodogram: fn(x: array of real, win: int): array of real;

	# Convolution, as the definition (len x + len h - 1 long), and by
	# the transform.  Both are here because the second is only worth
	# having if it agrees with the first, and the test says by how
	# much.
	convolve: fn(x, h: array of real): array of real;
	fftconvolve: fn(x, h: array of real): array of real;
	# Cross-correlation, lags -(len y - 1) .. (len x - 1)
	correlate: fn(x, y: array of real): array of real;

	# FIR design by windowed sinc.  Cutoffs in cycles per sample;
	# f2 is ignored for a low or high pass.  An odd number of taps
	# gives a filter with an exactly linear phase and an integer delay
	# of (ntaps-1)/2 samples, so that is what is required.
	LOWPASS, HIGHPASS, BANDPASS, BANDSTOP: con iota;
	firdesign: fn(kind, ntaps: int, f1, f2: real, win: int): (array of real, string);
	# Filter, returning the same length as the input, with the design
	# delay removed.
	fir:	fn(x, h: array of real): array of real;

	# One section of an IIR filter: y = b0 x + b1 x' + b2 x'' - a1 y' -
	# a2 y''.  A filter of higher order is a cascade of these, because
	# a single high-order recursion loses its poles to rounding.
	Biquad: adt {
		b0, b1, b2, a1, a2: real;
		x1, x2, y1, y2: real;	# what it remembers

		reset:	fn(s: self ref Biquad);
		run:	fn(s: self ref Biquad, x: real): real;
	};

	# Butterworth, by the bilinear transform with the cutoff pre-warped
	# so that the digital filter's -3 dB point lands where it was
	# asked for rather than where the transform happens to put it.
	butterworth: fn(kind, order: int, fc: real): (array of ref Biquad, string);
	# A one-pole low pass, which is the shape an RC circuit has.  Note
	# that the cutoff is pre-warped like any other design here, so this
	# is not quite the bilinear transform of a particular RC: it is the
	# one-pole filter whose -3 dB point is exactly at fc.  The two
	# converge as the sample period shrinks, and signaltest(1) measures
	# that against circuit(2) rather than asserting it.
	onepole: fn(fc: real): (array of ref Biquad, string);
	runiir:	fn(bq: array of ref Biquad, x: array of real): array of real;

	# The frequency response of a filter at nf points from 0 to
	# Nyquist, measured from its own coefficients: magnitude and phase.
	firresponse: fn(h: array of real, nf: int): (array of real, array of real);
	iirresponse: fn(bq: array of ref Biquad, nf: int): (array of real, array of real);
};
