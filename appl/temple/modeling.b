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
	# The modelling laboratory is appl/danby/stability.b, whose module is
	# named Modelinglab; there has never been an appl/temple/modelinglab.b.
	laboratory := load Command "/dis/danby/stability.dis";
	if(laboratory == nil)
		raise "fail:modeling";
	laboratory->init(ctxt,"modelinglab"::"modeling"::nil);
}
