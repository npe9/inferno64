implement Poplabtest;

# poplabtest - check every Danby population model written as a poplab(2)
# script.
#
# The models are one file each, and the model IS the SPEC constant in
# that file, so this reads the source and tests the string that ships,
# not a copy of it that could drift.  Extracting a Limbo string constant
# is a small price for that: the alternative is a test seam in every
# model, which is the sort of thing these models were rewritten to get
# rid of.
#
# Every model: the spec parses, its parameters have sane ranges and
# defaults, and its derivative is finite at its own initial state.  Two
# carry a property of their own, moved here from danbytest with the
# models: childcare's derivative must be zero when every population is,
# and each model must have the number of states its curriculum page
# says.

include "sys.m";
	sys: Sys;
include "draw.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "readdir.m";
	readdir: Readdir;
include "numerics.m";
	numerics: Numerics;
include "math.m";
	math: Math;
include "poplab.m";
	poplab: Poplab;
	dynsys: Dynsys;
	Model: import dynsys;

Poplabtest: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

DIR: con "/appl/danby";

bad := 0;
verbose := 0;

fail(s: string)
{
	sys->print("FAIL %s\n", s);
	bad++;
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	readdir = load Readdir Readdir->PATH;
	numerics = load Numerics Numerics->PATH;
	math = load Math Math->PATH;
	poplab = load Poplab Poplab->PATH;
	dynsys = load Dynsys Dynsys->PATH;
	if(bufio == nil || readdir == nil || numerics == nil || math == nil ||
			poplab == nil || dynsys == nil){
		sys->print("FAIL load: %r\n");
		raise "fail:load";
	}
	for(a := tl argv; a != nil; a = tl a)
		if(hd a == "-v")
			verbose = 1;

	(d, n) := readdir->init(DIR, Readdir->NAME);
	if(n <= 0){
		sys->print("FAIL cannot read %s: %r\n", DIR);
		raise "fail:readdir";
	}
	checked := 0;
	for(i := 0; i < n; i++){
		name := d[i].name;
		if(len name < 3 || name[len name-2:] != ".b")
			continue;
		spec := specof(DIR+"/"+name);
		if(spec == nil)
			continue;
		checked++;
		checkspec(name[0:len name-2], spec);
	}
	if(checked == 0)
		fail("no poplab models found in "+DIR);
	if(bad == 0)
		sys->print("OK   %d poplab model specs\n", checked);
	else {
		sys->print("%d failures over %d models\n", bad, checked);
		raise "fail:poplabtest";
	}
}

# specof: the SPEC constant of a mechlab model, or nil if this file is
# not one.  A Limbo string constant is quoted segments joined with +,
# possibly with # comment lines between them, ending at the ; that
# closes the declaration.
specof(path: string): string
{
	iob := bufio->open(path, Bufio->OREAD);
	if(iob == nil)
		return nil;
	ismodel := 0;
	inspec := 0;
	spec := "";
	while((line := iob.gets('\n')) != nil){
		if(!inspec && len line >= 9 && line[0:9] == "SPEC: con"){
			inspec = 1;
			line = line[9:];
		}else if(!inspec){
			if(strstr(line, "poplab->run") >= 0)
				ismodel = 1;
			continue;
		}
		(seg, done) := quoted(line);
		spec += seg;
		if(done)
			inspec = 0;
	}
	if(!ismodel)
		return nil;
	return spec;
}

# quoted: the concatenation of every double-quoted segment on one line,
# with \n understood, and whether the line ends the declaration.
quoted(line: string): (string, int)
{
	s := "";
	i := 0;
	for(; i < len line; i++){
		if(line[i] == '#')
			break;
		if(line[i] == ';')
			return (s, 1);
		if(line[i] != '"')
			continue;
		for(i++; i < len line && line[i] != '"'; i++){
			if(line[i] == '\\' && i+1 < len line){
				i++;
				case line[i] {
				'n' => s[len s] = '\n';
				't' => s[len s] = '\t';
				* => s[len s] = line[i];
				}
				continue;
			}
			s[len s] = line[i];
		}
	}
	return (s, 0);
}

strstr(s, sub: string): int
{
	for(i := 0; i+len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return i;
	return -1;
}

checkspec(name, spec: string)
{
	(m, err) := poplab->parse(spec);
	if(err != nil){
		fail(name+": "+err);
		return;
	}
	if(len m.parameter == 0)
		fail(name+": no param commands");
	for(i := 0; i < len m.parameter; i++){
		if(m.minima[i] >= m.maxima[i])
			fail(sys->sprint("%s: param %s range %g..%g",
				name, m.paramlabels[i], m.minima[i], m.maxima[i]));
		if(m.parameter[i] < m.minima[i] || m.parameter[i] > m.maxima[i])
			fail(sys->sprint("%s: param %s default %g outside %g..%g",
				name, m.paramlabels[i], m.parameter[i],
				m.minima[i], m.maxima[i]));
	}
	state := dynsys->initialstate(m);
	deriv := array[len state] of real;
	dynsys->rhs(m, 0.0, state, deriv);
	for(i = 0; i < len deriv; i++)
		if(deriv[i] != deriv[i])
			fail(sys->sprint("%s: derivative %s is not a number at t=0",
				name, m.statenames[i]));
	if(verbose)
		sys->print("     %s: %d params, %d states\n",
			name, len m.parameter, len m.statenames);
	checkstates(name, m);
	case name {
	"childcare" =>
		checkempty(name, m);
	"fishingone" =>
		checkfishery(name, m);
	"diseasebirthdeath1" =>
		# births balance deaths exactly, so the head count is a first
		# integral: the three rates must sum to zero
		checksum(name, m, 0.0);
	"diseasebirthdeath2" =>
		# births, deaths and virulence are independent, so the head
		# count changes at (birth - natural death) less what the disease
		# kills
		# at the same state checksum uses below
		p := m.parameter;
		checksum(name, m, (p[2]-p[3])-p[4]*0.15);
	}
}

# At the bionomic equilibrium - the stock at which the price of a catch
# just covers its cost, and the effort that holds the stock there -
# nothing moves.
checkfishery(name: string, m: ref Model)
{
	p := m.parameter;
	stock := p[4]/(p[3]*p[2]);
	effort := p[0]*(1.0-stock/p[1])/p[2];
	state := array[] of {stock, effort};
	deriv := array[len state] of real;
	dynsys->rhs(m, 0.0, state, deriv);
	for(i := 0; i < len deriv; i++){
		d := deriv[i];
		if(d < 0.0)
			d = -d;
		if(d > 1.0e-12)
			fail(sys->sprint("%s: d%s/dt is %g at the bionomic equilibrium",
				name, m.statenames[i], deriv[i]));
	}
}

checksum(name: string, m: ref Model, want: real)
{
	state := dynsys->initialstate(m);
	# the same state danbytest used, so the numbers are comparable
	if(len state == 3){
		state[0] = 0.8;
		state[1] = 0.15;
		state[2] = 0.05;
	}
	deriv := array[len state] of real;
	dynsys->rhs(m, 0.0, state, deriv);
	total := 0.0;
	for(i := 0; i < len deriv; i++)
		total += deriv[i];
	d := total-want;
	if(d < 0.0)
		d = -d;
	if(d > 1.0e-14)
		fail(sys->sprint("%s: the rates sum to %.17g, expected %.17g",
			name, total, want));
}

# Every population model's own state count, which is what its curriculum
# page describes and what danbytest used to assert one call at a time.
statecounts := array[] of {
	"brusselator", "2",
	"budworm", "1",
	"cannibalism", "2",
	"changingenvironment", "1",
	"childcare", "3",
	"crossinfection", "4",
	"decomposition", "3",
	"diseasebirthdeath1", "3",
	"diseasebirthdeath2", "3",
	"enzymeapplication", "6",
	"enzymekinetics", "4",
	"fishingone", "2",
	"fishingtwo", "3",
	"foodchain", "3",
	"moreenzyme", "4",
	"stillmoreenzyme", "5",
};

checkstates(name: string, m: ref Model)
{
	for(i := 0; i+1 < len statecounts; i += 2)
		if(statecounts[i] == name){
			want := int statecounts[i+1];
			if(len m.statenames != want)
				fail(sys->sprint("%s: %d states, expected %d",
					name, len m.statenames, want));
			return;
		}
}

# An empty population stays empty: with every state at zero, every rate
# is zero.  A model whose growth term is not proportional to a population
# would fail this, which is the point of asking.
checkempty(name: string, m: ref Model)
{
	state := array[len m.statenames] of real;
	for(i := 0; i < len state; i++)
		state[i] = 0.0;
	deriv := array[len state] of real;
	dynsys->rhs(m, 0.0, state, deriv);
	for(i = 0; i < len deriv; i++)
		if(deriv[i] != 0.0)
			fail(sys->sprint("%s: d%s/dt is %g with every population at zero",
				name, m.statenames[i], deriv[i]));
}

