implement Brusselator;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Brusselator: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/populations.dis";
	if(c == nil)
		raise "fail:Brusselator: cannot load populations interface";
	c->init(ctxt,"brusselator" :: "/dis/danby/brusselator.dis" :: "danby-brusselator" :: nil);
}
