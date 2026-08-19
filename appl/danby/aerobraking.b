implement Aerobraking;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Aerobraking: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/orbital.dis";
	if(c == nil)
		raise "fail:Aerobraking: cannot load orbital interface";
	c->init(ctxt,"aerobraking" :: "/dis/danby/plugin/aerobraking.dis" ::
		"danby-aerobraking" :: nil);
}
