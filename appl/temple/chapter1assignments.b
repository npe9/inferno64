implement Chapter1assignments;

include "sys.m";
include "draw.m";

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Chapter1assignments: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	laboratory := load Command "/dis/temple/delab.dis";
	if(laboratory == nil)
		raise "fail:assignments";
	laboratory->init(ctxt,"chapter1assignments"::nil);
}
