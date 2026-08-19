implement Baseballpitch;
include "sys.m";
include "draw.m";
Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
Baseballpitch: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/trajectory.dis";
	if(client == nil)
		raise "fail:Baseballpitch: cannot load trajectory interface";
	client->init(ctxt,
		"baseballpitch" :: "/dis/danby/plugin/baseballpitch.dis" ::
		"danby-baseballpitch" :: nil);
}
