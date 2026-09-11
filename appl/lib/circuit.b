implement Circuit;

# Lumped circuits by modified nodal analysis.  See circuit.m for the
# netlist and why the matrix is solved directly rather than by krylov(2).
#
# The capacitor and the inductor are handled by COMPANION MODELS: at
# each step each is replaced by a conductance in parallel with a current
# source, chosen so that the linear solve reproduces the trapezoidal
# rule applied to i = C dv/dt or v = L di/dt.  That is how every circuit
# simulator does it, and it is why a transient analysis is a sequence of
# linear solves rather than an ODE integration - the nonlinearity of a
# real device would add an inner Newton loop, and there are no nonlinear
# devices here.

include "sys.m";
	sys: Sys;
include "string.m";
	str: String;
include "math.m";
	math: Math;
include "circuit.m";

init()
{
	sys = load Sys Sys->PATH;
	str = load String String->PATH;
	math = load Math Math->PATH;
}

# SPICE's own suffixes.  `meg' and not `M' for a million: M is milli,
# which catches everyone once.
value(s: string): (real, string)
{
	if(s == nil)
		return (0.0, "empty value");
	# split the number from the suffix
	i := 0;
	while(i < len s && (s[i] == '-' || s[i] == '+' || s[i] == '.' ||
			(s[i] >= '0' && s[i] <= '9') || s[i] == 'e' || s[i] == 'E')){
		# an `e' is only an exponent if a digit or sign follows
		if((s[i] == 'e' || s[i] == 'E') &&
		   !(i+1 < len s && (s[i+1] == '-' || s[i+1] == '+' ||
				     (s[i+1] >= '0' && s[i+1] <= '9'))))
			break;
		i++;
	}
	if(i == 0)
		return (0.0, "no number in " + s);
	v := real s[0:i];
	suf := s[i:];
	for(j := 0; j < len suf; j++)
		if(suf[j] >= 'A' && suf[j] <= 'Z')
			suf[j] += 'a' - 'A';
	# `meg' before `m', or a megohm is a milliohm
	mul := 1.0;
	if(len suf >= 3 && suf[0:3] == "meg"){
		mul = 1.0e6;
		suf = suf[3:];
	} else if(len suf > 0){
		got := 1;
		case suf[0] {
		't' =>	mul = 1.0e12;
		'g' =>	mul = 1.0e9;
		'k' =>	mul = 1.0e3;
		'm' =>	mul = 1.0e-3;
		'u' =>	mul = 1.0e-6;
		'n' =>	mul = 1.0e-9;
		'p' =>	mul = 1.0e-12;
		'f' =>	mul = 1.0e-15;
		* =>	got = 0;
		}
		if(got)
			suf = suf[1:];
	}
	# Whatever is left must be a unit, and is then ignored, so that
	# 1kohm, 10uF and 5mH all read.  SPICE ignores ANY trailing text
	# here; this does not, because that turns a typo into a number -
	# `1q' would be one ohm and no one would ever be told.  Note that
	# matching the multiplier first makes a bare `1F' one femto and not
	# one farad, exactly as it does in SPICE, and there is no way to
	# tell the two apart.
	if(suf != nil)
		case suf {
		"ohm" or "ohms" or "r" or
		"f" or "farad" or "farads" or
		"h" or "henry" or "henries" or
		"v" or "volt" or "volts" or
		"a" or "amp" or "amps" or "ampere" or "amperes" or
		"s" or "sec" or "secs" or "second" or "seconds" or
		"hz" or "hertz" =>
			;
		* =>
			return (0.0, "'" + s[i:] + "' in " + s +
				" is not a multiplier followed by a unit");
		}
	return (v*mul, nil);
}

Net.node(n: self ref Net, name: string): int
{
	if(name == "0" || name == "gnd" || name == "GND")
		return 0;
	for(i := 0; i < n.nnodes; i++)
		if(n.names[i] == name)
			return i;
	if(n.nnodes >= len n.names){
		a := array[2*len n.names + 8] of string;
		a[0:] = n.names;
		n.names = a;
	}
	n.names[n.nnodes] = name;
	return n.nnodes++;
}

parse(spec: string): (ref Net, string)
{
	n := ref Net;
	n.names = array[16] of string;
	n.names[0] = "0";
	n.nnodes = 1;
	n.nsrc = 0;
	n.analysis = "dc";
	n.method = "trap";
	n.tstep = 0.0;
	n.tstop = 0.0;
	n.t = 0.0;
	parts: list of ref Part;
	ics: list of (string, real, int);	# .ic lines, applied once the parts exist
	np := 0;
	lineno := 0;
	for(rest := spec; rest != nil;){
		(line, tail) := str->splitl(rest, "\n");
		if(tail != nil)
			tail = tail[1:];
		rest = tail;
		lineno++;
		(nw, w) := sys->tokenize(line, " \t\r");
		if(nw == 0 || (hd w)[0] == '#')
			continue;
		a := array[nw] of string;
		for(i := 0; w != nil; (w, i) = (tl w, i+1))
			a[i] = hd w;
		if(a[0][0] == '.'){
			case a[0] {
			".dc" =>
				n.analysis = "dc";
			".tran" =>
				if(nw < 3)
					return (nil, sys->sprint("line %d: .tran needs a step and a stop time", lineno));
				(st, e1) := value(a[1]);
				if(e1 != nil)
					return (nil, sys->sprint("line %d: %s", lineno, e1));
				(sp, e2) := value(a[2]);
				if(e2 != nil)
					return (nil, sys->sprint("line %d: %s", lineno, e2));
				n.analysis = "tran";
				n.tstep = st;
				n.tstop = sp;
			".ic" =>
				if(nw != 3)
					return (nil, sys->sprint("line %d: .ic is a part name and a value", lineno));
				(iv, e3) := value(a[2]);
				if(e3 != nil)
					return (nil, sys->sprint("line %d: %s", lineno, e3));
				ics = (a[1], iv, lineno) :: ics;
			".method" =>
				if(nw != 2 || (a[1] != "trap" && a[1] != "be"))
					return (nil, sys->sprint("line %d: .method is trap or be", lineno));
				n.method = a[1];
			* =>
				return (nil, sys->sprint("line %d: no such directive %s", lineno, a[0]));
			}
			continue;
		}
		if(nw != 4)
			return (nil, sys->sprint("line %d: a component is NAME node node value", lineno));
		(v, ev) := value(a[3]);
		if(ev != nil)
			return (nil, sys->sprint("line %d: %s", lineno, ev));
		p := ref Part;
		p.name = a[0];
		p.a = n.node(a[1]);
		p.b = n.node(a[2]);
		p.value = v;
		p.vprev = 0.0;
		p.iprev = 0.0;
		p.ic = 0.0;
		p.hasic = 0;
		p.slot = -1;
		c := a[0][0];
		if(c >= 'a' && c <= 'z')
			c += 'A' - 'a';
		case c {
		'R' =>
			if(v == 0.0)
				return (nil, sys->sprint("line %d: %s has no resistance, which is a wire and not a component", lineno, p.name));
			p.kind = Res;
		'C' =>	p.kind = Cap;
		'L' =>
			if(v == 0.0)
				return (nil, sys->sprint("line %d: %s has no inductance", lineno, p.name));
			p.kind = Ind;
		'V' =>
			p.kind = Vsrc;
			p.slot = n.nsrc++;
		'I' =>	p.kind = Isrc;
		* =>
			return (nil, sys->sprint("line %d: %s: a component's name says what it is, and %c is none of R C L V I", lineno, p.name, c));
		}
		parts = p :: parts;
		np++;
	}
	if(np == 0)
		return (nil, "the netlist has no components in it");
	n.parts = array[np] of ref Part;
	i := np;
	for(l := parts; l != nil; l = tl l)
		n.parts[--i] = hd l;
	# .ic is applied here and not where it was read, so that it may
	# name a part the reader has not reached yet
	for(il := ics; il != nil; il = tl il){
		(nm, iv, ln) := hd il;
		found := 0;
		for(k := 0; k < np; k++){
			p := n.parts[k];
			if(p.name != nm)
				continue;
			if(p.kind != Cap && p.kind != Ind)
				return (nil, sys->sprint("line %d: .ic %s: only a capacitor or an inductor stores anything", ln, nm));
			p.ic = iv;
			p.hasic = 1;
			found = 1;
		}
		if(!found)
			return (nil, sys->sprint("line %d: .ic %s: there is no %s in this circuit", ln, nm, nm));
	}
	return (n, nil);
}

# Gaussian elimination with partial pivoting.  The system is small - a
# teaching circuit is tens of unknowns - and indefinite, so this is the
# right tool and an iterative solver is not.
solve(a: array of array of real, b: array of real): (array of real, string)
{
	n := len b;
	# work on copies: a caller that wants to solve twice with the same
	# matrix should not find it eaten
	m := array[n] of array of real;
	for(i := 0; i < n; i++){
		m[i] = array[n] of real;
		m[i][0:] = a[i];
	}
	x := array[n] of real;
	x[0:] = b;
	for(k := 0; k < n; k++){
		# pivot
		piv := k;
		for(i = k+1; i < n; i++)
			if(math->fabs(m[i][k]) > math->fabs(m[piv][k]))
				piv = i;
		if(math->fabs(m[piv][k]) < 1.0e-14)
			return (nil, sys->sprint("the circuit has no single answer: unknown %d is not determined - a node with nothing to hold it, or two voltage sources across each other", k));
		if(piv != k){
			trow := m[piv]; m[piv] = m[k]; m[k] = trow;
			tv := x[piv]; x[piv] = x[k]; x[k] = tv;
		}
		for(i = k+1; i < n; i++){
			f := m[i][k]/m[k][k];
			if(f == 0.0)
				continue;
			for(j := k; j < n; j++)
				m[i][j] -= f*m[k][j];
			x[i] -= f*x[k];
		}
	}
	for(i = n-1; i >= 0; i--){
		s := x[i];
		for(j := i+1; j < n; j++)
			s -= m[i][j]*x[j];
		x[i] = s/m[i][i];
	}
	return (x, nil);
}

# The three things a solve can be asked for, which differ ONLY in what
# the storage elements are taken to be:
#
#	Dcop	where the circuit ends up: capacitor open, inductor shorted
#	Icop	where it starts: each element HOLDS the state it has, so a
#		capacitor is a voltage source of its own voltage and an
#		inductor a current source of its own current.  The point of
#		it is the other half of each pair - the current through the
#		capacitor and the voltage across the inductor - which the
#		trapezoidal rule needs at t=0 and cannot invent.
#	Tran	a step: companion models, above.
Dcop, Icop, Tran: con iota;

assemble(n: ref Net, h: real, mode: int): string
{
	nn := n.nnodes - 1;			# ground is not an unknown
	sz := nn + n.nsrc;
	if(sz == 0)
		return "the netlist has no nodes but ground";
	g := array[sz] of array of real;
	for(i := 0; i < sz; i++){
		g[i] = array[sz] of real;
		for(j := 0; j < sz; j++)
			g[i][j] = 0.0;
	}
	rhs := array[sz] of real;
	for(i = 0; i < sz; i++)
		rhs[i] = 0.0;
	for(k := 0; k < len n.parts; k++){
		p := n.parts[k];
		(a, b) := (p.a-1, p.b-1);	# -1 because ground is dropped
		case p.kind {
		Res =>
			stampg(g, a, b, 1.0/p.value);
		Isrc =>
			stampi(rhs, a, b, p.value);
		Cap =>
			case mode {
			Dcop =>
				;			# open at DC: contributes nothing
			Icop =>
				# holds its voltage: a source of exactly that
				r := nn + p.slot;
				stampshort(g, a, b, r);
				rhs[r] = p.vprev;
			Tran =>
				(geq, ieq) := capcompanion(n, p, h);
				stampg(g, a, b, geq);
				stampi(rhs, a, b, ieq);
			}
		Ind =>
			case mode {
			Dcop =>
				# a short at DC, which MNA cannot stamp as a
				# conductance: a very large one is the usual dodge and
				# is a lie that shows up in the answer, so the
				# inductor gets a voltage-source row of its own set to
				# zero volts instead.  That is an exact short.
				stampshort(g, a, b, nn + p.slot);
			Icop =>
				stampi(rhs, a, b, p.iprev);	# holds its current
			Tran =>
				(geq, ieq) := indcompanion(n, p, h);
				stampg(g, a, b, geq);
				stampi(rhs, a, b, ieq);
			}
		Vsrc =>
			r := nn + p.slot;
			if(a >= 0){
				g[a][r] += 1.0;
				g[r][a] += 1.0;
			}
			if(b >= 0){
				g[b][r] -= 1.0;
				g[r][b] -= 1.0;
			}
			rhs[r] = p.value;
		}
	}
	(x, err) := solve(g, rhs);
	if(err != nil)
		return err;
	n.x = x;
	return nil;
}

stampg(g: array of array of real, a, b: int, v: real)
{
	if(a >= 0)
		g[a][a] += v;
	if(b >= 0)
		g[b][b] += v;
	if(a >= 0 && b >= 0){
		g[a][b] -= v;
		g[b][a] -= v;
	}
}

# A current source of i amps flowing INTO the element at a and out at b,
# which is SPICE's own sense for `I name n+ n-'.
stampi(rhs: array of real, a, b: int, i: real)
{
	if(a >= 0)
		rhs[a] -= i;
	if(b >= 0)
		rhs[b] += i;
}

stampshort(g: array of array of real, a, b, r: int)
{
	if(a >= 0){
		g[a][r] += 1.0;
		g[r][a] += 1.0;
	}
	if(b >= 0){
		g[b][r] -= 1.0;
		g[r][b] -= 1.0;
	}
}

# Both companions answer the same question and so are written the same
# way: the element's current from a to b is
#
#	i = geq*v + ieq
#
# a conductance geq with a current source ieq beside it.  ONE convention
# for both, because the first version of this had the capacitor's
# constant term defined with the opposite sign from the inductor's and
# then stamped both the same way.  The capacitor was right and the
# inductor was wrong by exactly a factor of -1 on its history, which is
# an inductor that gains energy every step: the series RLC reached 1e36.
# Nothing in a DC test can see this, because at DC neither companion is
# used at all.

# i = C dv/dt.  Trapezoidal: i_new + i_old = (2C/h)(v_new - v_old).
capcompanion(n: ref Net, p: ref Part, h: real): (real, real)
{
	if(n.method == "be"){
		geq := p.value/h;
		return (geq, -geq*p.vprev);
	}
	geq := 2.0*p.value/h;
	return (geq, -(geq*p.vprev + p.iprev));
}

# v = L di/dt.  Trapezoidal: i_new - i_old = (h/2L)(v_new + v_old).
indcompanion(n: ref Net, p: ref Part, h: real): (real, real)
{
	if(n.method == "be"){
		geq := h/p.value;
		return (geq, p.iprev);
	}
	geq := h/(2.0*p.value);
	return (geq, p.iprev + geq*p.vprev);
}

nodevi(n: ref Net, i: int): real
{
	if(i <= 0)
		return 0.0;
	return n.x[i-1];
}

nodev(n: ref Net, name: string): real
{
	for(i := 0; i < n.nnodes; i++)
		if(n.names[i] == name)
			return nodevi(n, i);
	return 0.0;
}

partv(n: ref Net, p: ref Part): real
{
	return nodevi(n, p.a) - nodevi(n, p.b);
}

parti(n: ref Net, name: string): real
{
	for(k := 0; k < len n.parts; k++){
		p := n.parts[k];
		if(p.name != name)
			continue;
		case p.kind {
		Res =>
			return partv(n, p)/p.value;
		Isrc =>
			return p.value;
		Vsrc or Ind =>
			if(p.slot >= 0 && n.x != nil)
				return n.x[n.nnodes-1 + p.slot];
			return p.iprev;
		Cap =>
			return p.iprev;
		}
	}
	return 0.0;
}

dc(n: ref Net): string
{
	# an inductor is a short at DC and needs an unknown for its current,
	# the same as a voltage source; give it one for this solve
	saved := n.nsrc;
	for(k := 0; k < len n.parts; k++)
		if(n.parts[k].kind == Ind)
			n.parts[k].slot = n.nsrc++;
	e := assemble(n, 0.0, Dcop);
	if(e == nil){
		# keep what was found, or parti() of an inductor would answer
		# from a slot that is about to be taken away
		nn := n.nnodes - 1;
		for(k = 0; k < len n.parts; k++){
			p := n.parts[k];
			case p.kind {
			Ind =>	p.iprev = n.x[nn + p.slot];
				p.vprev = 0.0;
			Cap =>	p.vprev = partv(n, p);
				p.iprev = 0.0;
			}
		}
	}
	# put the slots back so a following transient is unaffected
	for(k = 0; k < len n.parts; k++)
		if(n.parts[k].kind == Ind)
			n.parts[k].slot = -1;
	n.nsrc = saved;
	return e;
}

# Solve with every storage element holding the state it already has, and
# fill in the half of that state the solve determines rather than the
# user: the current through each capacitor and the voltage across each
# inductor.  A student says "the circuit is off before the switch
# closes" and means no charge and no current STORED; they do not mean
# the current through the capacitor is zero, and at t=0 in an RC it is
# V/R.  Handing the trapezoidal rule a zero there is an error in the
# initial condition, not in the scheme, and it is invisible to backward
# Euler - which never reads i_old, and so looked like the better method.
icpoint(n: ref Net): string
{
	saved := n.nsrc;
	for(k := 0; k < len n.parts; k++)
		if(n.parts[k].kind == Cap)
			n.parts[k].slot = n.nsrc++;
	e := assemble(n, 0.0, Icop);
	if(e == nil){
		nn := n.nnodes - 1;
		for(k = 0; k < len n.parts; k++){
			p := n.parts[k];
			case p.kind {
			Cap =>	p.iprev = n.x[nn + p.slot];
			Ind =>	p.vprev = partv(n, p);
			}
		}
	}
	for(k = 0; k < len n.parts; k++)
		if(n.parts[k].kind == Cap)
			n.parts[k].slot = -1;
	n.nsrc = saved;
	return e;
}

begin(n: ref Net): string
{
	# At rest: nothing STORED.  That is not the DC operating point,
	# which is where the circuit ends up rather than where it starts.
	for(k := 0; k < len n.parts; k++){
		p := n.parts[k];
		p.vprev = 0.0;
		p.iprev = 0.0;
		case p.kind {
		Cap =>	p.vprev = p.ic;		# volts across it
		Ind =>	p.iprev = p.ic;		# amps through it
		}
	}
	n.t = 0.0;
	return icpoint(n);
}

# Start from the DC operating point instead - the switch has been closed
# a long time and something else is about to change.
beginfromdc(n: ref Net): string
{
	e := dc(n);
	if(e != nil)
		return e;
	n.t = 0.0;
	return icpoint(n);
}

step(n: ref Net, h: real): string
{
	if(h <= 0.0)
		return "a transient step must be positive";
	e := assemble(n, h, Tran);
	if(e != nil)
		return e;
	# update what each storage element remembers
	for(k := 0; k < len n.parts; k++){
		p := n.parts[k];
		case p.kind {
		Cap =>
			v := partv(n, p);
			(geq, ieq) := capcompanion(n, p, h);
			p.iprev = geq*v + ieq;
			p.vprev = v;
		Ind =>
			v := partv(n, p);
			(geq, ieq) := indcompanion(n, p, h);
			p.iprev = geq*v + ieq;
			p.vprev = v;
		}
	}
	n.t += h;
	return nil;
}
