implement Skylab;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Skylab: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/trajectory.dis";
	if(c == nil)
		raise "fail:Skylab: cannot load trajectory interface";
	c->init(ctxt,"skylab" :: "/dis/danby/plugin/skylab.dis" :: "danby-skylab" :: nil);
}
