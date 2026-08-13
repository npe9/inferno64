implement Malaria;
include "sys.m";
include "draw.m";
Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
Malaria: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/populations.dis";
	if(client == nil)
		raise "fail:Malaria: cannot load compartment interface";
	client->init(ctxt,
		"malaria" :: "/dis/danby/malaria.dis" ::
		"danby-malaria" :: nil);
}
