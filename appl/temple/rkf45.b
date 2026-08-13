implement Rkf45;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Rkf45: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/methods.dis";
	if(c == nil)
		raise "fail:Rkf45: cannot load methods laboratory";
	c->init(ctxt,"rkf45" :: nil);
}
