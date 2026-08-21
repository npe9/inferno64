implement Uq;

include "sys.m";
	sys: Sys;
include "math.m";
	math: Math;
include "string.m";
	str: String;
include "rand.m";
	rand: Rand;
include "pde.m";
	pde: Pde;
	Problem: import pde;
include "uq.m";

init()
{
	if(sys == nil){
		sys = load Sys Sys->PATH;
		math = load Math Math->PATH;
		str = load String String->PATH;
		rand = load Rand Rand->PATH;
		pde = load Pde Pde->PATH;
		pde->init();
	}
}

words(s: string): array of string
{
	l := str->fields(s);
	a := array[len l] of string;
	for(i := 0; l != nil; (i,l) = (i+1,tl l))
		a[i] = hd l;
	return a;
}

# Uniform real in [0,1) from rand(2)'s integer generator.
uniform01(): real
{
	return real rand->rand(1000000000) / 1.0e9;
}

# Box-Muller: a standard normal deviate from two uniform draws.
stdnormal(): real
{
	u1 := uniform01();
	if(u1 < 1.0e-12)
		u1 = 1.0e-12;
	u2 := uniform01();
	return math->sqrt(-2.0*math->log(u1)) * math->cos(2.0*3.14159265358979323846*u2);
}

run(uqspec, template: string): (ref Summary, string)
{
	init();

	paramname := "";
	disttype := "";
	dp0 := 0.0;
	dp1 := 0.0;
	count := 0;
	seed := 1;
	until := 0.0;
	observekind := "";
	ox := 0;
	oy := 0;
	initkind := "";
	icx := 0;
	icy := 0;
	icradius := 0;
	icvalue := 0.0;

	for(rest := uqspec; rest != nil;){
		(line, tail) := str->splitl(rest, "\n");
		if(tail != nil)
			tail = tail[1:];
		rest = tail;
		a := words(line);
		if(len a == 0)
			continue;
		case a[0] {
		"sample" =>
			if(len a != 5)
				return (nil, "sample: usage: sample name uniform lo hi | sample name normal mean stddev");
			paramname = a[1];
			disttype = a[2];
			if(disttype != "uniform" && disttype != "normal")
				return (nil, "sample: distribution must be uniform or normal, got " + disttype);
			dp0 = real a[3];
			dp1 = real a[4];
		"count" =>
			if(len a != 2)
				return (nil, "count: usage: count n");
			count = int a[1];
		"seed" =>
			if(len a != 2)
				return (nil, "seed: usage: seed s");
			seed = int a[1];
		"until" =>
			if(len a != 2)
				return (nil, "until: usage: until t");
			until = real a[1];
		"observe" =>
			if(len a < 2)
				return (nil, "observe: usage: observe get x y | observe mean");
			observekind = a[1];
			case observekind {
			"get" =>
				if(len a != 4)
					return (nil, "observe get: usage: observe get x y");
				ox = int a[2];
				oy = int a[3];
			"mean" =>
				if(len a != 2)
					return (nil, "observe mean: usage: observe mean");
			* =>
				return (nil, "observe: unknown quantity " + observekind);
			}
		"init" =>
			if(len a < 2)
				return (nil, "init: usage: init clear value | init splat cx cy radius value");
			initkind = a[1];
			case initkind {
			"clear" =>
				if(len a != 3)
					return (nil, "init clear: usage: init clear value");
				icvalue = real a[2];
			"splat" =>
				if(len a != 6)
					return (nil, "init splat: usage: init splat cx cy radius value");
				icx = int a[2];
				icy = int a[3];
				icradius = int a[4];
				icvalue = real a[5];
			* =>
				return (nil, "init: unknown form " + initkind);
			}
		* =>
			return (nil, "unknown uq-spec line: " + a[0]);
		}
	}
	if(paramname == "")
		return (nil, "uq: spec has no sample line");
	if(count < 1)
		return (nil, "uq: spec has no count line, or count is not positive");
	if(observekind == "")
		return (nil, "uq: spec has no observe line");
	if(until <= 0.0)
		return (nil, "uq: spec has no until line, or until is not positive");

	rand->init(seed);
	values := array[count] of real;
	n := 0;
	nfailed := 0;
	token := "$" + paramname;
	for(i := 0; i < count; i++){
		draw: real;
		if(disttype == "uniform")
			draw = dp0 + (dp1-dp0)*uniform01();
		else
			draw = dp0 + dp1*stdnormal();
		spec := str->replace(template, token, sys->sprint("%.17g", draw), -1);
		(p, err) := pde->newproblem(spec);
		if(err != nil){
			nfailed++;
			continue;
		}
		case initkind {
		"clear" => pde->clear(p.field, icvalue);
		"splat" => pde->splat(p.field, icx, icy, icradius, icvalue);
		}
		(nil, err) = pde->run(p, until);
		if(err != nil){
			nfailed++;
			continue;
		}
		qoi: real;
		if(observekind == "get")
			qoi = pde->get(p.field, ox, oy);
		else
			qoi = fieldmean(p.field);
		values[n++] = qoi;
	}
	if(n == 0)
		return (nil, "uq: every draw failed - check the template and sample range");

	sum := 0.0;
	lo := values[0];
	hi := values[0];
	for(i = 0; i < n; i++){
		sum += values[i];
		if(values[i] < lo)
			lo = values[i];
		if(values[i] > hi)
			hi = values[i];
	}
	mean := sum/real n;
	variance := 0.0;
	for(i = 0; i < n; i++){
		d := values[i]-mean;
		variance += d*d;
	}
	if(n > 1)
		variance /= real (n-1);
	else
		variance = 0.0;
	return (ref Summary(n, nfailed, mean, math->sqrt(variance), lo, hi, values[0:n]), nil);
}

fieldmean(f: ref Pde->Field): real
{
	sum := 0.0;
	for(i := 0; i < len f.u; i++)
		sum += f.u[i];
	return sum/real len f.u;
}
