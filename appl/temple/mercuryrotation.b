implement Mercuryrotation;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Mercuryrotation: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Mercuryrotation: cannot load mechanism interface";
	c->init(ctxt,"mercuryrotation" :: "/dis/danby/mercuryrotation.dis" ::
		"danby-mercuryrotation" :: nil);
}
