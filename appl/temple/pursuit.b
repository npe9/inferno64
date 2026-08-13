implement Pursuit;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Pursuit: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Pursuit: cannot load mechanism interface";
	c->init(ctxt,"pursuit" :: "/dis/danby/pursuit.dis" :: "danby-pursuit" :: nil);
}
