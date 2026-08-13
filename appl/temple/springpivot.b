implement Springpivot;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Springpivot: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Springpivot: cannot load mechanism interface";
	c->init(ctxt,"springpivot" :: "/dis/danby/springpivot.dis" ::
		"danby-springpivot" :: nil);
}
