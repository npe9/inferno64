implement Lagrange1;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Lagrange1: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/orbital.dis";
	if(client == nil)
		raise "fail:Lagrange1: cannot load orbital interface";
	client->init(ctxt,"lagrange1" :: "/dis/danby/plugin/lagrange1.dis" :: "danby-lagrange1" :: nil);
}
