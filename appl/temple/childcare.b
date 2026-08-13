implement Childcare;

include "sys.m";
include "draw.m";

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Childcare: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	populations := load Command "/dis/temple/populations.dis";
	if(populations == nil)
		raise "fail:Childcare: cannot load population interface";
	populations->init(ctxt,
		"childcare" :: "/dis/danby/childcare.dis" ::
		"danby-childcare" :: nil);
}
