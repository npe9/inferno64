implement Poyntingrobertson;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Poyntingrobertson: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/orbital.dis";
	if(c == nil)
		raise "fail:Poyntingrobertson: cannot load orbital interface";
	c->init(ctxt,"poyntingrobertson" :: "/dis/danby/plugin/poyntingrobertson.dis" ::
		"danby-poyntingrobertson" :: nil);
}
