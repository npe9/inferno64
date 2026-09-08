implement Profilelabtest;

# profilelabtest - check every Danby radial structure model written as
# a profilelab(2) script.
#
# The models are one file each, and the model IS the SPEC constant in
# that file, so this reads the source and tests the string that ships,
# not a copy of it that could drift.  Extracting a Limbo string constant
# is a small price for that: the alternative is a test seam in every
# model, which is the sort of thing these models were rewritten to get
# rid of.
#
# Every model: the spec parses, it draws two curves, and the march it
# describes produces no NaN at any of its samples for any of twelve
# parameter settings.
#
# Then the two checks that matter, both of them things a sign error or a
# transposed term would break and nothing else would notice.  The
# enclosed mass can only ever increase outward, because a shell of
# non-negative density can only add to it; and where the spec asks for a
# normalisation, the normalised curve has to reach exactly 1 at the
# outermost sample, since that is the value it was divided by.  A profile
# that fell as it went out, or one whose normalisation quietly did
# nothing, would look perfectly plausible on the screen.

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
include "profilelab.m";
	profilelab: Profilelab;
	dynsys: Dynsys;
	Expr: import Hoc;
	Model: import dynsys;

Profilelabtest: module
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
	profilelab = load Profilelab Profilelab->PATH;
	dynsys = load Dynsys Dynsys->PATH;
	if(bufio == nil || readdir == nil || numerics == nil || math == nil ||
			profilelab == nil || dynsys == nil){
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
		fail("no ecolab models found in "+DIR);
	if(bad == 0)
		sys->print("OK   %d profilelab model specs\n", checked);
	else {
		sys->print("%d failures over %d models\n", bad, checked);
		raise "fail:profilelabtest";
	}
}

# specof: the SPEC constant of a profilelab model, or nil if this file is
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
			if(strstr(line, "profilelab->run") >= 0)
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
	(m, start, span, samples, normalised, err) := profilelab->parse(spec);
	if(err != nil){
		fail(name+": "+err);
		return;
	}
	if(len m.parameter == 0)
		fail(name+": no param commands");
	for(i := 0; i < len m.parameter; i++)
		if(m.minima[i] >= m.maxima[i])
			fail(sys->sprint("%s: param %s range %g..%g",
				name, m.paramlabels[i], m.minima[i], m.maxima[i]));
	if(len m.observablelabels != 2)
		fail(sys->sprint("%s: %d curves, not two", name, len m.observablelabels));
	# profilelab does not insist on a normalise line - a spec could
	# legitimately draw two curves that are already comparable - but
	# every model in THIS family plots an enclosed mass against a
	# density fraction, and one that forgot to normalise would put an
	# absolute mass on the same axis as a number that never leaves
	# 0..1, so the second curve would be a flat line along the bottom
	# or the first would be
	if(normalised < 0)
		fail(name+": no normalise line, so one curve is an absolute quantity sharing an axis with a fraction");
	if(verbose)
		sys->print("     %s: %d params, %d states, %d samples, normalising %d\n",
			name, len m.parameter, len m.statenames, samples, normalised);
	seed := 3312551;
	for(k := 0; k < 12; k++){
		if(k > 0)
			for(i = 0; i < len m.parameter; i++){
				seed = (seed*1103515245+12345)&16r7fffffff;
				m.parameter[i] = m.minima[i]+
					(m.maxima[i]-m.minima[i])*real(seed%1000)/1000.0;
			}
		d := profilelab->march(m, start, span, samples, normalised);
		what := sys->sprint("%s[%d]", name, k);
		for(i = 0; i < 3*samples; i++)
			if(d[i] != d[i]){
				fail(what+": sample "+string (i/3)+" is not a number");
				break;
			}
		# the radius only ever increases, and neither curve is
		# negative: a density is a density and a mass is a mass
		for(i = 1; i < samples; i++)
			if(d[3*i] <= d[3*(i-1)]){
				fail(sys->sprint("%s: radius does not increase at sample %d",
					what, i));
				break;
			}
		for(i = 0; i < samples; i++)
			if(d[3*i+1] < 0.0 || d[3*i+2] < 0.0){
				fail(sys->sprint("%s: negative value at sample %d, %.17g and %.17g",
					what, i, d[3*i+1], d[3*i+2]));
				break;
			}
		# the enclosed mass never falls: a shell of non-negative
		# density can only add to it
		mass := 1;
		if(normalised >= 0)
			mass = normalised;
		for(i = 1; i < samples; i++)
			if(d[3*i+1+mass] < d[3*(i-1)+1+mass]-1.0e-12){
				fail(sys->sprint("%s: %s falls at sample %d, %.17g then %.17g",
					what, m.observablelabels[mass], i,
					d[3*(i-1)+1+mass], d[3*i+1+mass]));
				break;
			}
		# and the outermost sample of the normalised curve is exactly
		# the 1 it was divided by
		if(normalised >= 0 && d[3*(samples-1)+1+normalised] != 0.0)
			near(what+": "+m.observablelabels[normalised]+" at the outer edge",
				d[3*(samples-1)+1+normalised], 1.0, 0.0);
	}
}

near(what: string, got, want, tol: real)
{
	d := got-want;
	if(d < 0.0)
		d = -d;
	if(d > tol)
		fail(sys->sprint("%s: got %.17g want %.17g", what, got, want));
}






