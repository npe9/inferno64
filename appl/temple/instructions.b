implement Instructions;

include "sys.m";
include "draw.m";

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Instructions: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	laboratory := load Command "/dis/temple/delab.dis";
	if(laboratory == nil)
		raise "fail:instructions";
	laboratory->init(ctxt,"instructions"::nil);
}
