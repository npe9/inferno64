implement Periodicvolterra;

include "sys.m";
	sys: Sys;
include "draw.m";

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Periodicvolterra: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	ecology := load Command "/dis/temple/ecology.dis";
	if(ecology == nil)
		raise "fail:Periodicvolterra: cannot load ecology interface";
	ecology->init(ctxt,
		"periodicvolterra" ::
		"/dis/danby/plugin/periodicvolterra.dis" ::
		"danby-periodicvolterra" :: nil);
}
