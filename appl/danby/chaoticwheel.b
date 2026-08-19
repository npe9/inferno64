implement Chaoticwheel;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Chaoticwheel: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Chaoticwheel: cannot load mechanism interface";
	c->init(ctxt,"chaoticwheel" :: "/dis/danby/plugin/chaoticwheel.dis" ::
		"danby-chaoticwheel" :: nil);
}
