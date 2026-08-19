implement Moreenzyme;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Moreenzyme: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/populations.dis";
	if(c == nil)
		raise "fail:Moreenzyme: cannot load populations interface";
	c->init(ctxt,"moreenzyme" :: "/dis/danby/plugin/moreenzyme.dis" :: "danby-moreenzyme" :: nil);
}
