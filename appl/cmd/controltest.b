implement Controltest;

# controltest - check control(2) against the textbook answers
#
# A second-order system's overshoot, peak time and settling are the
# first closed forms in any controls course, and they are exact:
# overshoot is exp(-pi*zeta/sqrt(1-zeta^2)) and nothing else.  The roots
# of a polynomial built FROM known roots must be those roots.  An
# integrator falls at exactly 20 dB a decade with exactly -90 degrees of
# phase.
#
# The most useful check here is not against a formula at all: routh()
# and stable() answer the same question by completely different means -
# one from the coefficients, one by finding every root - and they are
# run against each other on thousands of random polynomials.  Neither is
# the oracle; agreeing is the evidence.

include "sys.m";
	sys: Sys;
include "draw.m";
include "math.m";
	math: Math;
include "control.m";
	ctl: Control;
	Tf: import ctl;
include "circuit.m";
	ckt: Circuit;

Controltest: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

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

seed := 4242;
rnd(): real
{
	seed = (seed*1103515245 + 12345) & 16r7fffffff;
	return real(seed%20000 - 10000)/2000.0;
}

mk(num, den: array of real): ref Tf
{
	(t, e) := ctl->tf(num, den);
	if(e != nil){
		fail("tf: " + e);
		return nil;
	}
	return t;
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	ctl = load Control Control->PATH;
	ckt = load Circuit Circuit->PATH;
	if(ctl == nil || ckt == nil || math == nil){
		sys->print("FAIL load: %r\n");
		raise "fail:load";
	}
	ctl->init();
	ckt->init();
	for(a := tl argv; a != nil; a = tl a)
		if(hd a == "-v")
			verbose = 1;

	polynomials();
	rootsof();
	stability();
	responses();
	frequency();
	loops();
	rcplant();
	refusals();

	if(nfail == 0)
		sys->print("OK   control(2) against the textbook answers\n");
	else {
		sys->print("%d failures\n", nfail);
		raise "fail:controltest";
	}
}

polynomials()
{
	# (s+1)(s+2) = s^2 + 3s + 2
	c := ctl->polymul(array[] of {1.0, 1.0}, array[] of {1.0, 2.0});
	near("polymul [0]", c[0], 1.0, 0.0);
	near("polymul [1]", c[1], 3.0, 0.0);
	near("polymul [2]", c[2], 2.0, 0.0);
	# adding is from the right, since the coefficients are written
	# highest power first: (s^2+1) + (s+2) = s^2 + s + 3
	a := ctl->polyadd(array[] of {1.0, 0.0, 1.0}, array[] of {1.0, 2.0});
	near("polyadd [0]", a[0], 1.0, 0.0);
	near("polyadd [1]", a[1], 1.0, 0.0);
	near("polyadd [2]", a[2], 3.0, 0.0);
	near("polyeval at 2", ctl->polyeval(array[] of {1.0, 3.0, 2.0}, 2.0), 12.0, 0.0);
	# text, because a system a reader cannot read back is half useless
	t := mk(array[] of {1.0, 3.0}, array[] of {1.0, 2.0, 5.0});
	if(t != nil && t.text() != "s + 3 / s^2 + 2 s + 5")
		fail("text(): got `" + t.text() + "'");
	near("dc gain", t.dcgain(), 3.0/5.0, 1.0e-15);
}

rootsof()
{
	# a polynomial built from known roots must give them back
	want := array[] of {-1.0, -2.0, -3.0, -0.5};
	p := ctl->polyfromroots(want, array[] of {0.0, 0.0, 0.0, 0.0});
	(re, im, e) := ctl->roots(p);
	if(e != nil){
		fail("roots: " + e);
		return;
	}
	if(len re != 4)
		fail("a quartic has four roots, not " + string len re);
	else {
		matched := array[4] of int;
		for(i := 0; i < 4; i++){
			best := 1.0e30;
			at := -1;
			for(j := 0; j < 4; j++){
				if(matched[j])
					continue;
				d := math->fabs(re[j] - want[i]) + math->fabs(im[j]);
				if(d < best){
					best = d;
					at = j;
				}
			}
			matched[at] = 1;
			if(best > 1.0e-10)
				fail(sys->sprint("root %g came back %g%+gi", want[i], re[at], im[at]));
		}
		if(verbose)
			sys->print("     four real roots recovered\n");
	}
	# a conjugate pair: s^2 + 2s + 5 has roots -1 +- 2i
	(r2, i2, nil) := ctl->roots(array[] of {1.0, 2.0, 5.0});
	near("conjugate pair, real part", r2[0], -1.0, 1.0e-12);
	near("conjugate pair, real part again", r2[1], -1.0, 1.0e-12);
	if(math->fabs(math->fabs(i2[0]) - 2.0) > 1.0e-12 ||
	   math->fabs(i2[0] + i2[1]) > 1.0e-12)
		fail(sys->sprint("the pair should be -1 +- 2i, and is %g%+gi, %g%+gi",
			r2[0], i2[0], r2[1], i2[1]));
	# a real root must come back exactly real, not with 1e-17 of
	# imaginary part: stable() looks at the sign of the real part and a
	# plot of the poles would show a pair where there is one
	(r3, i3, nil) := ctl->roots(array[] of {1.0, 6.0, 11.0, 6.0});
	for(i := 0; i < 3; i++)
		if(i3[i] != 0.0)
			fail(sys->sprint("a real root came back with an imaginary part of %g", i3[i]));
	# the roots of a polynomial are its roots: evaluate there
	for(i = 0; i < 3; i++)
		near(sys->sprint("p(root %d)", i),
			ctl->polyeval(array[] of {1.0, 6.0, 11.0, 6.0}, r3[i]), 0.0, 1.0e-10);
}

# routh() and stable() answer the same question from opposite ends.
# Neither is checked against a table: they are checked against each
# other, on polynomials random enough to include the awkward ones, and
# the count of how often the answer was `unstable' is printed so that a
# run where everything happened to be stable cannot pass for agreement.
stability()
{
	(nu, ns) := (0, 0);
	for(t := 0; t < 3000; t++){
		n := 2 + t%5;
		p := array[n+1] of real;
		for(i := 0; i <= n; i++)
			p[i] = rnd();
		if(p[0] == 0.0)
			p[0] = 1.0;
		(cnt, e1) := ctl->routh(p);
		tf := mk(array[] of {1.0}, p);
		if(tf == nil)
			continue;
		(st, e2) := ctl->stable(tf);
		if(e1 != nil || e2 != nil)
			continue;
		(re, nil, nil) := ctl->roots(p);
		rhp := 0;
		onaxis := 0;
		for(i = 0; i < len re; i++){
			if(re[i] > 1.0e-9)
				rhp++;
			else if(re[i] > -1.0e-9)
				onaxis++;
		}
		if(onaxis)
			continue;	# a root on the axis is neither, and Routh says so by a zero row
		if(cnt != rhp)
			fail(sys->sprint("Routh counted %d unstable roots and there are %d, "+
				"for a degree-%d polynomial", cnt, rhp, n));
		if(st != (rhp == 0))
			fail(sys->sprint("stable() said %d and there are %d unstable roots", st, rhp));
		if(rhp)
			nu++;
		else
			ns++;
	}
	if(verbose)
		sys->print("     Routh and the roots agree on %d stable and %d unstable\n",
			ns, nu);
	if(nu < 100 || ns < 100)
		fail(sys->sprint("only %d stable and %d unstable cases: the agreement "+
			"between Routh and the roots is not being tested on both", ns, nu));

	# Roots ON the imaginary axis, which the random sweep above skips
	# because they are neither stable nor unstable.  These are what
	# make a whole row of the Routh array zero, and the row must be
	# replaced by the derivative of the polynomial the row above stands
	# for.  The dodge used for a single zero - substituting a small
	# number - gives the WRONG COUNT here, which is how it is known
	# that the derivative branch is doing the work: without it these
	# four answer 3, 2, 3 and 3.
	axis := array[] of {
		("(s^2+1)(s+2)", array[] of {1.0, 2.0, 1.0, 2.0}, 0),
		("(s^2+1)(s-2)", array[] of {1.0, -2.0, 1.0, -2.0}, 1),
		("(s^2+4)(s^2+1)(s+1)", array[] of {1.0, 1.0, 5.0, 5.0, 4.0, 4.0}, 0),
		("(s^2+4)(s^2+1)(s-1)", array[] of {1.0, -1.0, 5.0, -5.0, 4.0, -4.0}, 1),
		("(s^2+1)(s+1)(s-3)", array[] of {1.0, -2.0, -2.0, -2.0, -3.0}, 1),
	};
	for(t = 0; t < len axis; t++){
		(nm, p, want) := axis[t];
		(got, e) := ctl->routh(p);
		if(e != nil)
			fail("Routh on " + nm + ": " + e);
		else if(got != want)
			fail(sys->sprint("%s has %d roots in the right half plane and Routh "+
				"counted %d", nm, want, got));
		# and the root finder must say the same, by construction
		(re, nil, nil) := ctl->roots(p);
		rhp := 0;
		for(i := 0; i < len re; i++)
			if(re[i] > 1.0e-9)
				rhp++;
		if(rhp != want)
			fail(sys->sprint("%s: the roots say %d in the right half plane, not %d",
				nm, rhp, want));
	}

	# the two awkward cases, by name.  s^3 + s = s(s^2+1) has a pair on
	# the imaginary axis, which makes a whole row of the Routh array
	# zero; s^4 + s^3 + s^2 + s + 1 has a zero in the first column
	# with a nonzero row beside it.
	(c1, e) := ctl->routh(array[] of {1.0, 0.0, 1.0, 0.0});
	if(e != nil)
		fail("a row of zeros should be handled, not refused: " + e);
	else if(c1 != 0)
		fail(sys->sprint("s^3+s has no roots in the right half plane, and Routh "+
			"counted %d", c1));
	(c2, e2) := ctl->routh(array[] of {1.0, 1.0, 1.0, 1.0, 1.0});
	(re2, nil, nil) := ctl->roots(array[] of {1.0, 1.0, 1.0, 1.0, 1.0});
	rhp2 := 0;
	for(i := 0; i < len re2; i++)
		if(re2[i] > 1.0e-9)
			rhp2++;
	if(e2 != nil)
		fail("a zero in the first column should be handled: " + e2);
	else if(c2 != rhp2)
		fail(sys->sprint("Routh counted %d and the roots say %d", c2, rhp2));
}

# The second-order step response, whose overshoot and peak time are the
# first two formulas in the subject.
responses()
{
	wn := 4.0;
	zs := array[] of {0.1, 0.3, 0.5, 0.707, 0.9};
	for(t := 0; t < len zs; t++){
		z := zs[t];
		sys2 := mk(array[] of {wn*wn}, array[] of {1.0, 2.0*z*wn, wn*wn});
		if(sys2 == nil)
			continue;
		dt := 0.001;
		n := 20000;
		(y, e) := ctl->stepresponse(sys2, dt, n);
		if(e != nil){
			fail("step: " + e);
			continue;
		}
		# against the closed form, at every sample
		wd := wn*math->sqrt(1.0 - z*z);
		worst := 0.0;
		for(i := 0; i < n; i++){
			tt := real i*dt;
			want := 1.0 - math->exp(-z*wn*tt)*(math->cos(wd*tt) +
				z*wn/wd*math->sin(wd*tt));
			d := math->fabs(y[i]-want);
			if(d > worst)
				worst = d;
		}
		if(worst > 1.0e-9)
			fail(sys->sprint("the step response at zeta=%g is off the closed "+
				"form by %g", z, worst));
		m := ctl->metrics(y, dt);
		os := math->exp(-math->Pi*z/math->sqrt(1.0-z*z));
		pt := math->Pi/wd;
		near(sys->sprint("overshoot at zeta=%.3f", z), m.overshoot, os, 2.0e-3);
		near(sys->sprint("peak time at zeta=%.3f", z), m.peakt, pt, 2.0*dt);
		# metrics() takes the final value as the average of the last
		# tenth, so a lightly damped system is still ringing inside
		# the window it averages: the tolerance is that ringing, which
		# is a number and not a guess
		ring := 2.0*math->exp(-z*wn*0.9*real n*dt);
		if(ring < 1.0e-12)
			ring = 1.0e-12;	# no check can be tighter than the arithmetic
		near(sys->sprint("final value at zeta=%.3f", z), m.final, 1.0, ring);
		if(verbose)
			sys->print("     zeta=%.3f  step error %.3g, overshoot %.4f (want %.4f)\n",
				z, worst, m.overshoot, os);
	}

	# WHETHER IT FINISHED.  Every number metrics() gives but one is
	# computed from the final value, and the final value is the average
	# of the last tenth of the record - so a run that stops before the
	# response settles reports a final value that is merely where the
	# curve happened to be.  This system oscillates with a period of
	# about 6.5 s; sampled for 4 s it reports an overshoot of 0.037,
	# and sampled for 40 s the same system reports 0.139.  The flag is
	# what tells the two apart, and without it nothing here could.
	slow := mk(array[] of {0.52, 2.03, 3.0},
		array[] of {0.01, 1.03, 3.54, 4.03, 3.0});
	if(slow != nil){
		(ys, es) := ctl->stepresponse(slow, 0.002, 2000);
		if(es != nil)
			fail("slow step: " + es);
		else {
			ms := ctl->metrics(ys, 0.002);
			if(ms.settled)
				fail(sys->sprint("four seconds is two thirds of one oscillation "+
					"of this loop and it claims to have settled, reporting a "+
					"final value of %g and an overshoot of %g",
					ms.final, ms.overshoot));
		}
		(yl, nil) := ctl->stepresponse(slow, 0.002, 20000);
		ml := ctl->metrics(yl, 0.002);
		if(!ml.settled)
			fail("forty seconds is six oscillations and it has certainly settled");
		else {
			near("and then the final value is one", ml.final, 1.0, 1.0e-6);
			near("and the overshoot is the real one", ml.overshoot, 0.1395, 1.0e-3);
		}
		# the short run's overshoot really is wrong, which is the whole
		# reason the flag exists; if it were right the flag would be
		# pointless
		(ys2, nil) := ctl->stepresponse(slow, 0.002, 2000);
		ms2 := ctl->metrics(ys2, 0.002);
		if(math->fabs(ms2.overshoot - ml.overshoot) < 0.05)
			fail("the short run's overshoot is meant to be badly wrong, and it "+
				"agrees with the long run's, so this checks nothing");
	}
	# a well-damped system settles quickly and must say so
	quick := mk(array[] of {1.0}, array[] of {1.0, 2.0, 1.0});
	if(quick != nil){
		(yq, nil) := ctl->stepresponse(quick, 0.01, 4000);
		mq := ctl->metrics(yq, 0.01);
		if(!mq.settled)
			fail("a critically damped first-order-squared lag settles long "+
				"before forty seconds");
	}

	# a first-order lag: the step response is 1-exp(-t/tau) and the
	# impulse response is its derivative
	tau := 0.4;
	lag := mk(array[] of {1.0}, array[] of {tau, 1.0});
	(y, nil) := ctl->stepresponse(lag, 0.002, 2000);
	worst := 0.0;
	for(i := 0; i < 2000; i++){
		d := math->fabs(y[i] - (1.0 - math->exp(-real i*0.002/tau)));
		if(d > worst)
			worst = d;
	}
	if(worst > 1.0e-11)
		fail(sys->sprint("the first-order step is off 1-exp(-t/tau) by %g", worst));
	(h, nil) := ctl->impulseresponse(lag, 0.002, 2000);
	worst = 0.0;
	for(i = 0; i < 2000; i++){
		d := math->fabs(h[i] - math->exp(-real i*0.002/tau)/tau);
		if(d > worst)
			worst = d;
	}
	if(worst > 1.0e-10)
		fail(sys->sprint("the first-order impulse is off exp(-t/tau)/tau by %g", worst));
	else if(verbose)
		sys->print("     first order: step %.3g, impulse %.3g\n", worst, worst);

	# A system whose numerator has the SAME degree as its denominator
	# has a direct path from input to output, and the state-space form
	# has to subtract that path out of the output matrix.  Every other
	# system tested here is strictly proper, where the correction is
	# multiplied by zero and cannot be seen at all.  (s+1)/(s+2) has
	# the step response 1/2 + exp(-2t)/2, which starts at 1 and not 0.
	ff := mk(array[] of {1.0, 1.0}, array[] of {1.0, 2.0});
	(yf, ef) := ctl->stepresponse(ff, 0.002, 2000);
	if(ef != nil)
		fail("direct feedthrough: " + ef);
	else {
		worst = 0.0;
		for(i = 0; i < 2000; i++){
			d := math->fabs(yf[i] - (0.5 + 0.5*math->exp(-2.0*real i*0.002)));
			if(d > worst)
				worst = d;
		}
		if(worst > 1.0e-11)
			fail(sys->sprint("the step response of (s+1)/(s+2) is off "+
				"1/2+exp(-2t)/2 by %g", worst));
		near("and it starts at one, not zero", yf[0], 1.0, 1.0e-15);
		# heading for a half, but exp(-2t) at t=4 is still 3.4e-4 of
		# it, so the number to compare with is the closed form and not
		# the limit
		near("and heads for a half", yf[1999],
			0.5 + 0.5*math->exp(-2.0*1999.0*0.002), 1.0e-11);
	}

	# lsim with a step must equal stepresponse, or one of them is
	# taking the input differently from the other
	u := array[500] of real;
	for(i = 0; i < 500; i++)
		u[i] = 1.0;
	(y2, nil) := ctl->lsim(lag, u, 0.002);
	(y3, nil) := ctl->stepresponse(lag, 0.002, 500);
	worst = 0.0;
	for(i = 0; i < 500; i++){
		d := math->fabs(y2[i]-y3[i]);
		if(d > worst)
			worst = d;
	}
	if(worst != 0.0)
		fail(sys->sprint("lsim of a step and stepresponse differ by %g", worst));
}

frequency()
{
	# an integrator: exactly 1/w in magnitude and exactly -90 degrees,
	# at every frequency
	integ := mk(array[] of {1.0}, array[] of {1.0, 0.0});
	w := array[] of {0.01, 0.1, 1.0, 10.0, 100.0};
	(m, p) := ctl->bode(integ, w);
	for(i := 0; i < len w; i++){
		near(sys->sprint("integrator |H| at w=%g", w[i]), m[i], 1.0/w[i], 1.0e-14);
		near(sys->sprint("integrator phase at w=%g", w[i]), p[i], -math->Pi/2.0, 1.0e-14);
	}
	# a first-order lag is -3 dB at 1/tau and falls at 20 dB a decade
	tau := 0.25;
	lag := mk(array[] of {1.0}, array[] of {tau, 1.0});
	w2 := array[] of {1.0/tau, 100.0/tau, 1000.0/tau};
	(m2, p2) := ctl->bode(lag, w2);
	near("a lag at its corner", m2[0], 1.0/math->sqrt(2.0), 1.0e-14);
	near("a lag's phase at its corner", p2[0], -math->Pi/4.0, 1.0e-14);
	# ten is the ASYMPTOTE.  The response itself is 1/sqrt(1+(w tau)^2),
	# so a decade from w tau = 100 to 1000 is sqrt(1000001/10001) =
	# 9.99950, and checking it against 10 would be checking the
	# straight-line approximation a Bode plot draws rather than the
	# filter.
	exact := math->sqrt((1.0 + 1000.0*1000.0)/(1.0 + 100.0*100.0));
	near("a decade of roll-off", m2[1]/m2[2], exact, 1.0e-12);
	if(math->fabs(exact - 10.0) < 1.0e-6)
		fail("the exact ratio and the asymptote are indistinguishable here, "+
			"so this does not test which one is computed");

	# the phase is unwrapped: a third-order lag reaches -270 degrees and
	# must not come back as +90
	third := mk(array[] of {1.0}, array[] of {1.0, 3.0, 3.0, 1.0});
	wf := array[400] of real;
	for(i = 0; i < 400; i++)
		wf[i] = math->pow(10.0, -2.0 + 5.0*real i/399.0);
	(nil, p3) := ctl->bode(third, wf);
	near("three lags end at -270 degrees", p3[399], -3.0*math->Pi/2.0, 0.02);
	for(i = 1; i < 400; i++)
		if(p3[i] > p3[i-1] + 1.0e-9){
			fail(sys->sprint("the phase went back up at w=%g: it is not unwrapped",
				wf[i]));
			break;
		}
}

# A loop, its margins, and the thing every course opens with: for
# k/(s(s+1)(s+2)), the closed loop is stable up to exactly k=6, which is
# Routh's answer and can be checked against the roots.
loops()
{
	plant := mk(array[] of {1.0}, array[] of {1.0, 3.0, 2.0, 0.0});
	one := mk(array[] of {1.0}, array[] of {1.0});
	for(t := 0; t < 3; t++){
		k := array[] of {5.0, 6.0, 7.0};
		g := mk(array[] of {k[t]}, array[] of {1.0, 3.0, 2.0, 0.0});
		(cl, e) := ctl->feedback(g, one, -1);
		if(e != nil){
			fail("feedback: " + e);
			continue;
		}
		# 1 + k/(s^3+3s^2+2s) = 0 is s^3+3s^2+2s+k, stable for 0<k<6
		(st, nil) := ctl->stable(cl);
		want := 0;
		if(k[t] < 6.0)
			want = 1;
		if(st != want)
			fail(sys->sprint("with k=%g the closed loop should be %d and is %d",
				k[t], want, st));
	}
	# at k=6 exactly the poles sit on the imaginary axis at sqrt(2),
	# which is where it oscillates, and that is also the gain margin
	# of the k=1 loop: 6.
	(mm, e) := ctl->margins(plant);
	if(e != nil)
		fail("margins: " + e);
	else {
		if(!mm.hasgain)
			fail("this loop does have a phase crossover and a gain margin");
		else {
			near("the gain margin", mm.gain, 6.0, 1.0e-3);
			near("at the frequency it oscillates", mm.gainw, math->sqrt(2.0), 1.0e-3);
		}
		if(!mm.hasphase)
			fail("this loop does have a gain crossover and a phase margin");
		else if(verbose)
			sys->print("     phase margin %.4g degrees at w=%.4g\n",
				mm.phase*180.0/math->Pi, mm.phasew);
	}
	# an integrator alone never reaches -180 degrees, so it has no gain
	# margin at all - which is not the same as a large one, and is why
	# there is a flag rather than a big number
	integ := mk(array[] of {1.0}, array[] of {1.0, 0.0});
	(m2, nil) := ctl->margins(integ);
	if(m2 != nil && m2.hasgain)
		fail("an integrator's phase is -90 everywhere and it has no gain margin");

	# series and parallel, checked by evaluating rather than by
	# inspecting coefficients
	a := mk(array[] of {1.0, 1.0}, array[] of {1.0, 2.0});
	b := mk(array[] of {3.0}, array[] of {1.0, 0.0, 4.0});
	s := ctl->series(a, b);
	p := ctl->parallel(a, b);
	for(t = 0; t < 5; t++){
		x := 0.7 + real t;
		av := ctl->polyeval(a.num, x)/ctl->polyeval(a.den, x);
		bv := ctl->polyeval(b.num, x)/ctl->polyeval(b.den, x);
		near(sys->sprint("series at s=%g", x),
			ctl->polyeval(s.num, x)/ctl->polyeval(s.den, x), av*bv, 1.0e-12);
		near(sys->sprint("parallel at s=%g", x),
			ctl->polyeval(p.num, x)/ctl->polyeval(p.den, x), av+bv, 1.0e-12);
	}
	# A PD CONTROLLER, which is a PID with no integral term and was
	# the case nothing here tested.  Building it over the common
	# denominator s(taud s + 1) leaves a factor of s in the numerator
	# too, and nothing downstream cancels it: the controller comes back
	# with a pole at the origin, stable() calls every loop containing
	# it unstable, and the step response is wrong.  Found by using the
	# library rather than by testing it - lib/demo/pidlab.sh reported
	# UNSTABLE for an ordinary PD loop.
	(pd, epd) := ctl->pid(2.0, 0.0, 0.5, 0.01);
	if(epd != nil)
		fail("a PD controller is a normal thing to want: " + epd);
	else {
		(pre, nil, nil) := ctl->poles(pd);
		for(t = 0; t < len pre; t++)
			if(math->fabs(pre[t]) < 1.0e-9)
				fail("a PD controller has no pole at the origin - it has no "+
					"integral term - and one has been left there uncancelled");
		near("a PD controller's DC gain is kp", pd.dcgain(), 2.0, 1.0e-12);
		for(t = 0; t < 5; t++){
			x := 0.3 + real t;
			want := 2.0 + 0.5*x/(0.01*x + 1.0);
			near(sys->sprint("pd at s=%g", x),
				ctl->polyeval(pd.num, x)/ctl->polyeval(pd.den, x), want, 1.0e-10);
		}
		# and a loop closed round it is stable, which is the symptom
		lp := ctl->series(pd, mk(array[] of {1.0}, array[] of {1.0, 3.0, 2.0}));
		(cl, ecl) := ctl->feedback(lp, one, -1);
		if(ecl != nil)
			fail("closing a PD loop: " + ecl);
		else {
			(st, nil) := ctl->stable(cl);
			if(!st)
				fail("a PD controller on a stable plant, closed with unity "+
					"feedback, is a stable loop, and it was called unstable");
		}
	}
	# proportional only, and proportional-integral, which the general
	# case also has to get right
	(po, nil) := ctl->pid(3.0, 0.0, 0.0, 0.0);
	if(po != nil){
		near("a P controller is a constant", po.dcgain(), 3.0, 1.0e-14);
		if(po.order() != 0)
			fail("a P controller has no dynamics at all");
	}
	(pinteg, nil) := ctl->pid(2.0, 5.0, 0.0, 0.0);
	if(pinteg != nil){
		(pre2, nil, nil) := ctl->poles(pinteg);
		found := 0;
		for(t = 0; t < len pre2; t++)
			if(math->fabs(pre2[t]) < 1.0e-12)
				found = 1;
		if(!found)
			fail("a PI controller DOES have a pole at the origin - that is what "+
				"the integral term is - and it is missing");
	}

	# a PID controller is what its parts say it is
	(c, ep) := ctl->pid(2.0, 3.0, 0.5, 0.01);
	if(ep != nil)
		fail("pid: " + ep);
	else
		for(t = 0; t < 5; t++){
			x := 0.3 + real t;
			want := 2.0 + 3.0/x + 0.5*x/(0.01*x + 1.0);
			near(sys->sprint("pid at s=%g", x),
				ctl->polyeval(c.num, x)/ctl->polyeval(c.den, x), want, 1.0e-10);
		}
}

# The same RC circuit a third way.  circuit(2) integrates the network,
# signal(2) filters the samples, and control(2) integrates the transfer
# function - three independent pieces of code for one first-order lag.
# They are compared against the exponential rather than against each
# other, since each has its own step size and its own error.
rcplant()
{
	(r, c) := (1000.0, 1.0e-6);
	tau := r*c;
	dt := tau/50.0;
	n := 300;
	lag := mk(array[] of {1.0}, array[] of {tau, 1.0});
	if(lag == nil)
		return;
	(y, e) := ctl->stepresponse(lag, dt, n);
	if(e != nil){
		fail("rc plant: " + e);
		return;
	}
	(nl, err) := ckt->parse("V1 in 0 1\nR1 in out 1k\nC1 out 0 1u\n.tran 1u 1m\n");
	if(err != nil){
		fail("rc plant netlist: " + err);
		return;
	}
	ckt->begin(nl);
	(wc, wt) := (0.0, 0.0);
	for(i := 0; i < n; i++){
		if(i > 0)
			ckt->step(nl, dt);
		want := 1.0 - math->exp(-real i*dt/tau);
		d := math->fabs(y[i] - want);
		if(d > wt)
			wt = d;
		d = math->fabs(ckt->nodev(nl, "out") - want);
		if(d > wc)
			wc = d;
	}
	if(wt > 1.0e-10)
		fail(sys->sprint("control(2)'s lag is %g from the exponential", wt));
	if(wc > 1.0e-4)
		fail(sys->sprint("circuit(2)'s RC is %g from the exponential", wc));
	if(verbose)
		sys->print("     the same RC: control(2) %.3g, circuit(2) %.3g from exp\n",
			wt, wc);
	# and the transfer function's own DC gain and corner agree with the
	# circuit's: a divider of one resistor and an open capacitor
	near("the lag's DC gain", lag.dcgain(), 1.0, 1.0e-15);
	(m, nil) := ctl->bode(lag, array[] of {1.0/tau});
	near("the lag's corner is -3 dB", m[0], 1.0/math->sqrt(2.0), 1.0e-14);
}

refusals()
{
	(nil, e1) := ctl->tf(array[] of {1.0}, array[] of {0.0});
	if(e1 == nil)
		fail("a zero denominator should be refused");
	(nil, e2) := ctl->tf(array[] of {1.0, 0.0, 0.0}, array[] of {1.0, 1.0});
	if(e2 == nil)
		fail("a numerator of higher degree than the denominator should be refused");
	(nil, e3) := ctl->tf(array[] of {1.0}, array[] of {1.0, 1.0});
	if(e3 != nil)
		fail("a good transfer function was refused: " + e3);
	(nil, e4) := ctl->pid(1.0, 1.0, 1.0, 0.0);
	if(e4 == nil)
		fail("a derivative term without a filter is not proper and should be refused");
	(nil, e5) := ctl->pid(1.0, 1.0, 0.0, 0.0);
	if(e5 != nil)
		fail("a PI controller needs no filter and should not be refused: " + e5);
	# an impulse response that would contain a delta
	t := mk(array[] of {1.0, 1.0}, array[] of {1.0, 2.0});
	(nil, e6) := ctl->impulseresponse(t, 0.01, 10);
	if(e6 == nil)
		fail("an impulse response with a delta in it should be refused, not "+
			"returned with the delta missing");
	(nil, e7) := ctl->stepresponse(t, 0.01, 10);
	if(e7 != nil)
		fail("the STEP response of the same system is perfectly finite: " + e7);
	(nil, nil, e8) := ctl->roots(array[] of {0.0, 0.0});
	if(e8 == nil)
		fail("a polynomial that is identically zero has no roots to find");
}
