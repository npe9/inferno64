implement Grandtour;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Grandtour: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/orbital.dis";
	if(c == nil)
		raise "fail:Grandtour: cannot load orbital interface";
	c->init(ctxt,"grandtour" :: "/dis/danby/grandtour.dis" :: "danby-grandtour" :: nil);
}
