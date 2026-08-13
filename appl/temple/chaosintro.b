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
	chaos := load Command "/dis/temple/chaos.dis";
	if(chaos == nil)
		raise "fail:chaosintro";
	chaos->init(ctxt,"chaos"::"chaosintro"::nil);
}
