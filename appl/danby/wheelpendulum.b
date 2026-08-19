implement Wheelpendulum;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Wheelpendulum: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Wheelpendulum: cannot load mechanism interface";
	c->init(ctxt,"wheelpendulum" :: "/dis/danby/plugin/wheelpendulum.dis" ::
		"danby-wheelpendulum" :: nil);
}
