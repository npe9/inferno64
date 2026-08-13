implement Enzymeapplication;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Enzymeapplication: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/populations.dis";
	if(c == nil)
		raise "fail:Enzymeapplication: cannot load populations interface";
	c->init(ctxt,"enzymeapplication" :: "/dis/danby/enzymeapplication.dis" :: "danby-enzymeapplication" :: nil);
}
