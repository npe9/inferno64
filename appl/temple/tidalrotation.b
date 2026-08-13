implement Tidalrotation;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Tidalrotation: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Tidalrotation: cannot load mechanism interface";
	c->init(ctxt,"tidalrotation" :: "/dis/danby/tidalrotation.dis" ::
		"danby-tidalrotation" :: nil);
}
