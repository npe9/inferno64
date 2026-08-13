implement Migration;

include "sys.m";
include "draw.m";

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Migration: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	populations := load Command "/dis/temple/populations.dis";
	if(populations == nil)
		raise "fail:Migration: cannot load compartment interface";
	populations->init(ctxt,
		"migration" :: "/dis/danby/migration.dis" ::
		"danby-migration" :: nil);
}
