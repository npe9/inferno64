implement Spaceyoyo;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Spaceyoyo: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Spaceyoyo: cannot load mechanism interface";
	c->init(ctxt,"spaceyoyo" :: "/dis/danby/spaceyoyo.dis" :: "danby-spaceyoyo" :: nil);
}
