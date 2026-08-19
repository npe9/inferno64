implement Logisticpredators;

include "sys.m";
include "draw.m";

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Logisticpredators: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	ecology := load Command "/dis/temple/ecology.dis";
	if(ecology == nil)
		raise "fail:Logisticpredators: cannot load ecology interface";
	ecology->init(ctxt,
		"logisticpredators" :: "/dis/danby/plugin/logisticpredators.dis" ::
		"danby-logisticpredators" :: nil);
}
