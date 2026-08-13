implement Crossinfection;
include "sys.m";
include "draw.m";
Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
Crossinfection: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/populations.dis";
	if(client == nil)
		raise "fail:Crossinfection: cannot load compartment interface";
	client->init(ctxt,
		"crossinfection" :: "/dis/danby/crossinfection.dis" ::
		"danby-crossinfection" :: nil);
}
