implement Ipinttest;

#
# ipinttest - the arithmetic a Limbo program can ask IPint for that the
# C library underneath answers with sysfatal.
#
# libmp stops the machine for four of them: a division or a remainder
# by zero, a modular exponentiation with a negative exponent, and an
# inverse that does not exist.  On hosted emu that kills the process;
# on a native kernel sysfatal is a panic, so one line of Limbo could
# stop a booted machine.  keyring(2)'s IPint checks first and raises an
# exception instead, and this is the test that says so: each case is
# run inside a handler, and a case that returns normally or takes the
# machine with it is a failure either way.
#
# Every one of them has a positive control beside it -- the same
# operation with a legal argument -- so a build that raised for
# everything would fail here rather than pass.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
	kr: Keyring;
	IPint: import kr;

Ipinttest: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

Mod, Div, Mulmod, Addmod, Submod, Expmod, Invert: con iota;

Op: adt {
	kind:	int;
	a:	ref IPint;
	b:	ref IPint;
	m:	ref IPint;

	run:	fn(o: self ref Op): string;
};

nfail := 0;

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	if(kr == nil){
		sys->print("ipinttest: load keyring: %r\n");
		raise "fail:load";
	}

	zero := IPint.inttoip(0);
	one := IPint.inttoip(1);
	seven := IPint.inttoip(7);
	twelve := IPint.inttoip(12);
	fifteen := IPint.inttoip(15);

	# the four that used to be fatal
	mustraise("mod by zero", ref Op(Mod, seven, zero, nil));
	mustraise("div by zero", ref Op(Div, seven, zero, nil));
	mustraise("mulmod by zero", ref Op(Mulmod, seven, seven, zero));
	mustraise("addmod by zero", ref Op(Addmod, seven, seven, zero));
	mustraise("submod by zero", ref Op(Submod, seven, seven, zero));
	mustraise("expmod with a zero modulus", ref Op(Expmod, seven, seven, zero));
	mustraise("expmod with a negative exponent",
		ref Op(Expmod, seven, zero.sub(one), fifteen));
	mustraise("invert with a zero modulus", ref Op(Invert, seven, zero, nil));
	# 12 and 15 share the factor 3, so 12 has no inverse mod 15
	mustraise("invert where no inverse exists", ref Op(Invert, twelve, fifteen, nil));

	# the controls: the same operations, legal arguments
	returns("mod", ref Op(Mod, seven, fifteen, nil), "7");
	returns("div", ref Op(Div, fifteen, seven, nil), "2");
	returns("mulmod", ref Op(Mulmod, seven, seven, fifteen), "4");
	returns("addmod", ref Op(Addmod, seven, seven, fifteen), "14");
	returns("submod", ref Op(Submod, seven, twelve, fifteen), "10");
	returns("expmod", ref Op(Expmod, seven, seven, fifteen), "13");
	# a zero exponent is legal and gives 1; mpexp tests the exponent
	# against zero with a comparison, and so does the guard, so this
	# is the case that would break if the guard used a sign field
	returns("expmod with a zero exponent", ref Op(Expmod, seven, zero, fifteen), "1");
	# 7*13 = 91 = 6*15+1, so 13 is 7's inverse mod 15
	returns("invert", ref Op(Invert, seven, fifteen, nil), "13");

	if(nfail != 0){
		sys->print("ipinttest: %d FAILED\n", nfail);
		raise "fail:test";
	}
	sys->print("ipinttest: ok\n");
}

# the operation, with its answer in base 10; a raise comes out of here
# to the caller, which is the whole point
Op.run(o: self ref Op): string
{
	r: ref IPint;
	case o.kind {
	Mod =>		r = o.a.mod(o.b);
	Div =>		(r, nil) = o.a.div(o.b);
	Mulmod =>	r = o.a.mulmod(o.b, o.m);
	Addmod =>	r = o.a.addmod(o.b, o.m);
	Submod =>	r = o.a.submod(o.b, o.m);
	Expmod =>	r = o.a.expmod(o.b, o.m);
	Invert =>	r = o.a.invert(o.b);
	}
	return r.iptostr(10);
}

mustraise(what: string, o: ref Op)
{
	s: string;
	{
		s = o.run();
	} exception e {
	"*" =>
		sys->print("\t%-38s ok (%s)\n", what, e);
		return;
	}
	sys->print("\t%-38s FAIL (returned %s)\n", what, s);
	nfail++;
}

returns(what: string, o: ref Op, want: string)
{
	{
		got := o.run();
		if(got == want)
			sys->print("\t%-38s ok (%s)\n", what, got);
		else {
			sys->print("\t%-38s FAIL (got %s want %s)\n", what, got, want);
			nfail++;
		}
	} exception e {
	"*" =>
		sys->print("\t%-38s FAIL (raised %s)\n", what, e);
		nfail++;
	}
}
