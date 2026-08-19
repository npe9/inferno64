implement Diseasebirthdeath1;

include "sys.m";
include "draw.m";

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Diseasebirthdeath1: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	populations := load Command "/dis/temple/populations.dis";
	if(populations == nil)
		raise "fail:Diseasebirthdeath1: cannot load compartment interface";
	populations->init(ctxt,
		"diseasebirthdeath1" :: "/dis/danby/plugin/diseasebirthdeath1.dis" ::
		"danby-diseasebirthdeath1" :: nil);
}
