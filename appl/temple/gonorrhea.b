implement Gonorrhea;
include "sys.m";
include "draw.m";
Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
Gonorrhea: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/populations.dis";
	if(client == nil)
		raise "fail:Gonorrhea: cannot load compartment interface";
	client->init(ctxt,
		"gonorrhea" :: "/dis/danby/gonorrhea.dis" ::
		"danby-gonorrhea" :: nil);
}
