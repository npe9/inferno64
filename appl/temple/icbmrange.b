implement Icbmrange;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Icbmrange: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/trajectory.dis";
	if(c == nil)
		raise "fail:Icbmrange: cannot load trajectory interface";
	c->init(ctxt,"icbmrange" :: "/dis/danby/icbmrange.dis" :: "danby-icbmrange" :: nil);
}
