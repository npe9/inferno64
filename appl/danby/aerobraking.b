# aerobraking's own model (appl/danby/plugin/aerobraking.b) is a real
# command module now, not a bespoke Orbital-typed plugin - so this
# thin launcher points at appl/temple/eqnorbital.b, the harness built
# for that shape, not appl/temple/orbital.b (unchanged, still driving
# the other 11 hand-written Orbital plugins).
implement Aerobraking;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Aerobraking: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	c := load Command "/dis/temple/eqnorbital.dis";
	if(c == nil)
		raise "fail:Aerobraking: cannot load eqnorbital harness";
	c->init(ctxt,"aerobraking" :: "/dis/danby/plugin/aerobraking.dis" ::
		"danby-aerobraking" :: nil);
}
