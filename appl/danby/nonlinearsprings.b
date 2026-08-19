implement Nonlinearsprings;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Nonlinearsprings: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Nonlinearsprings: cannot load mechanism interface";
	c->init(ctxt,"nonlinearsprings" :: "/dis/danby/plugin/nonlinearsprings.dis" ::
		"danby-nonlinearsprings" :: nil);
}
