implement Spinningball;
include "sys.m";
include "draw.m";
Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
Spinningball: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/trajectory.dis";
	if(client == nil)
		raise "fail:Spinningball: cannot load trajectory interface";
	client->init(ctxt,
		"spinningball" :: "/dis/danby/plugin/spinningball.dis" ::
		"danby-spinningball" :: nil);
}
