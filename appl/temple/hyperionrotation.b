implement Hyperionrotation;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Hyperionrotation: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Hyperionrotation: cannot load mechanism interface";
	c->init(ctxt,"hyperionrotation" :: "/dis/danby/hyperionrotation.dis" ::
		"danby-hyperionrotation" :: nil);
}
