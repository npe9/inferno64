implement Basketball;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Basketball: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/trajectory.dis";
	if(client == nil)
		raise "fail:Basketball: cannot load trajectory interface";
	client->init(ctxt,"basketball" :: "/dis/danby/plugin/basketball.dis" ::
		"danby-basketball" :: nil);
}
