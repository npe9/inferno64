implement Manyspecies;

include "sys.m";
include "draw.m";

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Manyspecies: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	populations := load Command "/dis/temple/populations.dis";
	if(populations == nil)
		raise "fail:Manyspecies: cannot load population interface";
	populations->init(ctxt,
		"manyspecies" :: "/dis/danby/manyspecies.dis" ::
		"danby-manyspecies" :: nil);
}
