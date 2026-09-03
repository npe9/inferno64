implement Command;

# s3test(1) - drives s3(1)'s own in-process test seams: the XML pulls
# offline, then a real bogus-credential signed request to real S3 that
# must draw AWS's own signed error back (proving sign->TLS->S3->parse
# end to end without a real account). SigV4 signing itself is pinned
# against published vectors by awsv4test(1). The offline seam runs
# first, so a network outage fails late with the live leg named.

include "sys.m";
	sys: Sys;
include "draw.m";

Modelcmd: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
	badauthtest: fn(): string;
	listparsetest: fn(): string;
};

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	m := load Modelcmd "/dis/s3.dis";
	if(sys == nil || m == nil){
		sys->print("load failed\n");
		raise "fail:load";
	}
	failed := 0;
	failed += report("listparsetest", m->listparsetest());
	failed += report("badauthtest", m->badauthtest());
	if(failed){
		sys->print("s3test: %d FAILURE(S)\n", failed);
		raise "fail:tests";
	}
	sys->print("PASS\n");
}

report(name, err: string): int
{
	if(err != nil){
		sys->print("FAIL: %s: %s\n", name, err);
		return 1;
	}
	sys->print("%s: PASS\n", name);
	return 0;
}
