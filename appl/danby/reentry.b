implement Reentry;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Reentry: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/trajectory.dis";
	if(c == nil)
		raise "fail:Reentry: cannot load trajectory interface";
	c->init(ctxt,"reentry" :: "/dis/danby/plugin/reentry.dis" :: "danby-reentry" :: nil);
}
