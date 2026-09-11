implement Framegrab;

#
# Run a graphical program for a moment and write down what it drew.
#
# There was no way to do that.  The temple ports are demos: they open a
# window, draw, and keep drawing, and the only way to find out whether
# the picture was right was to look at the screen - which means being in
# front of it, and which is why doc/draw3d-adoption-plan.md has nine
# ports whose pictures "have not been checked".  Phase 1's evidence for
# those nine was a submission counter and a pixel count taken on the
# software path; neither says the GPU drew the right thing.
#
# This starts a module with a draw context, waits, reads the display
# back, and writes the pixels to a file with a few numbers about them.
# With no window manager the display IS what the program drew into, so
# what comes back is the frame.
#
# To compare a port against the other 3D provider without touching its
# source, bind one over the other first - the ports name the provider by
# path, and a path is a name in a namespace:
#
#	bind /dis/math/draw3d.dis /dis/math/draw3ddev.dis
#	framegrab -o soft.raw temple/shading
#
# and then again without the bind.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;

include "arg.m";

Command: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

Framegrab: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

stderr: ref Sys->FD;

usage()
{
	sys->fprint(stderr, "usage: framegrab [-n ms] [-o file] module [arg...]\n");
	raise "fail:usage";
}

fail(s: string)
{
	sys->fprint(stderr, "framegrab: %s\n", s);
	raise "fail:error";
}

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	draw = load Draw Draw->PATH;
	arg := load Arg Arg->PATH;
	if(arg == nil)
		fail(sys->sprint("cannot load %s: %r", Arg->PATH));

	ms := 1500;
	out := "framegrab.raw";
	arg->init(argv);
	arg->setusage("framegrab [-n ms] [-o file] module [arg...]");
	while((o := arg->opt()) != 0)
		case o {
		'n' =>	ms = int arg->earg();
		'o' =>	out = arg->earg();
		* =>	arg->usage();
		}
	argv = arg->argv();
	if(argv == nil)
		usage();
	if(ms < 1)
		ms = 1;

	name := hd argv;
	path := name;
	if(len path < 4 || path[len path-4:] != ".dis")
		path = "/dis/" + path + ".dis";
	m := load Command path;
	if(m == nil)
		fail(sys->sprint("cannot load %s: %r", path));

	wmclient = load Wmclient Wmclient->PATH;
	if(wmclient == nil)
		fail(sys->sprint("cannot load %s: %r", Wmclient->PATH));
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	if(ctxt == nil || ctxt.display == nil)
		fail("no draw context");

	# Its own process group, so that killing it later does not take this
	# program with it, and so that a port which calls NEWPGRP itself is
	# still reachable.
	pidc := chan of int;
	spawn runone(m, ctxt, argv, pidc);
	pid := <-pidc;

	sys->sleep(ms);

	d := ctxt.display;
	img := d.image;
	if(img == nil)
		fail("the display has no image");
	w := img.r.dx();
	h := img.r.dy();
	bpp := img.depth / 8;
	if(bpp < 1)
		bpp = 1;
	b := array[w*h*bpp] of byte;
	n := img.readpixels(img.r, b);
	kill(pid);
	if(n < 0)
		fail(sys->sprint("readpixels: %r"));

	fd := sys->create(out, Sys->OWRITE, 8r666);
	if(fd == nil)
		fail(sys->sprint("cannot create %s: %r", out));
	sys->write(fd, b, len b);

	# A few numbers, so a difference between two runs is visible without
	# rendering either of them.  The background is read from the corner
	# rather than written down here: a demo may clear to anything, and a
	# constant would silently count every pixel the day it changed.
	bg0 := b[0];
	bg1 := b[1];
	bg2 := b[2];
	lit := 0;
	white := 0;
	sum := 0;
	for(i := 0; i < w*h; i++){
		r := int b[i*bpp];
		g := int b[i*bpp+1];
		bl := int b[i*bpp+2];
		if(b[i*bpp] != bg0 || b[i*bpp+1] != bg1 || b[i*bpp+2] != bg2)
			lit++;
		if(r > 200 && g > 200 && bl > 200)
			white++;
		sum = (sum * 31 + r + g + bl) & 16r3FFFFFFF;
	}
	sys->print("framegrab: %s %dx%d depth %d after %d ms\n", name, w, h, img.depth, ms);
	sys->print("framegrab: not background %d of %d, near white %d, hash %d\n",
		lit, w*h, white, sum);
	sys->print("framegrab: wrote %s, %d bytes, %d bytes a pixel\n", out, len b, bpp);
}

runone(m: Command, ctxt: ref Draw->Context, argv: list of string, pidc: chan of int)
{
	sys->pctl(Sys->NEWPGRP, nil);
	pidc <-= sys->pctl(0, nil);
	{
		m->init(ctxt, argv);
	}exception e{
	"*" =>
		sys->fprint(stderr, "framegrab: %s raised %s\n", hd argv, e);
	}
}

# Kill the group, not the process: a demo that spawned helpers leaves
# them running otherwise, and emu does not exit while they live.
kill(pid: int)
{
	if(pid <= 0)
		return;
	fd := sys->open(sys->sprint("/prog/%d/ctl", pid), Sys->OWRITE);
	if(fd == nil)
		return;
	b := array of byte "killgrp";
	sys->write(fd, b, len b);
}
