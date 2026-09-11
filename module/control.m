# control - linear systems as transfer functions
#
# A transfer function is a ratio of polynomials in s.  Coefficients are
# given HIGHEST POWER FIRST, the way they are written down:
#
#	num = {1.0, 3.0}	den = {1.0, 2.0, 5.0}
#
# is (s + 3)/(s^2 + 2s + 5).  The other order exists in other libraries
# and nothing in an answer reveals which one was meant, so it is said
# here.
#
# Everything is continuous-time.  A discrete system is a different
# object with a different stability test, and mixing the two silently is
# the classic way to get a confident wrong answer; signal(2) is where
# the discrete filters live.
#
# Stability is asked twice, on purpose.  routh() answers it from the
# coefficients alone, by the Routh array, without finding a single root;
# stable() answers it by finding the roots and looking at them.  They
# are independent routes to the same fact, and controltest(1) runs them
# against each other on a few thousand polynomials - which is what makes
# either believable.

Control: module
{
	PATH: con "/dis/lib/control.dis";

	init:	fn();

	Tf: adt {
		num, den: array of real;	# highest power first

		order:	fn(t: self ref Tf): int;
		# a transfer function is proper if the denominator's degree is
		# at least the numerator's, which is what it means for a
		# system to be causal; everything here requires it
		proper:	fn(t: self ref Tf): int;
		dcgain:	fn(t: self ref Tf): real;
		text:	fn(t: self ref Tf): string;
	};

	# Build one, with the leading zeros trimmed and the denominator
	# checked for being a polynomial at all.
	tf:	fn(num, den: array of real): (ref Tf, string);

	# Polynomials, highest power first.
	polymul: fn(a, b: array of real): array of real;
	polyadd: fn(a, b: array of real): array of real;
	polyeval: fn(a: array of real, x: real): real;
	polyfromroots: fn(re, im: array of real): array of real;

	# The three ways of putting two systems together.  feedback() with
	# sign -1 is the negative feedback every control loop is made of:
	# g/(1 + g*h).
	series:	fn(a, b: ref Tf): ref Tf;
	parallel: fn(a, b: ref Tf): ref Tf;
	feedback: fn(g, h: ref Tf, sign: int): (ref Tf, string);

	# Roots of a polynomial, by Durand-Kerner: every root at once,
	# rather than one at a time with deflation, which loses accuracy in
	# the later roots as the earlier errors are baked into the
	# deflated polynomial.
	roots:	fn(a: array of real): (array of real, array of real, string);
	poles:	fn(t: ref Tf): (array of real, array of real, string);
	zeros:	fn(t: ref Tf): (array of real, array of real, string);

	# Stability, by the roots.
	stable:	fn(t: ref Tf): (int, string);
	# and stability from the coefficients alone: the number of roots
	# with positive real part, without finding any of them.
	routh:	fn(den: array of real): (int, string);

	# Time responses, by integrating the system in controllable
	# canonical form with fourth-order Runge-Kutta.  n samples dt
	# apart, starting at t=0.
	stepresponse: fn(t: ref Tf, dt: real, n: int): (array of real, string);
	# An impulse response is refused when the numerator's degree equals
	# the denominator's, because then it contains a delta at t=0 and no
	# array of samples can hold one; returning the rest of it and
	# saying nothing would be a plot with a piece missing.
	impulseresponse: fn(t: ref Tf, dt: real, n: int): (array of real, string);
	# and the response to any input at all, sampled the same way
	lsim:	fn(t: ref Tf, u: array of real, dt: real): (array of real, string);

	# The frequency response at each w, in radians per second:
	# magnitude and phase in radians.  The phase is unwrapped, so that
	# a Bode plot of a high-order system does not jump by 2 pi in the
	# middle of a smooth roll-off.
	bode:	fn(t: ref Tf, w: array of real): (array of real, array of real);

	# Gain and phase margin of an open loop, with the frequencies they
	# occur at.  A gain margin of Infinity means the phase never
	# reaches -180 degrees, which is not the same as a large one.
	Margins: adt {
		gain, gainw: real;	# gain margin (a ratio, not dB) and its frequency
		phase, phasew: real;	# phase margin in radians, and its frequency
		hasgain, hasphase: int;
	};
	margins: fn(t: ref Tf): (ref Margins, string);

	# What a course asks about a step response.
	Metrics: adt {
		final:	real;
		rise:	real;	# 10% to 90% of the final value
		peak:	real;	# the largest value reached
		peakt:	real;
		overshoot: real;	# as a fraction of the final value
		settle:	real;	# last time it left a 2% band
	};
	metrics: fn(y: array of real, dt: real): ref Metrics;

	# A PID controller: kp + ki/s + kd*s/(taud*s + 1).  The derivative
	# term needs the filter - a bare kd*s is not proper, cannot be
	# realised, and differentiates the noise in preference to the
	# signal.
	pid:	fn(kp, ki, kd, taud: real): (ref Tf, string);
};
