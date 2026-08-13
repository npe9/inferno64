implement Incubation;
include "sys.m";
include "draw.m";
Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
Incubation: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/populations.dis";
	if(client == nil)
		raise "fail:Incubation: cannot load compartment interface";
	client->init(ctxt,
		"incubation" :: "/dis/danby/incubation.dis" ::
		"danby-incubation" :: nil);
}
