implement Discus;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Discus: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/trajectory.dis";
	if(client == nil)
		raise "fail:Discus: cannot load trajectory interface";
	client->init(ctxt,"discus" :: "/dis/danby/plugin/discus.dis" ::
		"danby-discus" :: nil);
}
