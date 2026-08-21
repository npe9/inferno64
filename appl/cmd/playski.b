implement Command;

include "sys.m";
	sys: Sys;
include "draw.m";
include "sequencer.m";
	sequencer: Sequencer;

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	sequencer = load Sequencer Sequencer->PATH;
	if(sequencer == nil){
		sys->print("playski: cannot load %s: %r\n", Sequencer->PATH);
		return;
	}
	# sequencer(2)'s own init() is a complete standalone player - a
	# thin cmd wrapper around it only for a friendlier name than the
	# raw dis path, matching this tree's usual cmd/lib split. argv
	# already has the conventional arg0 slot filled in by the loader
	# (sequencer->init() itself drops it via "tl argv") - passed
	# through unchanged, not prepended again.
	sequencer->init(ctxt, argv);
}
