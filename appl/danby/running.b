implement Running;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Running: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/mechanism.dis";
	if(client == nil)
		raise "fail:Running: cannot load mechanism interface";
	client->init(ctxt,"running" :: "/dis/danby/plugin/running.dis" ::
		"danby-running" :: nil);
}
