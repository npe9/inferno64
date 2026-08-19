implement Fireflies;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Fireflies: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Fireflies: cannot load mechanism interface";
	c->init(ctxt,"fireflies" :: "/dis/danby/plugin/fireflies.dis" :: "danby-fireflies" :: nil);
}
