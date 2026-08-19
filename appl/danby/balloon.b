implement Balloon;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Balloon: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/mechanism.dis";
	if(client == nil)
		raise "fail:Balloon: cannot load mechanism interface";
	client->init(ctxt,"balloon" :: "/dis/danby/plugin/balloon.dis" ::
		"danby-balloon" :: nil);
}
