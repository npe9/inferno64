implement Violinbow;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Violinbow: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Violinbow: cannot load mechanism interface";
	c->init(ctxt,"violinbow" :: "/dis/danby/violinbow.dis" ::
		"danby-violinbow" :: nil);
}
