implement Yoyo;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Yoyo: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/mechanism.dis";
	if(client == nil)
		raise "fail:Yoyo: cannot load mechanism interface";
	client->init(ctxt,"yoyo" :: "/dis/danby/plugin/yoyo.dis" :: "danby-yoyo" :: nil);
}
