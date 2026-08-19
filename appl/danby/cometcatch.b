implement Cometcatch;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Cometcatch: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/orbital.dis";
	if(c == nil)
		raise "fail:Cometcatch: cannot load orbital interface";
	c->init(ctxt,"cometcatch" :: "/dis/danby/plugin/cometcatch.dis" :: "danby-cometcatch" :: nil);
}
