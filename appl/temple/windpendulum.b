implement Windpendulum;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Windpendulum: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Windpendulum: cannot load mechanism interface";
	c->init(ctxt,"windpendulum" :: "/dis/danby/windpendulum.dis" ::
		"danby-windpendulum" :: nil);
}
