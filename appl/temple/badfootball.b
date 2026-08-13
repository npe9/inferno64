implement Badfootball;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Badfootball: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/flight3d.dis";
	if(client == nil)
		raise "fail:Badfootball: cannot load flight3d interface";
	client->init(ctxt,"badfootball" :: "/dis/danby/badfootball.dis" ::
		"danby-badfootball" :: nil);
}
