implement Carbonmicrophone;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Carbonmicrophone: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Carbonmicrophone: cannot load mechanism interface";
	c->init(ctxt,"carbonmicrophone" :: "/dis/danby/plugin/carbonmicrophone.dis" :: "danby-carbonmicrophone" :: nil);
}
