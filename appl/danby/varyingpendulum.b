implement Varyingpendulum;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Varyingpendulum: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Varyingpendulum: cannot load mechanism interface";
	c->init(ctxt,"varyingpendulum" :: "/dis/danby/plugin/varyingpendulum.dis" ::
		"danby-varyingpendulum" :: nil);
}
