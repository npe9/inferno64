implement Thermotest;

# thermotest - check thermo(2) against the identities and the efficiencies
#
# Thermodynamics is unusually well supplied with things that must be
# EXACTLY true rather than approximately so, and those are what is
# checked here:
#
#	cp - cv = R			a relation, not a definition
#	du = q - w			on every process, each computed
#					independently of the others
#	wnet = qin - qout		around every cycle
#	sum of q/T = 0			around a reversible cycle
#	Carnot is 1 - Tc/Th		and nothing can beat it
#	Otto is 1 - r^(1-gamma)		whatever heat is added
#
# The heat exchanger is checked by working it out twice: the log mean
# temperature difference and the effectiveness-NTU relation are
# different pieces of arithmetic for one duty, and they must agree.

include "sys.m";
	sys: Sys;
include "draw.m";
include "math.m";
	math: Math;
include "thermo.m";
	th: Thermo;
	Gas, State, Change, Cycle, VdW: import th;

Thermotest: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

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
		fail(sys->sprint("%s: got %.12g want %.12g", what, got, want));
	else if(verbose)
		sys->print("     %s: %.10g\n", what, got);
}

rel(what: string, got, want, tol: real)
{
	s := want;
	if(s < 0.0)
		s = -s;
	if(s == 0.0)
		s = 1.0;
	near(what, got, want, tol*s);
}

air: ref Gas;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	th = load Thermo Thermo->PATH;
	if(th == nil || math == nil){
		sys->print("FAIL load: %r\n");
		raise "fail:load";
	}
	th->init();
	air = th->air();
	for(a := tl argv; a != nil; a = tl a)
		if(hd a == "-v")
			verbose = 1;

	gases();
	processes();
	cycles();
	realgas();
	exchangers();
	refusals();

	if(nfail == 0)
		sys->print("OK   thermo(2) against the identities\n");
	else {
		sys->print("%d failures\n", nfail);
		raise "fail:thermotest";
	}
}

gases()
{
	near("air's gas constant", air.r, 8314.462618/28.9647, 1.0e-9);
	near("cp - cv is R, exactly", air.cp - air.cv, air.r, 1.0e-10);
	near("and gamma is cp over cv", air.gamma(), 1.4, 1.0e-14);
	# air's cp is about 1005 J/kg K, which is the number in every table
	rel("air's cp", air.cp, 1004.7, 2.0e-3);
	# the two constructors must agree: a gas built from cp and the same
	# gas built from gamma are the same gas
	(g2, e) := th->fromcp("air", 28.9647, air.cp);
	if(e != nil)
		fail("fromcp: " + e);
	else {
		near("built from cp, the same cv", g2.cv, air.cv, 1.0e-10);
		near("and the same gamma", g2.gamma(), air.gamma(), 1.0e-14);
	}
	# a monatomic gas has gamma 5/3 and cv = 3R/2
	(he, e2) := th->fromgamma("helium", 4.0026, 5.0/3.0);
	if(e2 != nil)
		fail("helium: " + e2);
	else
		near("helium's cv is 3R/2", he.cv, 1.5*he.r, 1.0e-10);
}

# Every process is checked against the first law, and the first law is a
# real check here because the work and the heat are each computed from
# the process and neither from the other.
firstlaw(what: string, c: ref Change)
{
	rel(what + ": du = q - w", c.du, c.heat - c.work, 1.0e-12);
}

processes()
{
	(s1, e) := th->statept(air, 100000.0, 300.0);
	if(e != nil){
		fail("state: " + e);
		return;
	}
	near("pv = RT", s1.p*s1.v, air.r*s1.t, 1.0e-9);

	(ci, e1) := th->isothermal(air, s1, 50000.0);
	if(e1 != nil)
		fail("isothermal: " + e1);
	else {
		firstlaw("isothermal", ci);
		near("an isothermal changes no internal energy", ci.du, 0.0, 1.0e-12);
		near("so all the heat becomes work", ci.heat, ci.work, 1.0e-12);
		near("and the temperature is where it started", ci.b.t, s1.t, 1.0e-12);
		# halving the pressure doubles the volume
		near("halving the pressure doubles the volume", ci.b.v, 2.0*s1.v, 1.0e-12);
		# the entropy rise of an isothermal expansion is R ln(v2/v1)
		rel("and the entropy rises by R ln 2", ci.ds, air.r*math->log(2.0), 1.0e-12);
	}

	(cb, e2) := th->isobaric(air, s1, 600.0);
	if(e2 != nil)
		fail("isobaric: " + e2);
	else {
		firstlaw("isobaric", cb);
		near("an isobaric stays at its pressure", cb.b.p, s1.p, 1.0e-12);
		rel("its heat is cp dT", cb.heat, air.cp*300.0, 1.0e-12);
		rel("and its work is R dT", cb.work, air.r*300.0, 1.0e-10);
	}

	(cv, e3) := th->isochoric(air, s1, 600.0);
	if(e3 != nil)
		fail("isochoric: " + e3);
	else {
		firstlaw("isochoric", cv);
		near("nothing moves, so no work is done", cv.work, 0.0, 0.0);
		rel("and the heat is cv dT", cv.heat, air.cv*300.0, 1.0e-12);
		near("the volume is unchanged", cv.b.v, s1.v, 1.0e-15);
	}

	(cs, e4) := th->isentropic(air, s1, 1000000.0);
	if(e4 != nil)
		fail("isentropic: " + e4);
	else {
		firstlaw("isentropic", cs);
		near("an isentropic adds no heat", cs.heat, 0.0, 1.0e-9);
		near("and changes no entropy", cs.ds, 0.0, 1.0e-11);
		near("so the work is minus the change in internal energy",
			cs.work, -cs.du, 1.0e-10);
		gam := air.gamma();
		# the three isentropic relations must all hold at once
		rel("p v^gamma is constant", cs.b.p*math->pow(cs.b.v, gam),
			s1.p*math->pow(s1.v, gam), 1.0e-12);
		rel("T v^(gamma-1) is constant", cs.b.t*math->pow(cs.b.v, gam-1.0),
			s1.t*math->pow(s1.v, gam-1.0), 1.0e-12);
		rel("T p^((1-gamma)/gamma) is constant",
			cs.b.t*math->pow(cs.b.p, (1.0-gam)/gam),
			s1.t*math->pow(s1.p, (1.0-gam)/gam), 1.0e-12);
	}

	# the polytropic is the general case and must reduce to the others
	(pg, e5) := th->polytropic(air, s1, 1000000.0, air.gamma());
	if(e5 != nil)
		fail("polytropic at gamma: " + e5);
	else if(cs != nil){
		near("n = gamma is the isentropic", pg.work, cs.work, 1.0e-9);
		near("and its heat is zero too", pg.heat, 0.0, 1.0e-9);
	}
	(p1, e6) := th->polytropic(air, s1, 50000.0, 1.0);
	if(e6 != nil)
		fail("polytropic at one: " + e6);
	else if(ci != nil)
		near("n = 1 is the isothermal", p1.work, ci.work, 1.0e-10);
	# an index between 1 and gamma takes in heat AND cools, which is
	# the case that catches a sign error in the polytropic specific heat
	(pm, e7) := th->polytropic(air, s1, 1000000.0, 1.2);
	if(e7 != nil)
		fail("polytropic at 1.2: " + e7);
	else {
		firstlaw("polytropic n=1.2", pm);
		if(pm.b.t <= s1.t)
			fail("compressing at n = 1.2 still raises the temperature");
		if(pm.heat >= 0.0)
			fail(sys->sprint("compressing at an index below gamma must REJECT "+
				"heat, and this took in %g", pm.heat));
	}
}

cycleclosed(what: string, c: ref Cycle)
{
	# the first law around the loop: what came out as work is what
	# went in as heat, less what was thrown away
	rel(what + ": wnet = qin - qout", c.wnet, c.qin - c.qout, 1.0e-10);
	if(c.qin <= 0.0)
		fail(what + ": an engine must take heat in");
	if(c.qout <= 0.0)
		fail(what + ": an engine must throw heat away - the second law says so, "+
			"and a cycle that does not is a perpetual motion machine");
	if(c.efficiency <= 0.0 || c.efficiency >= 1.0)
		fail(sys->sprint("%s: an efficiency of %g is not one", what, c.efficiency));
}

cycles()
{
	(tc, thot) := (300.0, 900.0);
	(cy, e) := th->carnot(air, tc, thot, 1000000.0, 500000.0);
	if(e != nil)
		fail("carnot: " + e);
	else {
		cycleclosed("carnot", cy);
		rel("Carnot's efficiency is 1 - Tc/Th", cy.efficiency,
			1.0 - tc/thot, 1.0e-10);
		# and around a reversible cycle the heat divided by the
		# temperature it crossed at sums to zero - which is what
		# entropy IS, and is exact here
		rel("the heat over temperature sums to zero around it",
			cy.qin/thot - cy.qout/tc, 0.0, 1.0e-10);
		if(verbose)
			sys->print("     Carnot %.4f between %g and %g K\n",
				cy.efficiency, tc, thot);
	}

	# Otto: the efficiency depends on the compression ratio ALONE.
	# Adding four times the heat must not change it at all, which is
	# the surprising part and is worth checking rather than repeating.
	ratio := 9.0;
	gam := air.gamma();
	want := 1.0 - math->pow(ratio, 1.0-gam);
	qs := array[] of {500000.0, 1000000.0, 2000000.0};
	first := 0.0;
	for(k := 0; k < len qs; k++){
		(o, eo) := th->otto(air, ratio, 300.0, 100000.0, qs[k]);
		if(eo != nil){
			fail("otto: " + eo);
			continue;
		}
		cycleclosed("otto", o);
		rel(sys->sprint("Otto at q=%g is 1 - r^(1-gamma)", qs[k]),
			o.efficiency, want, 1.0e-10);
		if(k == 0)
			first = o.efficiency;
		else
			near("and four times the heat makes no difference",
				o.efficiency, first, 1.0e-12);
	}
	if(verbose)
		sys->print("     Otto at r=%g: %.4f\n", ratio, want);
	# a higher compression ratio is a better engine
	(o1, nil) := th->otto(air, 8.0, 300.0, 100000.0, 1000000.0);
	(o2, nil) := th->otto(air, 12.0, 300.0, 100000.0, 1000000.0);
	if(o1 != nil && o2 != nil && o2.efficiency <= o1.efficiency)
		fail("squeezing harder must make the engine better");

	# Brayton, likewise from the pressure ratio alone
	pr := 10.0;
	(b, eb) := th->brayton(air, pr, 300.0, 100000.0, 1400.0);
	if(eb != nil)
		fail("brayton: " + eb);
	else {
		cycleclosed("brayton", b);
		rel("Brayton is 1 - rp^((1-gamma)/gamma)", b.efficiency,
			1.0 - math->pow(pr, (1.0-gam)/gam), 1.0e-10);
		if(verbose)
			sys->print("     Brayton at rp=%g: %.4f\n", pr, b.efficiency);
	}

	# Diesel is always worse than Otto at the same compression ratio,
	# and approaches it as the cutoff approaches one
	(d, ed) := th->diesel(air, 18.0, 2.0, 300.0, 100000.0);
	(oo, nil) := th->otto(air, 18.0, 300.0, 100000.0, 1000000.0);
	if(ed != nil)
		fail("diesel: " + ed);
	else {
		cycleclosed("diesel", d);
		if(oo != nil && d.efficiency >= oo.efficiency)
			fail(sys->sprint("at the same compression ratio the Diesel cycle is "+
				"worse than the Otto, and it came out %g against %g",
				d.efficiency, oo.efficiency));
		(dn, nil) := th->diesel(air, 18.0, 1.001, 300.0, 100000.0);
		if(dn != nil && oo != nil){
			if(math->fabs(dn.efficiency - oo.efficiency) > 1.0e-3)
				fail(sys->sprint("as the cutoff approaches one the Diesel cycle "+
					"becomes the Otto cycle, and %g is not %g",
					dn.efficiency, oo.efficiency));
			else if(verbose)
				sys->print("     Diesel %.4f, at cutoff 1.001 %.4f, Otto %.4f\n",
					d.efficiency, dn.efficiency, oo.efficiency);
		}
	}

	# NOTHING BEATS CARNOT between the same two temperatures.  For each
	# cycle the extremes are its own hottest and coldest states, and no
	# efficiency may exceed 1 - Tmin/Tmax computed from those.
	cs := array[4] of ref Cycle;
	ns := array[] of {"carnot", "otto", "diesel", "brayton"};
	cs[0] = cy;
	(cs[1], nil) = th->otto(air, 9.0, 300.0, 100000.0, 1000000.0);
	(cs[2], nil) = th->diesel(air, 18.0, 2.0, 300.0, 100000.0);
	(cs[3], nil) = th->brayton(air, 10.0, 300.0, 100000.0, 1400.0);
	for(k = 0; k < 4; k++){
		c := cs[k];
		if(c == nil)
			continue;
		(lo, hi) := (c.states[0].t, c.states[0].t);
		for(i := 1; i < len c.states; i++){
			if(c.states[i].t < lo)
				lo = c.states[i].t;
			if(c.states[i].t > hi)
				hi = c.states[i].t;
		}
		limit := 1.0 - lo/hi;
		if(c.efficiency > limit + 1.0e-12)
			fail(sys->sprint("the %s cycle runs between %.1f and %.1f K, where "+
				"nothing can beat %.4f, and it claims %.4f",
				ns[k], lo, hi, limit, c.efficiency));
		else if(verbose)
			sys->print("     %-8s %.4f, Carnot between its own extremes %.4f\n",
				ns[k], c.efficiency, limit);
	}
}

realgas()
{
	# carbon dioxide: Tc 304.13 K, pc 7.3773 MPa
	r := 8314.462618/44.01;
	w := th->vanderwaals(r, 304.13, 7.3773e6);
	(tc, pc, vc) := w.critical();
	# the constants were derived from the critical point, so asking for
	# it back must return it - a round trip through two formulas that
	# are inverses of each other
	rel("the critical temperature comes back", tc, 304.13, 1.0e-12);
	rel("and the critical pressure", pc, 7.3773e6, 1.0e-12);
	# at the critical point the compressibility of ANY van der Waals
	# gas is exactly 3/8, whatever the gas
	near("and z at the critical point is 3/8 for every gas",
		pc*vc/(r*tc), 0.375, 1.0e-12);
	# far from the critical point it must look ideal
	near("a thin gas is an ideal one", w.z(100.0, 1000.0), 1.0, 1.0e-3);
	if(math->fabs(w.z(vc*1.2, tc) - 1.0) < 0.1)
		fail("near its critical point a real gas is nothing like ideal, and z "+
			"came out close to one");
	else if(verbose)
		sys->print("     CO2: z = %.4f at the critical point, %.4f when thin\n",
			pc*vc/(r*tc), w.z(100.0, 1000.0));
	# a helium-like gas with almost no attraction is nearly ideal
	w2 := th->vanderwaals(2077.0, 5.19, 0.227e6);
	if(w2.z(1.0, 300.0) < 0.99 || w2.z(1.0, 300.0) > 1.01)
		fail(sys->sprint("helium at 300 K and a cubic metre a kilogram is very "+
			"nearly ideal, and z came out %g", w2.z(1.0, 300.0)));
}

exchangers()
{
	# A short fat fin is nearly all base and its efficiency is one; a
	# long thin one is mostly useless.
	(f0, e0) := th->finefficiency(50.0, 200.0, 0.01, 1.0e-9);
	if(e0 != nil)
		fail("fin: " + e0);
	else
		near("a fin of no length is all base", f0, 1.0, 1.0e-9);
	(f1, nil) := th->finefficiency(50.0, 200.0, 0.01, 0.05);
	(f2, nil) := th->finefficiency(50.0, 200.0, 0.01, 0.5);
	if(f1 <= f2)
		fail("a longer fin is a less efficient one");
	if(f1 <= 0.0 || f1 >= 1.0)
		fail(sys->sprint("a fin's efficiency is between nothing and all, and "+
			"came out %g", f1));
	# against the formula itself, at one point
	m := math->sqrt(2.0*50.0/(200.0*0.01));
	rel("and it is tanh(mL)/mL", f1, math->tanh(m*0.05)/(m*0.05), 1.0e-12);

	# THE SAME EXCHANGER, WORKED OUT TWICE.  Effectiveness-NTU gives
	# the outlet temperatures from the sizes; the log mean temperature
	# difference gives the duty from the temperatures.  They are
	# different arithmetic and must agree.
	arr := array[] of {th->COUNTER, th->PARALLEL};
	nm := array[] of {"counterflow", "parallel flow"};
	for(k := 0; k < 2; k++){
		(ch, cc) := (2000.0, 4000.0);		# W/K
		ua := 3000.0;				# W/K
		(thi, tci) := (400.0, 300.0);
		cmin := ch;
		cmax := cc;
		if(cc < ch){
			cmin = cc;
			cmax = ch;
		}
		ntu := ua/cmin;
		(eff, ee) := th->effectiveness(arr[k], ntu, cmin/cmax);
		if(ee != nil){
			fail("effectiveness: " + ee);
			continue;
		}
		q1 := eff*cmin*(thi - tci);
		tho := thi - q1/ch;
		tco := tci + q1/cc;
		(dt, el) := th->lmtd(arr[k], thi, tho, tci, tco);
		if(el != nil){
			fail("lmtd: " + el);
			continue;
		}
		q2 := ua*dt;
		rel(nm[k] + ": the two methods give the same duty", q2, q1, 1.0e-9);
		if(verbose)
			sys->print("     %-14s eff %.4f, duty %.1f W and %.1f W\n",
				nm[k], eff, q1, q2);
		# and the energy balances between the streams
		rel(nm[k] + ": what the hot stream lost the cold stream gained",
			ch*(thi-tho), cc*(tco-tci), 1.0e-12);
	}
	# counterflow beats parallel flow at the same size, always
	(ec, nil) := th->effectiveness(th->COUNTER, 1.5, 0.5);
	(ep, nil) := th->effectiveness(th->PARALLEL, 1.5, 0.5);
	if(ec <= ep)
		fail(sys->sprint("counterflow is the better arrangement and always has "+
			"been: %g against %g", ec, ep));
	# with equal capacities the counterflow formula divides by zero and
	# must take the limit instead
	(e1, er) := th->effectiveness(th->COUNTER, 2.0, 1.0);
	if(er != nil)
		fail("equal capacities: " + er);
	else {
		near("at equal capacities counterflow is NTU/(1+NTU)", e1, 2.0/3.0, 1.0e-12);
		# and it must join smoothly onto the general formula
		(e2, nil) := th->effectiveness(th->COUNTER, 2.0, 0.999999);
		near("and the general formula agrees just beside it", e2, e1, 1.0e-6);
	}
	# a huge exchanger approaches perfection but never reaches it
	(ebig, nil) := th->effectiveness(th->COUNTER, 100.0, 0.5);
	if(ebig <= 0.999 || ebig > 1.0)
		fail(sys->sprint("an enormous counterflow exchanger is nearly perfect, "+
			"and came to %g", ebig));
	# parallel flow cannot, however big: its limit is 1/(1+cr)
	(pbig, nil) := th->effectiveness(th->PARALLEL, 100.0, 0.5);
	near("parallel flow is stuck at 1/(1+cr) however big it is", pbig,
		1.0/1.5, 1.0e-9);
	# equal end differences: the log mean of two equal numbers is that
	# number, and the formula divides by log(1)
	# 400 down to 350 against 300 up to 350: both ends differ by 50
	(d, nil) := th->lmtd(th->COUNTER, 400.0, 350.0, 300.0, 350.0);
	near("equal end differences give that difference", d, 50.0, 1.0e-9);
}

refusals()
{
	(nil, e1) := th->fromgamma("impossible", 28.0, 0.9);
	if(e1 == nil)
		fail("gamma below one would make cv negative and should be refused");
	(nil, e2) := th->fromgamma("impossible", 28.0, 2.0);
	if(e2 == nil)
		fail("gamma above 5/3 is above a monatomic gas and should be refused");
	(nil, e3) := th->fromcp("impossible", 28.0, 100.0);
	if(e3 == nil)
		fail("a cp below R would make cv negative and should be refused");
	(nil, e4) := th->statept(air, 100000.0, -50.0);
	if(e4 == nil)
		fail("a negative absolute temperature should be refused - this is what "+
			"happens when celsius is passed");
	(nil, e5) := th->statept(air, -100.0, 300.0);
	if(e5 == nil)
		fail("a negative absolute pressure should be refused");
	(nil, e6) := th->carnot(air, 900.0, 300.0, 1000000.0, 500000.0);
	if(e6 == nil)
		fail("a cold reservoir hotter than the hot one is not an engine");
	(nil, e7) := th->otto(air, 0.5, 300.0, 100000.0, 1000000.0);
	if(e7 == nil)
		fail("a compression ratio below one is an expansion");
	(nil, e8) := th->diesel(air, 18.0, 20.0, 300.0, 100000.0);
	if(e8 == nil)
		fail("a cutoff ratio above the compression ratio should be refused");
	(nil, e9) := th->brayton(air, 10.0, 300.0, 100000.0, 400.0);
	if(e9 == nil)
		fail("a turbine inlet cooler than the compressor outlet is not a burner");
	(nil, e10) := th->lmtd(th->COUNTER, 400.0, 350.0, 360.0, 420.0);
	if(e10 == nil)
		fail("streams that cross should be refused: heat does not flow uphill");
	(nil, e11) := th->effectiveness(th->COUNTER, 1.0, 1.5);
	if(e11 == nil)
		fail("a capacity ratio above one means Cmin and Cmax are the wrong way "+
			"round and should be refused");
	(nil, e12) := th->finefficiency(50.0, 200.0, -0.01, 0.05);
	if(e12 == nil)
		fail("a fin of negative thickness should be refused");
	(nil, e13) := th->carnot(air, 300.0, 900.0, 1000000.0, 500000.0);
	if(e13 != nil)
		fail("a good Carnot cycle was refused: " + e13);
}
