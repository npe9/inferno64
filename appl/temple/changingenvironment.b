implement Changingenvironment;

include "sys.m";
include "draw.m";

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Changingenvironment: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	populations := load Command "/dis/temple/populations.dis";
	if(populations == nil)
		raise "fail:Changingenvironment: cannot load population interface";
	populations->init(ctxt,
		"changingenvironment" :: "/dis/danby/changingenvironment.dis" ::
		"danby-changingenvironment" :: nil);
}
