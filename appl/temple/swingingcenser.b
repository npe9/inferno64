implement Swingingcenser;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Swingingcenser: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Swingingcenser: cannot load mechanism interface";
	c->init(ctxt,"swingingcenser" :: "/dis/danby/swingingcenser.dis" ::
		"danby-swingingcenser" :: nil);
}
