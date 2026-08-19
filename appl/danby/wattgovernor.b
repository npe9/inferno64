implement Wattgovernor;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Wattgovernor: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Wattgovernor: cannot load mechanism interface";
	c->init(ctxt,"wattgovernor" :: "/dis/danby/plugin/wattgovernor.dis" :: "danby-wattgovernor" :: nil);
}
