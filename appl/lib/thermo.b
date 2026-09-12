implement Thermo;

# Gases, processes, cycles and heat exchange.  See thermo.m for the sign
# convention (heat in positive, work out positive) and for the units,
# which are SI and absolute throughout.

include "sys.m";
	sys: Sys;
include "math.m";
	math: Math;
include "thermo.m";

init()
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
}

Gas.gamma(g: self ref Gas): real
{
	if(g.cv == 0.0)
		return 0.0;
	return g.cp/g.cv;
}

fromcp(name: string, mw, cp: real): (ref Gas, string)
{
	if(mw <= 0.0)
		return (nil, "a molar mass must be positive");
	g := ref Gas;
	g.name = name;
	g.mw = mw;
	g.r = RUNIV/mw;
	if(cp <= g.r)
		return (nil, sys->sprint("cp must exceed R (%.1f J/kg K for this gas), "+
			"since cp - cv = R and cv is positive", g.r));
	g.cp = cp;
	g.cv = cp - g.r;
	return (g, nil);
}

fromgamma(name: string, mw, gamma: real): (ref Gas, string)
{
	if(mw <= 0.0)
		return (nil, "a molar mass must be positive");
	if(gamma <= 1.0)
		return (nil, "gamma is cp/cv and cp exceeds cv by R, so it is above one");
	if(gamma > 1.7)
		return (nil, "gamma above 5/3 is above a monatomic gas's, which is the "+
			"most any gas has");
	g := ref Gas;
	g.name = name;
	g.mw = mw;
	g.r = RUNIV/mw;
	g.cv = g.r/(gamma - 1.0);
	g.cp = g.cv*gamma;
	return (g, nil);
}

air(): ref Gas
{
	(g, nil) := fromgamma("air", 28.9647, 1.4);
	return g;
}

# The reference state for u, h and s.  Only differences matter, so the
# choice is arbitrary and is recorded rather than hidden: u and h are
# measured from 0 K, and the entropy from one bar at 300 K.
TREF: con 300.0;
PREF: con 100000.0;

fill(g: ref Gas, s: ref State)
{
	s.u = g.cv*s.t;
	s.h = g.cp*s.t;
	s.s = g.cp*math->log(s.t/TREF) - g.r*math->log(s.p/PREF);
}

statepv(g: ref Gas, p, v: real): (ref State, string)
{
	if(p <= 0.0 || v <= 0.0)
		return (nil, "pressure and volume are positive, and absolute");
	s := ref State;
	s.p = p;
	s.v = v;
	s.t = p*v/g.r;
	fill(g, s);
	return (s, nil);
}

statept(g: ref Gas, p, t: real): (ref State, string)
{
	if(p <= 0.0)
		return (nil, "pressure is positive and absolute");
	if(t <= 0.0)
		return (nil, "temperature is in kelvin, so it is positive; a celsius "+
			"value has been passed if this looks wrong");
	s := ref State;
	s.p = p;
	s.t = t;
	s.v = g.r*t/p;
	fill(g, s);
	return (s, nil);
}

statevt(g: ref Gas, v, t: real): (ref State, string)
{
	if(v <= 0.0)
		return (nil, "volume is positive");
	if(t <= 0.0)
		return (nil, "temperature is in kelvin, so it is positive");
	s := ref State;
	s.v = v;
	s.t = t;
	s.p = g.r*t/v;
	fill(g, s);
	return (s, nil);
}

# Each of these computes the work from the process and the heat from the
# process, never one from the other: the first law is then a statement
# about the result that a test can check, rather than an assumption
# built into the code.

isothermal(g: ref Gas, a: ref State, p2: real): (ref Change, string)
{
	if(p2 <= 0.0)
		return (nil, "pressure is positive");
	(b, e) := statept(g, p2, a.t);
	if(e != nil)
		return (nil, e);
	c := ref Change;
	c.b = b;
	# w = R T ln(v2/v1), and for an isothermal that is R T ln(p1/p2)
	c.work = g.r*a.t*math->log(a.p/p2);
	# the internal energy of an ideal gas depends on temperature alone
	c.du = 0.0;
	c.heat = c.work;
	c.ds = b.s - a.s;
	return (c, nil);
}

isobaric(g: ref Gas, a: ref State, t2: real): (ref Change, string)
{
	(b, e) := statept(g, a.p, t2);
	if(e != nil)
		return (nil, e);
	c := ref Change;
	c.b = b;
	c.work = a.p*(b.v - a.v);
	c.heat = g.cp*(t2 - a.t);
	c.du = g.cv*(t2 - a.t);
	c.ds = b.s - a.s;
	return (c, nil);
}

isochoric(g: ref Gas, a: ref State, t2: real): (ref Change, string)
{
	(b, e) := statevt(g, a.v, t2);
	if(e != nil)
		return (nil, e);
	c := ref Change;
	c.b = b;
	c.work = 0.0;			# nothing moves, so nothing is done
	c.heat = g.cv*(t2 - a.t);
	c.du = g.cv*(t2 - a.t);
	c.ds = b.s - a.s;
	return (c, nil);
}

isentropic(g: ref Gas, a: ref State, p2: real): (ref Change, string)
{
	return polytropic(g, a, p2, g.gamma());
}

polytropic(g: ref Gas, a: ref State, p2, n: real): (ref Change, string)
{
	if(p2 <= 0.0)
		return (nil, "pressure is positive");
	if(n == 1.0)
		return isothermal(g, a, p2);
	if(n < 0.0)
		return (nil, "a negative polytropic index describes nothing physical");
	# p v^n constant, so T2/T1 = (p2/p1)^((n-1)/n)
	t2 := a.t*math->pow(p2/a.p, (n-1.0)/n);
	(b, e) := statept(g, p2, t2);
	if(e != nil)
		return (nil, e);
	c := ref Change;
	c.b = b;
	# w = (p1 v1 - p2 v2)/(n-1), which for n = gamma is -du exactly
	c.work = (a.p*a.v - p2*b.v)/(n - 1.0);
	c.du = g.cv*(t2 - a.t);
	# q from the process: the polytropic specific heat is cv(n-gamma)/(n-1)
	c.heat = g.cv*(n - g.gamma())/(n - 1.0)*(t2 - a.t);
	c.ds = b.s - a.s;
	return (c, nil);
}

# ---------------------------------------------------------------- cycles

mkcycle(states: array of ref State, names: array of string,
	wnet, qin, qout: real): ref Cycle
{
	c := ref Cycle;
	c.states = states;
	c.names = names;
	c.wnet = wnet;
	c.qin = qin;
	c.qout = qout;
	if(qin != 0.0)
		c.efficiency = wnet/qin;
	return c;
}

# Isothermal in, isentropic down, isothermal out, isentropic up.  Its
# efficiency is 1 - Tc/Th and nothing else, and no cycle between the
# same two temperatures can beat it.
carnot(g: ref Gas, tc, th, p1, p2: real): (ref Cycle, string)
{
	if(tc <= 0.0 || th <= 0.0)
		return (nil, "temperatures are in kelvin and positive");
	if(th <= tc)
		return (nil, "the hot reservoir must be hotter than the cold one, or "+
			"there is no engine");
	if(p2 >= p1)
		return (nil, "the isothermal expansion must lower the pressure");
	(s1, e1) := statept(g, p1, th);
	if(e1 != nil)
		return (nil, e1);
	(c12, e2) := isothermal(g, s1, p2);		# heat in, at th
	if(e2 != nil)
		return (nil, e2);
	s2 := c12.b;
	# isentropic down to tc
	p3 := s2.p*math->pow(tc/th, g.gamma()/(g.gamma()-1.0));
	(c23, e3) := isentropic(g, s2, p3);
	if(e3 != nil)
		return (nil, e3);
	s3 := c23.b;
	# isentropic up from s4 to s1 closes the cycle, so s4 is where
	# that line meets the cold isotherm
	p4 := p1*math->pow(tc/th, g.gamma()/(g.gamma()-1.0));
	(c34, e4) := isothermal(g, s3, p4);		# heat out, at tc
	if(e4 != nil)
		return (nil, e4);
	s4 := c34.b;
	(c41, e5) := isentropic(g, s4, p1);
	if(e5 != nil)
		return (nil, e5);
	wnet := c12.work + c23.work + c34.work + c41.work;
	return (mkcycle(array[] of {s1, s2, s3, s4},
		array[] of {"hot isotherm", "expansion", "cold isotherm", "compression"},
		wnet, c12.heat, -c34.heat), nil);
}

# Compress, burn at constant volume, expand, reject at constant volume.
# Its efficiency is 1 - r^(1-gamma) and depends on the compression ratio
# alone - not on how much heat was added, which is the surprising part
# and is worth being able to check.
otto(g: ref Gas, ratio, t1, p1, qin: real): (ref Cycle, string)
{
	if(ratio <= 1.0)
		return (nil, "a compression ratio is above one");
	if(qin <= 0.0)
		return (nil, "an engine needs heat put into it");
	(s1, e1) := statept(g, p1, t1);
	if(e1 != nil)
		return (nil, e1);
	gam := g.gamma();
	# compress isentropically by the volume ratio
	t2 := t1*math->pow(ratio, gam-1.0);
	(c12, e2) := isentropic(g, s1, p1*math->pow(ratio, gam));
	if(e2 != nil)
		return (nil, e2);
	s2 := c12.b;
	t3 := t2 + qin/g.cv;
	(c23, e3) := isochoric(g, s2, t3);
	if(e3 != nil)
		return (nil, e3);
	s3 := c23.b;
	(c34, e4) := isentropic(g, s3, s3.p/math->pow(ratio, gam));
	if(e4 != nil)
		return (nil, e4);
	s4 := c34.b;
	(c41, e5) := isochoric(g, s4, t1);
	if(e5 != nil)
		return (nil, e5);
	wnet := c12.work + c23.work + c34.work + c41.work;
	return (mkcycle(array[] of {s1, s2, s3, s4},
		array[] of {"intake", "compressed", "burnt", "expanded"},
		wnet, c23.heat, -c41.heat), nil);
}

# The same but burning at constant pressure, over a cutoff ratio.  Its
# efficiency is always below the Otto cycle's at the same compression
# ratio, and approaches it as the cutoff approaches one.
diesel(g: ref Gas, ratio, cutoff, t1, p1: real): (ref Cycle, string)
{
	if(ratio <= 1.0)
		return (nil, "a compression ratio is above one");
	if(cutoff <= 1.0)
		return (nil, "the cutoff ratio is above one; at one the cycle is an "+
			"Otto cycle and burns at constant volume");
	if(cutoff >= ratio)
		return (nil, "the cutoff ratio must be below the compression ratio, or "+
			"the burn outlasts the stroke");
	(s1, e1) := statept(g, p1, t1);
	if(e1 != nil)
		return (nil, e1);
	gam := g.gamma();
	(c12, e2) := isentropic(g, s1, p1*math->pow(ratio, gam));
	if(e2 != nil)
		return (nil, e2);
	s2 := c12.b;
	(c23, e3) := isobaric(g, s2, s2.t*cutoff);
	if(e3 != nil)
		return (nil, e3);
	s3 := c23.b;
	# expand back to the original volume
	(c34, e4) := isentropic(g, s3, s3.p*math->pow(s3.v/s1.v, gam));
	if(e4 != nil)
		return (nil, e4);
	s4 := c34.b;
	(c41, e5) := isochoric(g, s4, t1);
	if(e5 != nil)
		return (nil, e5);
	wnet := c12.work + c23.work + c34.work + c41.work;
	return (mkcycle(array[] of {s1, s2, s3, s4},
		array[] of {"intake", "compressed", "burnt", "expanded"},
		wnet, c23.heat, -c41.heat), nil);
}

# A gas turbine: compress, burn at constant pressure, expand, reject at
# constant pressure.  Efficiency 1 - rp^((1-gamma)/gamma), which again
# depends on the pressure ratio alone.
brayton(g: ref Gas, ratio, t1, p1, t3: real): (ref Cycle, string)
{
	if(ratio <= 1.0)
		return (nil, "a pressure ratio is above one");
	(s1, e1) := statept(g, p1, t1);
	if(e1 != nil)
		return (nil, e1);
	(c12, e2) := isentropic(g, s1, p1*ratio);
	if(e2 != nil)
		return (nil, e2);
	s2 := c12.b;
	if(t3 <= s2.t)
		return (nil, sys->sprint("the turbine inlet must be hotter than the "+
			"compressor outlet (%.1f K), or the burner is cooling the gas", s2.t));
	(c23, e3) := isobaric(g, s2, t3);
	if(e3 != nil)
		return (nil, e3);
	s3 := c23.b;
	(c34, e4) := isentropic(g, s3, p1);
	if(e4 != nil)
		return (nil, e4);
	s4 := c34.b;
	(c41, e5) := isobaric(g, s4, t1);
	if(e5 != nil)
		return (nil, e5);
	wnet := c12.work + c23.work + c34.work + c41.work;
	return (mkcycle(array[] of {s1, s2, s3, s4},
		array[] of {"intake", "compressed", "burnt", "expanded"},
		wnet, c23.heat, -c41.heat), nil);
}

# --------------------------------------------------------- a real gas

vanderwaals(r, tc, pc: real): ref VdW
{
	w := ref VdW;
	w.r = r;
	# inverting the critical relations: a = 27 R^2 Tc^2 / 64 pc,
	# b = R Tc / 8 pc
	w.a = 27.0*r*r*tc*tc/(64.0*pc);
	w.b = r*tc/(8.0*pc);
	return w;
}

VdW.pressure(w: self ref VdW, v, t: real): real
{
	if(v <= w.b)
		return 0.0;		# inside the molecules' own volume
	return w.r*t/(v - w.b) - w.a/(v*v);
}

VdW.critical(w: self ref VdW): (real, real, real)
{
	tc := 8.0*w.a/(27.0*w.r*w.b);
	pc := w.a/(27.0*w.b*w.b);
	vc := 3.0*w.b;
	return (tc, pc, vc);
}

VdW.z(w: self ref VdW, v, t: real): real
{
	return w.pressure(v, t)*v/(w.r*t);
}

# ------------------------------------------------------- heat transfer

finefficiency(h, k, thick, length: real): (real, string)
{
	if(h <= 0.0 || k <= 0.0 || thick <= 0.0 || length <= 0.0)
		return (0.0, "every one of these is a positive quantity");
	m := math->sqrt(2.0*h/(k*thick));
	x := m*length;
	if(x < 1.0e-8)
		return (1.0, nil);	# a fin with no length is all base
	return (math->tanh(x)/x, nil);
}

lmtd(arrangement: int, thi, tho, tci, tco: real): (real, string)
{
	(d1, d2) := (0.0, 0.0);
	case arrangement {
	PARALLEL =>
		d1 = thi - tci;
		d2 = tho - tco;
	COUNTER =>
		d1 = thi - tco;
		d2 = tho - tci;
	* =>
		return (0.0, "an exchanger is parallel flow or counterflow");
	}
	if(d1 <= 0.0 || d2 <= 0.0)
		return (0.0, sys->sprint("the streams cross: the difference is %.3g at "+
			"one end and %.3g at the other, and heat does not flow uphill",
			d1, d2));
	if(math->fabs(d1 - d2) < 1.0e-12*d1)
		return (d1, nil);	# the log mean of equal numbers is the number
	return ((d1 - d2)/math->log(d1/d2), nil);
}

effectiveness(arrangement: int, ntu, cr: real): (real, string)
{
	if(ntu < 0.0)
		return (0.0, "NTU is not negative");
	if(cr < 0.0 || cr > 1.0)
		return (0.0, "the capacity ratio is the smaller capacity over the "+
			"larger, so it is between 0 and 1");
	case arrangement {
	PARALLEL =>
		if(cr == 0.0)
			return (1.0 - math->exp(-ntu), nil);
		return ((1.0 - math->exp(-ntu*(1.0+cr)))/(1.0+cr), nil);
	COUNTER =>
		if(cr == 0.0)
			return (1.0 - math->exp(-ntu), nil);
		if(math->fabs(cr - 1.0) < 1.0e-12)
			return (ntu/(1.0 + ntu), nil);	# the limit, which the formula cannot take
		x := math->exp(-ntu*(1.0-cr));
		return ((1.0 - x)/(1.0 - cr*x), nil);
	}
	return (0.0, "an exchanger is parallel flow or counterflow");
}
