implement Oregonator;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Oregonator: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/populations.dis";
	if(c == nil)
		raise "fail:Oregonator: cannot load populations interface";
	c->init(ctxt,"oregonator" :: "/dis/danby/oregonator.dis" :: "danby-oregonator" :: nil);
}
