implement Cricketswing;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Cricketswing: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/flight3d.dis";
	if(client == nil)
		raise "fail:Cricketswing: cannot load flight3d interface";
	client->init(ctxt,"cricketswing" :: "/dis/danby/cricketswing.dis" ::
		"danby-cricketswing" :: nil);
}
