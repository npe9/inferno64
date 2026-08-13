implement Modeling;

include "sys.m";
include "draw.m";

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Modeling: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	laboratory := load Command "/dis/temple/modelinglab.dis";
	if(laboratory == nil)
		raise "fail:modeling";
	laboratory->init(ctxt,"modelinglab"::"modeling"::nil);
}
