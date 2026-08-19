implement Cannibalism;

include "sys.m";
include "draw.m";

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Cannibalism: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	populations := load Command "/dis/temple/populations.dis";
	if(populations == nil)
		raise "fail:Cannibalism: cannot load population interface";
	populations->init(ctxt,
		"cannibalism" :: "/dis/danby/plugin/cannibalism.dis" ::
		"danby-cannibalism" :: nil);
}
