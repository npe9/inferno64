implement Rotatingring1;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Rotatingring1: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Rotatingring1: cannot load mechanism interface";
	c->init(ctxt,"rotatingring1" :: "/dis/danby/rotatingring1.dis" :: "danby-rotatingring1" :: nil);
}
