implement Diving;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Diving: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/mechanism.dis";
	if(client == nil)
		raise "fail:Diving: cannot load mechanism interface";
	client->init(ctxt,"diving" :: "/dis/danby/plugin/diving.dis" ::
		"danby-diving" :: nil);
}
