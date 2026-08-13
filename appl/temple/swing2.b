implement Swing2;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Swing2: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Swing2: cannot load mechanism interface";
	c->init(ctxt,"swing2" :: "/dis/danby/swing2.dis" :: "danby-swing2" :: nil);
}
