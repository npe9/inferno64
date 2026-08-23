implement Command;

#
# Show what a program's own bind does to a trace of it.
#
# The interposition iostats(4) does is on the name space, so what a trace
# captures is what the program reaches through the name space. A program that
# attaches a kernel device itself reaches it directly instead, past anything
# mounted on the way, and none of that traffic is recorded.
#
# That is not a hypothetical: it is what a graphics program normally does.
# So this does the same small piece of work twice over - allocate a display
# and an image, through libdraw, nothing exotic - and differs only in whether
# it binds #i onto /dev itself or inherits a /dev its parent bound. Trace it
# both ways and the difference is the whole point:
#
#	iostats -t /a.styx drawbind		# inherits /dev
#	iostats -t /b.styx drawbind -b		# binds #i itself
#	styxlog -f draw /a.styx			# three opens and a write
#	styxlog -f draw /b.styx			# nothing at all
#
include "sys.m";
	sys: Sys;
	print, fprint: import sys;
include "draw.m";
	draw: Draw;
	Display, Image, Rect, Point: import draw;
include "arg.m";

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	arg := load Arg Arg->PATH;
	if(draw == nil || arg == nil){
		print("drawbind: load: %r\n");
		raise "fail:load";
	}

	bindit := 0;
	arg->init(argv);
	arg->setusage("drawbind [-b]");
	while((o := arg->opt()) != 0)
		case o {
		'b' =>	bindit++;	# attach the device here, escaping any trace
		* =>	arg->usage();
		}
	if(arg->argv() != nil)
		arg->usage();

	if(bindit && sys->bind("#i", "/dev", Sys->MBEFORE) < 0){
		fprint(sys->fildes(2), "drawbind: bind #i: %r\n");
		raise "fail:bind";
	}

	# Display.allocate opens /dev/draw/new by name, so this is an ordinary
	# use of the name space and nothing here is aware of the trace.
	display := Display.allocate(nil);
	if(display == nil){
		fprint(sys->fildes(2), "drawbind: allocate display: %r\n");
		raise "fail:display";
	}
	img := display.newimage(Rect(Point(0,0), Point(64,64)), display.image.chans, 0, Draw->Black);
	if(img == nil){
		fprint(sys->fildes(2), "drawbind: allocate image: %r\n");
		raise "fail:image";
	}
	how := "using an inherited";
	if(bindit)
		how = "having bound #i onto";
	print("drawbind: allocated a %dx%d image, %s /dev\n", img.r.dx(), img.r.dy(), how);
}
