implement Shipmotion;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Shipmotion: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/mechanism.dis";
	if(client == nil)
		raise "fail:Shipmotion: cannot load mechanism interface";
	client->init(ctxt,"shipmotion" :: "/dis/danby/plugin/shipmotion.dis" ::
		"danby-shipmotion" :: nil);
}
