implement Fishingone;
include "sys.m";
include "draw.m";
Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
Fishingone: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/populations.dis";
	if(client == nil)
		raise "fail:Fishingone: cannot load model interface";
	client->init(ctxt,
		"fishingone" :: "/dis/danby/fishingone.dis" ::
		"danby-fishingone" :: nil);
}
