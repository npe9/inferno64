implement Diseasebirthdeath2;

include "sys.m";
include "draw.m";

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Diseasebirthdeath2: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	populations := load Command "/dis/temple/populations.dis";
	if(populations == nil)
		raise "fail:Diseasebirthdeath2: cannot load compartment interface";
	populations->init(ctxt,
		"diseasebirthdeath2" :: "/dis/danby/plugin/diseasebirthdeath2.dis" ::
		"danby-diseasebirthdeath2" :: nil);
}
