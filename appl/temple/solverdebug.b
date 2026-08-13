implement Solverdebug;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Solverdebug: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/solverlab.dis";
	if(c == nil)
		raise "fail:Solverdebug: cannot load solver laboratory";
	c->init(ctxt,"solverdebug" :: nil);
}
