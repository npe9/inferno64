implement Lakepollution;

include "sys.m";
include "draw.m";

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Lakepollution: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	populations := load Command "/dis/temple/populations.dis";
	if(populations == nil)
		raise "fail:Lakepollution: cannot load population interface";
	populations->init(ctxt,
		"lakepollution" :: "/dis/danby/plugin/lakepollution.dis" ::
		"danby-lakepollution" :: nil);
}
