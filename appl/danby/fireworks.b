implement Fireworks;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Fireworks: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/mechanism.dis";
	if(client == nil)
		raise "fail:Fireworks: cannot load mechanism interface";
	client->init(ctxt,"fireworks" :: "/dis/danby/plugin/fireworks.dis" ::
		"danby-fireworks" :: nil);
}
