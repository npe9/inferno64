implement Doublependulumapp;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Doublependulumapp: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Doublependulum: cannot load mechanism interface";
	c->init(ctxt,"doublependulum" :: "/dis/danby/plugin/doublependulum.dis" ::
		"danby-doublependulum" :: nil);
}
