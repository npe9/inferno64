implement Tabletennis;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Tabletennis: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/trajectory.dis";
	if(client == nil)
		raise "fail:Tabletennis: cannot load trajectory interface";
	client->init(ctxt,"tabletennis" :: "/dis/danby/tabletennis.dis" ::
		"danby-tabletennis" :: nil);
}
