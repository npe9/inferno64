implement Pegpendulum;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Pegpendulum: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Pegpendulum: cannot load mechanism interface";
	c->init(ctxt,"pegpendulum" :: "/dis/danby/plugin/pegpendulum.dis" ::
		"danby-pegpendulum" :: nil);
}
