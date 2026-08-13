implement Skijump;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Skijump: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/trajectory.dis";
	if(client == nil)
		raise "fail:Skijump: cannot load trajectory interface";
	client->init(ctxt,"skijump" :: "/dis/danby/skijump.dis" ::
		"danby-skijump" :: nil);
}
