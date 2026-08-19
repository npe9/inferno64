implement Synchronousmotor;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Synchronousmotor: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Synchronousmotor: cannot load mechanism interface";
	c->init(ctxt,"synchronousmotor" :: "/dis/danby/plugin/synchronousmotor.dis" ::
		"danby-synchronousmotor" :: nil);
}
