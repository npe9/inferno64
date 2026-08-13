implement Rkf45system;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Rkf45system: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/solverlab.dis";
	if(c == nil)
		raise "fail:Rkf45system: cannot load solver laboratory";
	c->init(ctxt,"rkf45system" :: nil);
}
