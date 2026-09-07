implement Chaosintro;

include "sys.m";
include "draw.m";

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Chaosintro: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	# The chaos program is appl/danby/lorenz.b, whose module used to be
	# named Chaos; there has never been an appl/temple/chaos.b.  This
	# loaded a stale /dis/temple/chaos.dis left by an older layout.
	chaos := load Command "/dis/danby/lorenz.dis";
	if(chaos == nil)
		raise "fail:chaosintro";
	chaos->init(ctxt,"chaos"::"chaosintro"::nil);
}
