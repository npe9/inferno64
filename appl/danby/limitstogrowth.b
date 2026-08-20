implement Limitstogrowth;

include "sys.m";
include "draw.m";

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Limitstogrowth: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	populations := load Command "/dis/temple/populations.dis";
	if(populations == nil)
		raise "fail:Limitstogrowth: cannot load population interface";
	populations->init(ctxt,
		"limitstogrowth" :: "/dis/danby/plugin/limitstogrowth.dis" ::
		"danby-limitstogrowth" :: nil);
}
