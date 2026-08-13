implement Dynamoreversal;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Dynamoreversal: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Dynamoreversal: cannot load mechanism interface";
	c->init(ctxt,"dynamoreversal" :: "/dis/danby/dynamoreversal.dis" :: "danby-dynamoreversal" :: nil);
}
