implement Logisticprey;

include "sys.m";
include "draw.m";

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Logisticprey: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	ecology := load Command "/dis/temple/ecology.dis";
	if(ecology == nil)
		raise "fail:Logisticprey: cannot load ecology interface";
	ecology->init(ctxt,
		"logisticprey" :: "/dis/danby/logisticprey.dis" ::
		"danby-logisticprey" :: nil);
}
