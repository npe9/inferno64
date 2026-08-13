implement Existence;

include "sys.m";
include "draw.m";

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Existence: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	laboratory := load Command "/dis/temple/delab.dis";
	if(laboratory == nil)
		raise "fail:existence";
	laboratory->init(ctxt,"existence"::nil);
}
