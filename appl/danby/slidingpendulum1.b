implement Slidingpendulum1;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Slidingpendulum1: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Slidingpendulum1: cannot load mechanism interface";
	c->init(ctxt,"slidingpendulum1" :: "/dis/danby/plugin/slidingpendulum1.dis" ::
		"danby-slidingpendulum1" :: nil);
}
