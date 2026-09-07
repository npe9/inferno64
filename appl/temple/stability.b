implement Stabilityapp;

include "sys.m";
include "draw.m";

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Stabilityapp: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	# The modelling laboratory is appl/danby/stability.b, whose module is
	# named Modelinglab; there has never been an appl/temple/modelinglab.b.
	# This loaded /dis/temple/modelinglab.dis, a stale file from an older
	# layout, so the launcher had been dead since that file went.
	laboratory := load Command "/dis/danby/stability.dis";
	if(laboratory == nil)
		raise "fail:stability: cannot load /dis/danby/stability.dis";
	laboratory->init(ctxt,"modelinglab"::"stability"::nil);
}
