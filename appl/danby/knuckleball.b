implement Knuckleball;
include "sys.m";
include "draw.m";
Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
Knuckleball: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/trajectory.dis";
	if(client == nil)
		raise "fail:Knuckleball: cannot load trajectory interface";
	client->init(ctxt,
		"knuckleball" :: "/dis/danby/plugin/knuckleball.dis" ::
		"danby-knuckleball" :: nil);
}
