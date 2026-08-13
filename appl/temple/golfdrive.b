implement Golfdrive;
include "sys.m";
include "draw.m";
Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
Golfdrive: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/trajectory.dis";
	if(client == nil)
		raise "fail:Golfdrive: cannot load trajectory interface";
	client->init(ctxt,
		"golfdrive" :: "/dis/danby/golfdrive.dis" ::
		"danby-golfdrive" :: nil);
}
