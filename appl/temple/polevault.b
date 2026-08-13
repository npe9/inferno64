implement Polevault;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Polevault: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/mechanism.dis";
	if(client == nil)
		raise "fail:Polevault: cannot load mechanism interface";
	client->init(ctxt,"polevault" :: "/dis/danby/polevault.dis" ::
		"danby-polevault" :: nil);
}
