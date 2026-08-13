implement Hovercraft;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Hovercraft: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/mechanism.dis";
	if(client == nil)
		raise "fail:Hovercraft: cannot load mechanism interface";
	client->init(ctxt,"hovercraft" :: "/dis/danby/hovercraft.dis" ::
		"danby-hovercraft" :: nil);
}
