implement Drypendulum;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Drypendulum: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Drypendulum: cannot load mechanism interface";
	c->init(ctxt,"drypendulum" :: "/dis/danby/drypendulum.dis" ::
		"danby-drypendulum" :: nil);
}
