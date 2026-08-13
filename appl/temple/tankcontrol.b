implement Tankcontrol;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Tankcontrol: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/populations.dis";
	if(c == nil)
		raise "fail:Tankcontrol: cannot load populations interface";
	c->init(ctxt,"tankcontrol" :: "/dis/danby/tankcontrol.dis" :: "danby-tankcontrol" :: nil);
}
