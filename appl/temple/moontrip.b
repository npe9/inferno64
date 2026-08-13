implement Moontrip;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Moontrip: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/orbital.dis";
	if(client == nil)
		raise "fail:Moontrip: cannot load orbital interface";
	client->init(ctxt,"moontrip" :: "/dis/danby/moontrip.dis" :: "danby-moontrip" :: nil);
}
