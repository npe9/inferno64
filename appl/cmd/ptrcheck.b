implement Ptrcheck;
include "sys.m";
	sys: Sys;
include "draw.m";
include "sh.m";

Ptrcheck: module {
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	ofd := sys->create("/tmp/ptrcheck.out", Sys->OWRITE, 8r666);
	if(ofd == nil)
		ofd = sys->fildes(2);

	fd := sys->open("/dev/pointer", Sys->OREAD);
	if(fd == nil)
		sys->fprint(ofd, "FAIL open /dev/pointer: %r\n");
	else
		sys->fprint(ofd, "OK /dev/pointer\n");

	cfd := sys->open("/dev/cursor", Sys->OWRITE);
	if(cfd == nil)
		sys->fprint(ofd, "FAIL open /dev/cursor: %r\n");
	else
		sys->fprint(ofd, "OK /dev/cursor\n");

	# hand off to wm
	sh := load Command "/dis/wm/wm.dis";
	if(sh == nil){
		sys->fprint(ofd, "FAIL load wm: %r\n");
		return;
	}
	sys->fprint(ofd, "starting wm\n");
	sh->init(ctxt, "wm/wm" :: nil);
}
