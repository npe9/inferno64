implement Javelin;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Javelin: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/trajectory.dis";
	if(client == nil)
		raise "fail:Javelin: cannot load trajectory interface";
	client->init(ctxt,"javelin" :: "/dis/danby/plugin/javelin.dis" ::
		"danby-javelin" :: nil);
}
