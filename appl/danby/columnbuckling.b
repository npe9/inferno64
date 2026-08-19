implement Columnbuckling;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Columnbuckling: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Columnbuckling: cannot load mechanism interface";
	c->init(ctxt,"columnbuckling" :: "/dis/danby/plugin/columnbuckling.dis" ::
		"danby-columnbuckling" :: nil);
}
