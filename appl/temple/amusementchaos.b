implement Amusementchaos;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Amusementchaos: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/mechanism.dis";
	if(client == nil)
		raise "fail:Amusementchaos: cannot load mechanism interface";
	client->init(ctxt,"amusementchaos" :: "/dis/danby/amusementchaos.dis" ::
		"danby-amusementchaos" :: nil);
}
