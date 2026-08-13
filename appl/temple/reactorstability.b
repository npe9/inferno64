implement Reactorstability;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Reactorstability: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/populations.dis";
	if(c == nil)
		raise "fail:Reactorstability: cannot load populations interface";
	c->init(ctxt,"reactorstability" :: "/dis/danby/reactorstability.dis" :: "danby-reactorstability" :: nil);
}
