implement Icbmaccuracy;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Icbmaccuracy: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/flight3d.dis";
	if(c == nil)
		raise "fail:Icbmaccuracy: cannot load flight3d interface";
	c->init(ctxt,"icbmaccuracy" :: "/dis/danby/icbmaccuracy.dis" ::
		"danby-icbmaccuracy" :: nil);
}
