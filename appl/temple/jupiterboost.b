implement Jupiterboost;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Jupiterboost: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/orbital.dis";
	if(c == nil)
		raise "fail:Jupiterboost: cannot load orbital interface";
	c->init(ctxt,"jupiterboost" :: "/dis/danby/jupiterboost.dis" ::
		"danby-jupiterboost" :: nil);
}
