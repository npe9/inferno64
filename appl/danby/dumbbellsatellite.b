implement Dumbbellsatellite;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Dumbbellsatellite: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Dumbbellsatellite: cannot load mechanism interface";
	c->init(ctxt,"dumbbellsatellite" :: "/dis/danby/plugin/dumbbellsatellite.dis" ::
		"danby-dumbbellsatellite" :: nil);
}
