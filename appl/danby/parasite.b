implement Parasite;

include "sys.m";
include "draw.m";

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Parasite: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	populations := load Command "/dis/temple/populations.dis";
	if(populations == nil)
		raise "fail:Parasite: cannot load population interface";
	populations->init(ctxt,
		"parasite" :: "/dis/danby/plugin/parasite.dis" ::
		"danby-parasite" :: nil);
}
