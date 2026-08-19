implement Pendulumperiod;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Pendulumperiod: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Pendulumperiod: cannot load mechanism interface";
	c->init(ctxt,"pendulumperiod" :: "/dis/danby/plugin/pendulumperiod.dis" ::
		"danby-pendulumperiod" :: nil);
}
