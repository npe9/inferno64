implement Magneticpendulum2d;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Magneticpendulum2d: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Magneticpendulum2d: cannot load mechanism interface";
	c->init(ctxt,"magneticpendulum2d" :: "/dis/danby/magneticpendulum2d.dis" ::
		"danby-magneticpendulum2d" :: nil);
}
