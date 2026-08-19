implement Whitedwarf;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Whitedwarf: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/profile.dis";
	if(c == nil)
		raise "fail:Whitedwarf: cannot load profile interface";
	c->init(ctxt,"whitedwarf" :: "/dis/danby/plugin/whitedwarf.dis" :: "danby-whitedwarf" :: nil);
}
