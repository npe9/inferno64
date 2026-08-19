implement Stillmoreenzyme;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Stillmoreenzyme: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/populations.dis";
	if(c == nil)
		raise "fail:Stillmoreenzyme: cannot load populations interface";
	c->init(ctxt,"stillmoreenzyme" :: "/dis/danby/plugin/stillmoreenzyme.dis" :: "danby-stillmoreenzyme" :: nil);
}
