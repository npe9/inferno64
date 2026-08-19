implement Perihelion;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Perihelion: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/orbital.dis";
	if(c == nil)
		raise "fail:Perihelion: cannot load orbital interface";
	c->init(ctxt,"perihelion" :: "/dis/danby/plugin/perihelion.dis" :: "danby-perihelion" :: nil);
}
