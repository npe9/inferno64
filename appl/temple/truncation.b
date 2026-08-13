implement Truncation;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Truncation: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/methods.dis";
	if(c == nil)
		raise "fail:Truncation: cannot load methods laboratory";
	c->init(ctxt,"truncation" :: nil);
}
