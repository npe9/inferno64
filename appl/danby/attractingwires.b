implement Attractingwires;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Attractingwires: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Attractingwires: cannot load mechanism interface";
	c->init(ctxt,"attractingwires" :: "/dis/danby/plugin/attractingwires.dis" ::
		"danby-attractingwires" :: nil);
}
