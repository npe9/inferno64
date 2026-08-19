implement Alternativepredation;

include "sys.m";
include "draw.m";

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Alternativepredation: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	ecology := load Command "/dis/temple/ecology.dis";
	if(ecology == nil)
		raise "fail:Alternativepredation: cannot load ecology interface";
	ecology->init(ctxt,
		"alternativepredation" :: "/dis/danby/plugin/alternativepredation.dis" ::
		"danby-alternativepredation" :: nil);
}
