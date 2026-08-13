implement Flight;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Flight: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/mechanism.dis";
	if(client == nil)
		raise "fail:Flight: cannot load mechanism interface";
	client->init(ctxt,"flight" :: "/dis/danby/flight.dis" ::
		"danby-flight" :: nil);
}
