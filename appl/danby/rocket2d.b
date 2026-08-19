implement Rocket2d;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Rocket2d: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/trajectory.dis";
	if(c == nil)
		raise "fail:Rocket2d: cannot load trajectory interface";
	c->init(ctxt,"rocket2d" :: "/dis/danby/plugin/rocket2d.dis" :: "danby-rocket2d" :: nil);
}
