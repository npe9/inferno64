implement Dampedpendulum;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Dampedpendulum: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Dampedpendulum: cannot load mechanism interface";
	c->init(ctxt,"dampedpendulum" :: "/dis/danby/dampedpendulum.dis" ::
		"danby-dampedpendulum" :: nil);
}
