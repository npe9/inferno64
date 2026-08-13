implement Carrierlanding;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Carrierlanding: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Carrierlanding: cannot load mechanism interface";
	c->init(ctxt,"carrierlanding" :: "/dis/danby/carrierlanding.dis" ::
		"danby-carrierlanding" :: nil);
}
