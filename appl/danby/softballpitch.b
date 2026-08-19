implement Softballpitch;
include "sys.m";
include "draw.m";
Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
Softballpitch: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/trajectory.dis";
	if(client == nil)
		raise "fail:Softballpitch: cannot load trajectory interface";
	client->init(ctxt,
		"softballpitch" :: "/dis/danby/plugin/softballpitch.dis" ::
		"danby-softballpitch" :: nil);
}
