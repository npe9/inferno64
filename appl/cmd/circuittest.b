implement Circuittest;

# circuittest - check circuit(2) against the answers a textbook gives
#
# Every circuit here has a closed form, which is the point: a divider is
# a ratio, an RC step is an exponential, a series RLC is a damped
# sinusoid whose frequency and decay are both known.  Nothing is checked
# against a previous run of this program.
#
# The controls are the half that matters.  A solver that answered
# anything at all for a circuit with no answer - a node floating with
# nothing to hold it, two voltage sources argued across each other -
# would pass every positive check here while being useless, so both are
# required to be refused.

include "sys.m";
	sys: Sys;
include "draw.m";
include "math.m";
	math: Math;
include "circuit.m";
	ckt: Circuit;
	Net: import ckt;

Circuittest: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

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
	if(d > tol)
		fail(sys->sprint("%s: got %.10g want %.10g", what, got, want));
	else if(verbose)
		sys->print("     %s: %.8g\n", what, got);
}

build(spec: string): ref Net
{
	(n, err) := ckt->parse(spec);
	if(err != nil){
		fail("parse: " + err);
		return nil;
	}
	return n;
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	ckt = load Circuit Circuit->PATH;
	if(math == nil || ckt == nil){
		sys->print("FAIL load: %r\n");
		raise "fail:load";
	}
	ckt->init();
	for(a := tl argv; a != nil; a = tl a)
		if(hd a == "-v")
			verbose = 1;

	# a divider is a ratio and nothing else
	n := build("V1 in 0 10\nR1 in mid 1k\nR2 mid 0 3k\n.dc\n");
	if(n != nil){
		e := ckt->dc(n);
		if(e != nil)
			fail("divider: " + e);
		else {
			near("divider node", ckt->nodev(n, "mid"), 7.5, 1.0e-12);
			# and the current is the same everywhere in a series loop
			near("divider current through R1", ckt->parti(n, "R1"), 10.0/4000.0, 1.0e-15);
			near("divider current through R2", ckt->parti(n, "R2"), 10.0/4000.0, 1.0e-15);
			near("the source carries it too", ckt->parti(n, "V1"), -10.0/4000.0, 1.0e-15);
		}
	}

	# a current source pushes its current whatever is in the way
	n = build("I1 0 out 1m\nR1 out 0 2k\n.dc\n");
	if(n != nil && ckt->dc(n) == nil)
		near("current source into 2k", ckt->nodev(n, "out"), 2.0, 1.0e-12);

	# at DC a capacitor is open and an inductor is a short, so this
	# divider ignores the capacitor entirely and shorts out R3
	n = build("V1 in 0 12\nR1 in mid 2k\nR2 mid 0 2k\nC1 mid 0 10u\n" +
		"R3 mid low 1k\nL1 low 0 1m\n.dc\n");
	if(n != nil){
		e := ckt->dc(n);
		if(e != nil)
			fail("dc storage: " + e);
		else {
			# R2 parallel R3 (the inductor shorts R3's far end) = 666.67
			rp := 1.0/(1.0/2000.0 + 1.0/1000.0);
			near("capacitor open, inductor short",
				ckt->nodev(n, "mid"), 12.0*rp/(2000.0+rp), 1.0e-9);
			near("the inductor's far node is grounded through it",
				ckt->nodev(n, "low"), 0.0, 1.0e-12);
		}
	}

	# RC step: v(t) = V(1 - exp(-t/RC)), which is the first thing
	# anybody computes about a circuit
	rcstep();
	# RL step: i(t) = (V/R)(1 - exp(-tR/L))
	rlstep();
	# series RLC, underdamped: a damped sinusoid with a known frequency
	rlcring();
	# a circuit that starts with something already stored.  These
	# matter more than they look: at rest the inductor's initial-
	# condition stamp is a current source of zero amps and the
	# capacitor's is a source of zero volts, so a SIGN error in either
	# is invisible to every test above.  Only a nonzero initial
	# condition can see it, and both of these are large and signed.
	decays();
	# trapezoidal really is better than backward Euler, measured, for
	# both kinds of storage element
	methods();

	# THE CONTROLS.  A circuit with no answer must be refused.
	n = build("V1 in 0 5\nR1 in mid 1k\nC1 far 0 1u\n.dc\n");
	if(n != nil){
		e := ckt->dc(n);
		if(e == nil)
			fail("a node with nothing to hold it should have no answer, " +
				"but the solve returned one");
		else if(verbose)
			sys->print("     floating node refused: %s\n", e);
	}
	n = build("V1 a 0 5\nV2 a 0 7\nR1 a 0 1k\n.dc\n");
	if(n != nil){
		e := ckt->dc(n);
		if(e == nil)
			fail("two sources disagreeing across one pair of nodes should " +
				"have no answer, but the solve returned one");
	}
	# and a circuit that DOES have an answer is not refused, or the two
	# checks above would pass on a solver that refused everything
	n = build("V1 a 0 5\nR1 a 0 1k\n.dc\n");
	if(n != nil && ckt->dc(n) != nil)
		fail("a circuit with an answer was refused, so the refusals prove nothing");

	# the netlist language says what it will not accept
	(nil, e1) := ckt->parse("X1 a b 1k\n");
	if(e1 == nil)
		fail("a component whose name says it is nothing should be refused");
	# SPICE's suffixes, including the one that catches everyone: M is
	# milli.  Checked by measurement, not by reading the table - a
	# 1 ohm resistor across a 1M amp source is 1mV or 1MV and there is
	# no mistaking which.
	sufs := array[] of {("1m", 1.0e-3), ("1meg", 1.0e6), ("1M", 1.0e-3),
		("1MEG", 1.0e6), ("1k", 1.0e3), ("1kohm", 1.0e3), ("1u", 1.0e-6),
		("1mH", 1.0e-3), ("1", 1.0)};
	for(si := 0; si < len sufs; si++){
		(txt, want) := sufs[si];
		sn := build(sys->sprint("I1 0 out %s\nR1 out 0 1\n.dc\n", txt));
		if(sn != nil && ckt->dc(sn) == nil)
			near("suffix " + txt, ckt->nodev(sn, "out"), want, 1.0e-9*want);
	}
	(nil, e2) := ckt->parse("R1 a b 1q\n");
	if(e2 == nil)
		fail("a value with a suffix that means nothing should be refused");
	(nil, e3) := ckt->parse("R1 a b 1k\n");
	if(e3 != nil)
		fail("a good netlist was refused: " + e3);

	if(nfail == 0)
		sys->print("OK   circuit(2) against the closed forms\n");
	else {
		sys->print("%d failures\n", nfail);
		raise "fail:circuittest";
	}
}

rcstep()
{
	(r, c, v) := (1000.0, 1.0e-6, 5.0);
	tau := r*c;
	n := build(sys->sprint("V1 in 0 %g\nR1 in out %g\nC1 out 0 %g\n.tran %g %g\n",
		v, r, c, tau/200.0, 5.0*tau));
	if(n == nil)
		return;
	ckt->begin(n);
	h := tau/200.0;
	worst := 0.0;
	for(i := 1; i <= 1000; i++){
		e := ckt->step(n, h);
		if(e != nil){
			fail("rc step: " + e);
			return;
		}
		t := real i*h;
		want := v*(1.0 - math->exp(-t/tau));
		d := math->fabs(ckt->nodev(n, "out") - want);
		if(d > worst)
			worst = d;
	}
	if(worst > 1.0e-4)
		fail(sys->sprint("RC step: worst error %g over five time constants", worst));
	else if(verbose)
		sys->print("     RC step worst error %g\n", worst);
}

rlstep()
{
	(r, l, v) := (100.0, 0.01, 5.0);
	tau := l/r;
	n := build(sys->sprint("V1 in 0 %g\nR1 in mid %g\nL1 mid 0 %g\n.tran %g %g\n",
		v, r, l, tau/200.0, 5.0*tau));
	if(n == nil)
		return;
	ckt->begin(n);
	h := tau/200.0;
	worst := 0.0;
	for(i := 1; i <= 1000; i++){
		if(ckt->step(n, h) != nil){
			fail("rl step");
			return;
		}
		t := real i*h;
		want := v/r*(1.0 - math->exp(-t/tau));
		d := math->fabs(ckt->parti(n, "L1") - want);
		if(d > worst)
			worst = d;
	}
	if(worst > 1.0e-5)
		fail(sys->sprint("RL step: worst current error %g", worst));
	else if(verbose)
		sys->print("     RL step worst error %g\n", worst);
}

# Series RLC driven by a step.  Underdamped, so the capacitor voltage is
# V(1 - exp(-at)(cos wd t + (a/wd) sin wd t)) with a = R/2L and
# wd = sqrt(1/LC - a^2).  Both the ringing frequency and the decay are
# checked, because a scheme can get one and not the other - backward
# Euler gets the frequency about right and damps far too fast.
rlcring()
{
	(r, l, c, v) := (20.0, 1.0e-3, 1.0e-6, 1.0);
	a := r/(2.0*l);
	w0sq := 1.0/(l*c);
	wd := math->sqrt(w0sq - a*a);
	n := build(sys->sprint("V1 in 0 %g\nR1 in mid %g\nL1 mid out %g\nC1 out 0 %g\n" +
		".tran 1e-7 2e-3\n", v, r, l, c));
	if(n == nil)
		return;
	ckt->begin(n);
	h := 1.0e-7;
	worst := 0.0;
	for(i := 1; i <= 20000; i++){
		if(ckt->step(n, h) != nil){
			fail("rlc step");
			return;
		}
		t := real i*h;
		want := v*(1.0 - math->exp(-a*t)*(math->cos(wd*t) + a/wd*math->sin(wd*t)));
		d := math->fabs(ckt->nodev(n, "out") - want);
		if(d > worst)
			worst = d;
	}
	if(worst > 2.0e-3)
		fail(sys->sprint("RLC ringing: worst error %g against the damped sinusoid", worst));
	else if(verbose)
		sys->print("     RLC worst error %g (wd = %g rad/s)\n", worst, wd);
}

# An inductor with current already in it, and a capacitor with charge
# already on it, each emptying into a resistor.  Both decay as
# exp(-t/tau) from a value the netlist states.
#
# The inductive kick is the interesting half: 1 A through L1 into a 100
# ohm resistor puts -100 V across it at t=0, from a 0 V circuit.  A
# stamp with the wrong sign puts +100 V there instead, which is a number
# no later average could hide.
decays()
{
	(r, l, i0) := (100.0, 0.01, 1.0);
	tau := l/r;
	n := build(sys->sprint("R1 a 0 %g\nL1 a 0 %g\n.ic L1 %g\n.tran 1u 1m\n",
		r, l, i0));
	if(n == nil)
		return;
	if(ckt->begin(n) != nil){
		fail("inductive kick: begin");
		return;
	}
	near("the kick at t=0", ckt->nodev(n, "a"), -i0*r, 1.0e-9);
	h := tau/200.0;
	worst := 0.0;
	for(k := 1; k <= 1000; k++){
		if(ckt->step(n, h) != nil){
			fail("inductive kick: step");
			return;
		}
		want := i0*math->exp(-real k*h/tau);
		d := math->fabs(ckt->parti(n, "L1") - want);
		if(d > worst)
			worst = d;
	}
	if(worst > 1.0e-6)
		fail(sys->sprint("inductor decay: worst current error %g", worst));
	else if(verbose)
		sys->print("     inductor decay worst error %g\n", worst);

	(rc, c, v0) := (1000.0, 1.0e-6, 2.0);
	tauc := rc*c;
	n = build(sys->sprint("R1 a 0 %g\nC1 a 0 %g\n.ic C1 %g\n.tran 1u 5m\n",
		rc, c, v0));
	if(n == nil)
		return;
	ckt->begin(n);
	near("the charge is there before anything moves", ckt->nodev(n, "a"), v0, 1.0e-12);
	near("and it is already flowing out", ckt->parti(n, "C1"), -v0/rc, 1.0e-12);
	h = tauc/200.0;
	worst = 0.0;
	for(k = 1; k <= 1000; k++){
		ckt->step(n, h);
		want := v0*math->exp(-real k*h/tauc);
		d := math->fabs(ckt->nodev(n, "a") - want);
		if(d > worst)
			worst = d;
	}
	# relative to the initial value, because that is what trapezoidal
	# truncation scales with: this run and the inductor's above differ
	# by exactly the factor 2 between their initial values
	if(worst/v0 > 1.0e-6)
		fail(sys->sprint("capacitor discharge: worst error %g of %g", worst, v0));
	else if(verbose)
		sys->print("     capacitor discharge worst error %g (%g relative)\n",
			worst, worst/v0);

	# beginfromdc() starts where the circuit already is, so nothing
	# moves: a steady state stepped forward stays put.  This is the
	# only test that drives icpoint() with a nonzero inductor current
	# AND a nonzero capacitor voltage at once.
	n = build("V1 in 0 5\nR1 in mid 100\nC1 mid 0 1u\nR2 mid out 50\nL1 out 0 1m\n" +
		".tran 1u 1m\n");
	if(n == nil)
		return;
	if(ckt->beginfromdc(n) != nil){
		fail("beginfromdc");
		return;
	}
	# mid is the divider, the inductor shorting out the far end of R2
	vmid := 5.0*50.0/150.0;
	near("steady state before stepping", ckt->nodev(n, "mid"), vmid, 1.0e-12);
	near("the inductor carries it", ckt->parti(n, "L1"), vmid/50.0, 1.0e-12);
	for(k = 1; k <= 200; k++)
		ckt->step(n, 1.0e-6);
	near("and after 200 steps it has not moved", ckt->nodev(n, "mid"), vmid, 1.0e-9);
	near("nor has the current", ckt->parti(n, "L1"), vmid/50.0, 1.0e-9);

	# .ic says what it will not accept
	(nil, e) := ckt->parse("R1 a 0 1k\n.ic R1 5\n");
	if(e == nil)
		fail("a resistor stores nothing and .ic on one should be refused");
	(nil, e2) := ckt->parse("C1 a 0 1u\nR1 a 0 1k\n.ic C2 5\n");
	if(e2 == nil)
		fail(".ic naming a part that is not there should be refused");
	(nil, e3) := ckt->parse("C1 a 0 1u\nR1 a 0 1k\n.ic C1 5\n");
	if(e3 != nil)
		fail("a good .ic was refused: " + e3);
}

# The two integration rules do not agree, and the one the library
# defaults to is the better one.  Checked rather than asserted.
methods()
{
	(r, c, v) := (1000.0, 1.0e-6, 5.0);
	tau := r*c;
	h := tau/20.0;			# deliberately coarse, so they differ
	es := array[2] of real;
	ms := array[] of {"trap", "be"};
	for(k := 0; k < 2; k++){
		n := build(sys->sprint("V1 in 0 %g\nR1 in out %g\nC1 out 0 %g\n" +
			".method %s\n.tran %g %g\n", v, r, c, ms[k], h, 5.0*tau));
		if(n == nil)
			return;
		ckt->begin(n);
		worst := 0.0;
		for(i := 1; i <= 100; i++){
			ckt->step(n, h);
			t := real i*h;
			want := v*(1.0 - math->exp(-t/tau));
			d := math->fabs(ckt->nodev(n, "out") - want);
			if(d > worst)
				worst = d;
		}
		es[k] = worst;
	}
	if(verbose)
		sys->print("     at h = tau/20: trapezoidal %g, backward Euler %g\n",
			es[0], es[1]);
	if(es[0] >= es[1])
		fail(sys->sprint("trapezoidal (%g) is no better than backward Euler "+
			"(%g), and it is the default because it should be", es[0], es[1]));
	if(es[1] < 1.0e-6)
		fail(sys->sprint("backward Euler's error is only %g at this step, so "+
			"the comparison proves nothing", es[1]));

	# and the same for the inductor, whose backward-Euler companion is
	# a different expression and was covered by nothing above
	(rl, l) := (100.0, 0.01);
	taul := l/rl;
	hl := taul/20.0;
	for(k = 0; k < 2; k++){
		n := build(sys->sprint("R1 a 0 %g\nL1 a 0 %g\n.ic L1 1\n.method %s\n" +
			".tran %g %g\n", rl, l, ms[k], hl, 5.0*taul));
		if(n == nil)
			return;
		ckt->begin(n);
		worst := 0.0;
		for(i := 1; i <= 100; i++){
			ckt->step(n, hl);
			want := math->exp(-real i*hl/taul);
			d := math->fabs(ckt->parti(n, "L1") - want);
			if(d > worst)
				worst = d;
		}
		es[k] = worst;
	}
	if(verbose)
		sys->print("     inductor at h = tau/20: trapezoidal %g, backward Euler %g\n",
			es[0], es[1]);
	if(es[0] >= es[1])
		fail(sys->sprint("for the inductor too, trapezoidal (%g) must beat "+
			"backward Euler (%g)", es[0], es[1]));
	if(es[1] < 1.0e-6)
		fail(sys->sprint("the inductor's backward-Euler error is only %g, so "+
			"that comparison proves nothing", es[1]));
}
