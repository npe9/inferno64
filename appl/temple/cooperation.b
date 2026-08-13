implement Cooperation;

include "sys.m";
include "draw.m";

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Cooperation: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	ecology := load Command "/dis/temple/ecology.dis";
	if(ecology == nil)
		raise "fail:Cooperation: cannot load ecology interface";
	ecology->init(ctxt,
		"cooperation" :: "/dis/danby/cooperation.dis" ::
		"danby-cooperation" :: nil);
}
