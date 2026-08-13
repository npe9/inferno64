implement Heliumburning;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Heliumburning: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/populations.dis";
	if(c == nil)
		raise "fail:Heliumburning: cannot load populations interface";
	c->init(ctxt,"heliumburning" :: "/dis/danby/heliumburning.dis" ::
		"danby-heliumburning" :: nil);
}
