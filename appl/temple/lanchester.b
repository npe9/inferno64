implement Lanchester;
include "sys.m";
include "draw.m";
Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
Lanchester: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/populations.dis";
	if(client == nil)
		raise "fail:Lanchester: cannot load model interface";
	client->init(ctxt,
		"lanchester" :: "/dis/danby/lanchester.dis" ::
		"danby-lanchester" :: nil);
}
