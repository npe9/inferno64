# Create a Vanadium principal, self-bless, and print blessing names / encoded form.
# Inspired by: go run v.io/x/ref/cmd/principal
implement Principalcmd;

include "sys.m";
	sys: Sys;

include "draw.m";

include "arg.m";

include "keyring.m";
	kr: Keyring;

include "v23.m";
	v23: V23security;
	Principal, Blessings: import v23;

Principalcmd: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	v23 = load V23security V23security->PATH;
	if(v23 == nil)
		fail(sys->sprint("load v23security: %r"));
	if((e := v23->init()) != nil)
		fail(e);

	arg := load Arg Arg->PATH;
	arg->init(args);
	arg->setusage("v23/principal [-b bits] [-n name]");
	bits := 512;
	name := "principal";
	while((o := arg->opt()) != 0)
		case o {
		'b' =>
			bits = int arg->earg();
		'n' =>
			name = arg->earg();
		* =>
			arg->usage();
		}
	args = arg->argv();
	if(args != nil)
		arg->usage();

	(p, err) := v23->createprincipal(bits, name);
	if(p == nil)
		fail(err);
	(b, err2) := p.blessself(name, v23->unconstrained() :: nil);
	if(b == nil)
		fail(err2);
	p.setdefault(b);
	p.addroot(b);

	sys->print("public-key:\n%s\n", kr->pktostr(p.publickey()));
	sys->print("blessings:");
	for(n := v23->blessingnames(b); n != nil; n = tl n)
		sys->print(" %s", hd n);
	sys->print("\n");
	sys->print("%s", v23->encodeblessings(b));
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "v23/principal: %s\n", s);
	raise "fail:"+s;
}
