implement Seasonaldisease;
include "sys.m";
include "draw.m";
Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
Seasonaldisease: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/populations.dis";
	if(client == nil)
		raise "fail:Seasonaldisease: cannot load compartment interface";
	client->init(ctxt,
		"seasonaldisease" :: "/dis/danby/seasonaldisease.dis" ::
		"danby-seasonaldisease" :: nil);
}
