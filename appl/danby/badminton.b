implement Badminton;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Badminton: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/trajectory.dis";
	if(client == nil)
		raise "fail:Badminton: cannot load trajectory interface";
	client->init(ctxt,"badminton" :: "/dis/danby/plugin/badminton.dis" ::
		"danby-badminton" :: nil);
}
