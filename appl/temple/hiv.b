implement Hiv;
include "sys.m";
include "draw.m";
Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
Hiv: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/populations.dis";
	if(client == nil)
		raise "fail:Hiv: cannot load compartment interface";
	client->init(ctxt,
		"hiv" :: "/dis/danby/hiv.dis" ::
		"danby-hiv" :: nil);
}
