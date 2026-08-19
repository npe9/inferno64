implement Foodchain;

include "sys.m";
include "draw.m";

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Foodchain: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	populations := load Command "/dis/temple/populations.dis";
	if(populations == nil)
		raise "fail:Foodchain: cannot load population interface";
	populations->init(ctxt,
		"foodchain" :: "/dis/danby/plugin/foodchain.dis" ::
		"danby-foodchain" :: nil);
}
