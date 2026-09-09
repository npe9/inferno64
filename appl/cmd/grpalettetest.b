implement Grpalettetest;

# Checks grpalette(2): that EGA is still the sixteen colours the ports had
# written into them, that RICH did not quietly change what an index means,
# and that the true-colour arithmetic behaves at its endpoints.
#
# The EGA table below is an independent copy of the literal that stood in
# appl/temple/*.b before the module existed.  It is deliberately not read
# from the module - a test that asks the module for the answer and then
# compares it with the module's answer checks nothing.

include "sys.m";
	sys: Sys;

include "draw.m";

include "env.m";
	env: Env;

include "grpalette.m";
	grpal: Grpalette;

Grpalettetest: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

fail := 0;
total := 0;
verbose := 0;

# The literal, as it stood in fifty-one ports.
was := array[] of {
	int 16r000000FF, int 16r0000AAFF, int 16r00AA00FF, int 16r00AAAAFF,
	int 16rAA0000FF, int 16rAA00AAFF, int 16rAA5500FF, int 16rAAAAAAFF,
	int 16r555555FF, int 16r5555FFFF, int 16r55FF55FF, int 16r55FFFFFF,
	int 16rFF5555FF, int 16rFF55FFFF, int 16rFFFF55FF, int 16rFFFFFFFF
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	env = load Env Env->PATH;
	grpal = load Grpalette Grpalette->PATH;
	if(grpal == nil){
		sys->fprint(sys->fildes(2), "grpalettetest: cannot load %s: %r\n",
			Grpalette->PATH);
		raise "fail:load";
	}
	for(a := tl argv; a != nil; a = tl a)
		if(hd a == "-v")
			verbose = 1;
	grpal->init();

	envknob();
	egaexact();
	richidentity();
	registers();
	arithmetic();

	sys->print("grpalettetest: %d/%d\n", total-fail, total);
	if(fail)
		raise "fail:test";
}

ok(what: string, cond: int)
{
	total++;
	if(!cond){
		fail++;
		sys->print("FAIL %s\n", what);
	}else if(verbose)
		sys->print("ok   %s\n", what);
}

okv(what: string, got, want: int)
{
	total++;
	if(got != want){
		fail++;
		sys->print("FAIL %s: got %ux want %ux\n", what, got, want);
	}else if(verbose)
		sys->print("ok   %s = %ux\n", what, got);
}

# $grpalette selects the palette a session starts in; unset means RICH.
envknob()
{
	want := Grpalette->RICH;
	if(env != nil)
		case env->getenv("grpalette") {
		"ega" or "EGA" =>	want = Grpalette->EGA;
		"grey" or "gray" =>	want = Grpalette->GREY;
		}
	ok("default palette follows $grpalette", grpal->loaded() == want);
}

# The claim every port's fidelity rests on.
egaexact()
{
	grpal->set(Grpalette->EGA);
	v := grpal->values();
	ok("EGA has sixteen entries", len v == 16);
	for(i := 0; i < 16 && i < len v; i++)
		okv("EGA " + grpal->name(i), v[i], was[i]);
	t := grpal->table(Grpalette->EGA);
	for(i = 0; i < 16 && i < len t; i++)
		okv("EGA table " + grpal->name(i), t[i], was[i]);
	ok("loaded() reports EGA", grpal->loaded() == Grpalette->EGA);
}

lum(v: int): int
{
	r := (v>>24)&16rFF;
	g := (v>>16)&16rFF;
	b := (v>>8)&16rFF;
	return 2126*r + 7152*g + 722*b;
}

# RICH may look different; it may not mean anything different.  An index
# has to keep its hue, keep its place in the dim/bright pair, and keep
# black and white exact so palette black and Draw->Black cannot drift.
richidentity()
{
	r := grpal->table(Grpalette->RICH);
	e := grpal->table(Grpalette->EGA);
	ok("RICH has sixteen entries", len r == 16);
	okv("RICH BLACK is exact", r[Grpalette->BLACK], int 16r000000FF);
	okv("RICH WHITE is exact", r[Grpalette->WHITE], int 16rFFFFFFFF);
	for(i := 0; i < 16; i++){
		okv("RICH " + grpal->name(i) + " is opaque", r[i]&16rFF, 16rFF);
		# hue: wherever EGA ranks one channel above another, RICH must
		# not reverse it.  An ordering, not a ratio, so a hue can be
		# adjusted but not swapped for a different colour.  Channels
		# EGA holds equal are free - EGA is coarse enough that BLUE
		# has r and g both at zero, and RICH is not obliged to.
		ok("RICH " + grpal->name(i) + " keeps its channel order",
			sameorder(e[i], r[i]));
	}
	# i and i+8 are the same colour dim and bright.
	for(i = 0; i < 8; i++)
		ok("RICH " + grpal->name(i) + " is darker than " + grpal->name(i+8),
			lum(r[i]) < lum(r[i+8]));
	ok("RICH differs from EGA somewhere", differs(r, e));
}

# does b reverse any channel ordering that a states?
sameorder(a, b: int): int
{
	for(s1 := 8; s1 <= 24; s1 += 8)
		for(s2 := 8; s2 <= 24; s2 += 8){
			ca := (a>>s1)&16rFF;
			cb := (a>>s2)&16rFF;
			da := (b>>s1)&16rFF;
			db := (b>>s2)&16rFF;
			if(ca < cb && da >= db)
				return 0;
			if(ca > cb && da <= db)
				return 0;
		}
	return 1;
}

differs(a, b: array of int): int
{
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 1;
	return 0;
}

# GrPaletteColorSet: a register is writable, and writing one means no
# named palette is loaded any more.
registers()
{
	grpal->set(Grpalette->EGA);
	grpal->setcolour(Grpalette->RED, int 16r123456FF);
	okv("setcolour writes the register", grpal->value(Grpalette->RED),
		int 16r123456FF);
	ok("setcolour clears the loaded palette", grpal->loaded() == -1);
	okv("setcolour leaves its neighbours", grpal->value(Grpalette->GREEN),
		int 16r00AA00FF);
	grpal->set(Grpalette->EGA);
	okv("set() puts the register back", grpal->value(Grpalette->RED),
		int 16rAA0000FF);
	okv("value() wraps like a four-bit index",
		grpal->value(Grpalette->RED+16), grpal->value(Grpalette->RED));

	g := grpal->table(Grpalette->GREY);
	okv("GREY starts black", g[0], int 16r000000FF);
	okv("GREY ends white", g[15], int 16rFFFFFFFF);
	for(i := 1; i < 16; i++)
		ok("GREY rises at " + string i, lum(g[i]) > lum(g[i-1]));
}

arithmetic()
{
	v := int 16r4080C0FF;
	okv("shade at 1 is the colour", grpal->shade(v, 1.0), v);
	okv("shade at 0 is black", grpal->shade(v, 0.0), int 16r000000FF);
	okv("shade below 0 clamps to black", grpal->shade(v, -3.0), int 16r000000FF);
	okv("shade at 2 is white", grpal->shade(v, 2.0), int 16rFFFFFFFF);
	okv("shade above 2 clamps to white", grpal->shade(v, 9.0), int 16rFFFFFFFF);
	ok("shade keeps alpha", (grpal->shade(v, 0.3)&16rFF) == 16rFF);
	last := -1;
	mono := 1;
	for(i := 0; i <= 20; i++){
		l := lum(grpal->shade(v, real i/10.0));
		if(l < last)
			mono = 0;
		last = l;
	}
	ok("shade is monotonic in lit", mono);

	a := int 16r000000FF;
	b := int 16rFFFFFFFF;
	okv("mix at 0 is a", grpal->mix(a, b, 0.0), a);
	okv("mix at 1 is b", grpal->mix(a, b, 1.0), b);
	okv("mix below 0 clamps", grpal->mix(a, b, -1.0), a);
	okv("mix above 1 clamps", grpal->mix(a, b, 2.0), b);
	okv("dither is the midpoint", grpal->dither(a, b), grpal->mix(a, b, 0.5));
	ok("dither of a colour with itself is that colour",
		grpal->dither(v, v) == v);
	# The property the ports' shade ramps rest on: a run of mixes
	# between two registers must actually be that many different
	# colours.  A 4x4 ordered dither of two entries can only express
	# seventeen mixes and only as a stipple; this is the same ramp as
	# one colour a step.
	rmp := array[65] of int;
	for(ri := 0; ri < len rmp; ri++)
		rmp[ri] = grpal->mix(grpal->value(Grpalette->BLACK),
			grpal->value(Grpalette->LTBLUE), real ri/64.0);
	nd := 0;
	for(ri = 0; ri < len rmp; ri++){
		seen := 0;
		for(rj := 0; rj < ri; rj++)
			if(rmp[rj] == rmp[ri])
				seen = 1;
		if(!seen)
			nd++;
	}
	ok("a 65-step ramp is 65 distinct colours", nd == 65);
	rmono := 1;
	for(ri = 1; ri < len rmp; ri++)
		if(lum(rmp[ri]) < lum(rmp[ri-1]))
			rmono = 0;
	ok("a ramp rises without a step back", rmono);

	# The trap rgba() exists for: a computed white must equal a written
	# one.  int is 64 bits wide at run time here, so an unextended
	# 16rFFFFFFFF is 4294967295 and compares unequal to the literal -1
	# while printing the same eight hex digits.
	ok("a computed white is the literal white",
		grpal->shade(int 16r808080FF, 4.0) == int 16rFFFFFFFF);
	ok("a computed colour is sign-extended like a literal",
		grpal->mix(int 16rFF0000FF, int 16rFFFFFFFF, 1.0) == int 16rFFFFFFFF);

	# the dither pair TempleOS used for a colour it did not have: half
	# way between two registers is a colour neither of them is.
	d := grpal->dither(grpal->value(Grpalette->RED), grpal->value(Grpalette->YELLOW));
	ok("a dithered pair is between its two registers",
		lum(d) > lum(grpal->value(Grpalette->RED)) &&
		lum(d) < lum(grpal->value(Grpalette->YELLOW)));
}
