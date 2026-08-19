implement Fishingtwo;
include "sys.m";
include "draw.m";
Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
Fishingtwo: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/populations.dis";
	if(client == nil)
		raise "fail:Fishingtwo: cannot load model interface";
	client->init(ctxt,
		"fishingtwo" :: "/dis/danby/plugin/fishingtwo.dis" ::
		"danby-fishingtwo" :: nil);
}
