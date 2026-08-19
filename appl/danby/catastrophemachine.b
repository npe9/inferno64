implement Catastrophemachine;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Catastrophemachine: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Catastrophemachine: cannot load mechanism interface";
	c->init(ctxt,"catastrophemachine" :: "/dis/danby/plugin/catastrophemachine.dis" ::
		"danby-catastrophemachine" :: nil);
}
