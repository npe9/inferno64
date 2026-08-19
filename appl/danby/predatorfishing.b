implement Predatorfishing;

include "sys.m";
	sys: Sys;
include "draw.m";

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Predatorfishing: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	ecology := load Command "/dis/temple/ecology.dis";
	if(ecology == nil)
		raise "fail:Predatorfishing: cannot load ecology interface";
	ecology->init(ctxt,
		"predatorfishing" ::
		"/dis/danby/plugin/predatorfishing.dis" ::
		"danby-predatorfishing" :: nil);
}
