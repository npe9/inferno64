implement Internalcompetition;

include "sys.m";
include "draw.m";

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Internalcompetition: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	ecology := load Command "/dis/temple/ecology.dis";
	if(ecology == nil)
		raise "fail:Internalcompetition: cannot load ecology interface";
	ecology->init(ctxt,
		"internalcompetition" :: "/dis/danby/plugin/internalcompetition.dis" ::
		"danby-internalcompetition" :: nil);
}
