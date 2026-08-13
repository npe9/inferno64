implement Violetsantsrodents;

include "sys.m";
include "draw.m";

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Violetsantsrodents: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	populations := load Command "/dis/temple/populations.dis";
	if(populations == nil)
		raise "fail:Violetsantsrodents: cannot load population interface";
	populations->init(ctxt,
		"violetsantsrodents" :: "/dis/danby/violetsantsrodents.dis" ::
		"danby-violetsantsrodents" :: nil);
}
