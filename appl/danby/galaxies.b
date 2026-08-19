implement Galaxies;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Galaxies: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/orbital.dis";
	if(c == nil)
		raise "fail:Galaxies: cannot load orbital interface";
	c->init(ctxt,"galaxies" :: "/dis/danby/plugin/galaxies.dis" :: "danby-galaxies" :: nil);
}
