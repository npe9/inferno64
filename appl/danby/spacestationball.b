implement Spacestationball;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Spacestationball: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/mechanism.dis";
	if(client == nil)
		raise "fail:Spacestationball: cannot load mechanism interface";
	client->init(ctxt,"spacestationball" :: "/dis/danby/plugin/spacestationball.dis" ::
		"danby-spacestationball" :: nil);
}
