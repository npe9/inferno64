implement Reservoir;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Reservoir: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/populations.dis";
	if(c == nil)
		raise "fail:Reservoir: cannot load populations interface";
	c->init(ctxt,"reservoir" :: "/dis/danby/plugin/reservoir.dis" :: "danby-reservoir" :: nil);
}
