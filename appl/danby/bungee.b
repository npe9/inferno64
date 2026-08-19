implement Bungee;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Bungee: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/mechanism.dis";
	if(client == nil)
		raise "fail:Bungee: cannot load mechanism interface";
	client->init(ctxt,"bungee" :: "/dis/danby/plugin/bungee.dis" :: "danby-bungee" :: nil);
}
