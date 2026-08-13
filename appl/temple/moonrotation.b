implement Moonrotation;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Moonrotation: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Moonrotation: cannot load mechanism interface";
	c->init(ctxt,"moonrotation" :: "/dis/danby/moonrotation.dis" ::
		"danby-moonrotation" :: nil);
}
