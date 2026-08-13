implement Lowthrust;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Lowthrust: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/orbital.dis";
	if(c == nil)
		raise "fail:Lowthrust: cannot load orbital interface";
	c->init(ctxt,"lowthrust" :: "/dis/danby/lowthrust.dis" :: "danby-lowthrust" :: nil);
}
