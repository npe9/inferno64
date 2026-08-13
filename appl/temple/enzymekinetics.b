implement Enzymekinetics;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Enzymekinetics: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/populations.dis";
	if(c == nil)
		raise "fail:Enzymekinetics: cannot load populations interface";
	c->init(ctxt,"enzymekinetics" :: "/dis/danby/enzymekinetics.dis" :: "danby-enzymekinetics" :: nil);
}
