implement Twomagnet;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Twomagnet: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Twomagnet: cannot load mechanism interface";
	c->init(ctxt,"twomagnet" :: "/dis/danby/plugin/twomagnet.dis" :: "danby-twomagnet" :: nil);
}
