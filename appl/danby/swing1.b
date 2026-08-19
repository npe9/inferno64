implement Swing1;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Swing1: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Swing1: cannot load mechanism interface";
	c->init(ctxt,"swing1" :: "/dis/danby/plugin/swing1.dis" :: "danby-swing1" :: nil);
}
