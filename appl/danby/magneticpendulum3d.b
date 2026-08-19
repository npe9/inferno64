implement Magneticpendulum3d;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Magneticpendulum3d: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Magneticpendulum3d: cannot load mechanism interface";
	c->init(ctxt,"magneticpendulum3d" :: "/dis/danby/plugin/magneticpendulum3d.dis" ::
		"danby-magneticpendulum3d" :: nil);
}
