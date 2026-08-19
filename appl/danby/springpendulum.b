implement Springpendulum;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Springpendulum: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Springpendulum: cannot load mechanism interface";
	c->init(ctxt,"springpendulum" :: "/dis/danby/plugin/springpendulum.dis" ::
		"danby-springpendulum" :: nil);
}
