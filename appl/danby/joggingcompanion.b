implement Joggingcompanion;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Joggingcompanion: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/mechanism.dis";
	if(client == nil)
		raise "fail:Joggingcompanion: cannot load mechanism interface";
	client->init(ctxt,"joggingcompanion" :: "/dis/danby/plugin/joggingcompanion.dis" ::
		"danby-joggingcompanion" :: nil);
}
