implement Budworm;

include "sys.m";
include "draw.m";

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Budworm: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	populations := load Command "/dis/temple/populations.dis";
	if(populations == nil)
		raise "fail:Budworm: cannot load population interface";
	populations->init(ctxt,
		"budworm" :: "/dis/danby/plugin/budworm.dis" ::
		"danby-budworm" :: nil);
}
