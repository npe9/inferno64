implement Weightchange;
include "sys.m";
include "draw.m";
Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
Weightchange: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/populations.dis";
	if(client == nil)
		raise "fail:Weightchange: cannot load stock interface";
	client->init(ctxt,
		"weightchange" :: "/dis/danby/plugin/weightchange.dis" ::
		"danby-weightchange" :: nil);
}
