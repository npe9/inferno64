implement Starmodel;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Starmodel: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/profile.dis";
	if(c == nil)
		raise "fail:Starmodel: cannot load profile interface";
	c->init(ctxt,"starmodel" :: "/dis/danby/starmodel.dis" :: "danby-starmodel" :: nil);
}
