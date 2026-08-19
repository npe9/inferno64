implement Pistonflywheel;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Pistonflywheel: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Pistonflywheel: cannot load mechanism interface";
	c->init(ctxt,"pistonflywheel" :: "/dis/danby/plugin/pistonflywheel.dis" :: "danby-pistonflywheel" :: nil);
}
