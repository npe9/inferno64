implement Vanderpol;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Vanderpol: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Vanderpol: cannot load mechanism interface";
	c->init(ctxt,"vanderpol" :: "/dis/danby/vanderpol.dis" :: "danby-vanderpol" :: nil);
}
