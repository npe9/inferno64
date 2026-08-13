implement Simplependulum;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Simplependulum: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Simplependulum: cannot load mechanism interface";
	c->init(ctxt,"simplependulum" :: "/dis/danby/simplependulum.dis" ::
		"danby-simplependulum" :: nil);
}
