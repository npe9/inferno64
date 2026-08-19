implement Decomposition;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Decomposition: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/populations.dis";
	if(c == nil)
		raise "fail:Decomposition: cannot load populations interface";
	c->init(ctxt,"decomposition" :: "/dis/danby/plugin/decomposition.dis" :: "danby-decomposition" :: nil);
}
