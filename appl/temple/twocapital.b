implement Twocapital;
include "sys.m";
include "draw.m";
Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
Twocapital: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/populations.dis";
	if(client == nil)
		raise "fail:Twocapital: cannot load model interface";
	client->init(ctxt,
		"twocapital" :: "/dis/danby/twocapital.dis" ::
		"danby-twocapital" :: nil);
}
