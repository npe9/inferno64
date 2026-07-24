implement Mousedev;
include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Rect: import draw;

Mousedev: module {
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;

	ofd := sys->create("/tmp/mousedev.out", Sys->OWRITE, 8r666);
	disp := Display.allocate(nil);
	if(disp == nil){
		sys->fprint(ofd, "display: %r\n");
		exit;
	}
	r := disp.image.r;
	sys->fprint(ofd, "display ok %d %d\n", r.dx(), r.dy());

	fd := sys->open("/dev/pointer", Sys->OREAD);
	if(fd == nil){
		sys->fprint(ofd, "open pointer: %r\n");
		exit;
	}
	sys->fprint(ofd, "listening\n");
	buf := array[49] of byte;
	for(i := 0; i < 30; i++){
		n := sys->read(fd, buf, len buf);
		if(n <= 0){
			sys->fprint(ofd, "read n=%d %r\n", n);
			break;
		}
		sys->fprint(ofd, "%s\n", string buf[0:n]);
	}
	sys->fprint(ofd, "done\n");
}
