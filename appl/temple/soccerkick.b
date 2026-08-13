implement Soccerkick;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Soccerkick: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/flight3d.dis";
	if(client == nil)
		raise "fail:Soccerkick: cannot load flight3d interface";
	client->init(ctxt,"soccerkick" :: "/dis/danby/soccerkick.dis" ::
		"danby-soccerkick" :: nil);
}
