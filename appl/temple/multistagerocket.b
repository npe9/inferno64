implement Multistagerocket;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Multistagerocket: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Multistagerocket: cannot load mechanism interface";
	c->init(ctxt,"multistagerocket" :: "/dis/danby/multistagerocket.dis" ::
		"danby-multistagerocket" :: nil);
}
