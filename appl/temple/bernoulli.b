implement Bernoulli;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Bernoulli: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/mechanism.dis";
	if(c == nil)
		raise "fail:Bernoulli: cannot load mechanism interface";
	c->init(ctxt,"bernoulli" :: "/dis/danby/bernoulli.dis" :: "danby-bernoulli" :: nil);
}
