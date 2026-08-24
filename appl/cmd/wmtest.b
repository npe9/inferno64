implement Command;

#
# Make and unmake windows, repeatedly, and say whether any of it failed.
#
# wm(1) has no automated test at all, which is awkward for the part of it that
# has an open bug: Screen.newwindow() has been seen to return nil, rarely, and
# the report was never reproduced. It was characterised on a build where every
# unlock() was a plain store, so it may not be the same fault now, or any.
#
# Reproducing it needs the window-creation path exercised far more often than a
# person would, and that is all this does. It is not a clever test. Its value
# is the rate: a hundred windows in a run says more about a one-in-many fault
# than a session driven by hand ever will, and it says it in an exit status.
#
# The failure is no longer silent - every Limbo caller of newwindow reports the
# reason now (commit 8ad7019e) - so a nil here comes with an explanation rather
# than a blank window.
#
include "sys.m";
	sys: Sys;
	print, sprint, fprint: import sys;
include "draw.m";
	draw: Draw;
	Display, Image, Screen, Rect, Point: import draw;
include "tk.m";
	tk: Tk;
include "tkclient.m";
	tkclient: Tkclient;
include "arg.m";

Quitter: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

# End the "wmtest"le session, so that a run which finished can be told from one
# that hung. Without this every GUI run is killed by a timeout and reports the
# same status either way, which makes a hang invisible: nothing is printed and
# nothing breaks. quitall(1) is loaded rather than reimplemented.
quitsession()
{
	q := load Quitter "/dis/quitall.dis";
	if(q == nil){
		sys->print("%s: cannot load /dis/quitall.dis: %r\n", "wmtest");
		return;
	}
	q->init(nil, "quitall" :: nil);
}

rfd: ref Sys->FD;
quitwhendone := 0;

say(s: string)
{
	sys->print("%s", s);
	if(rfd != nil)
		fprint(rfd, "%s", s);
}

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

cfg := array[] of {
	"frame .f",
	"label .l -text {window} -width 120",
	"pack .l -in .f",
	"pack .f -fill both -expand 1",
	"pack propagate . 0",
	"update",
};

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	if(tk == nil || tkclient == nil || arg == nil){
		print("wmtest: load: %r\n");
		raise "fail:load";
	}

	n := 100;
	direct := 0;
	procs := 1;
	quit := 0;
	pixels := 0;
	result := "/wmtest.result";
	arg->init(argv);
	arg->setusage("wmtest [-n windows] [-p procs] [-d] [-k] [-q] [-r resultfile]");
	while((o := arg->opt()) != 0)
		case o {
		'n' =>	n = int arg->earg();
		'd' =>	direct++;	# Screen.newwindow itself, with no Tk above it
		'r' =>	result = arg->earg();
		'p' =>	procs = int arg->earg();	# make them concurrently
		'q' =>	quit++;		# end the session when finished
		'k' =>	pixels++;	# draw into them and check the pixels come back
		* =>	arg->usage();
		}

	if(ctxt == nil){
		fprint(sys->fildes(2), "wmtest: no window context\n");
		raise "fail:context";
	}

	# wm's Log window intercepts sys->print, so a result printed there is
	# invisible to whatever started this. It goes to a file.
	rfd = sys->create(result, Sys->OWRITE, 8r666);
	quitwhendone = quit;

	if(pixels){
		checkpixels(ctxt, n);
		return;
	}
	if(direct){
		newwindows(ctxt, n, procs);
		return;
	}

	tkclient->init();
	bad := 0;
	for(i := 0; i < n; i++){
		(t, nil) := tkclient->toplevel(ctxt, "", "wmtest " + string i, 0);
		if(t == nil){
			say(sprint("wmtest: toplevel %d of %d: nil: %r\n", i, n));
			bad++;
			continue;
		}
		for(j := 0; j < len cfg; j++)
			tk->cmd(t, cfg[j]);
		tkclient->onscreen(t, nil);
		tk->cmd(t, "update");

		# A window that exists but has no size is the same failure wearing
		# a different hat, so ask rather than assume it worked.
		w := int tk->cmd(t, ". cget -actwidth");
		h := int tk->cmd(t, ". cget -actheight");
		if(w <= 0 || h <= 0){
			say(sprint("wmtest: toplevel %d of %d came up %dx%d\n", i, n, w, h));
			bad++;
		}
		# Not wmctl "exit": that tells wm the client is finished, and wm
		# then takes the whole client away - the loop died silently on
		# its first pass. Dropping the reference is what unmaps one
		# window without ending the program.
		t = nil;
	}
	report("toplevels", n, bad);
}

#
# The same thing one layer down. Tk's toplevel does a great deal besides
# calling newwindow, so a failure through it does not say where the failure
# was; this calls Screen.newwindow directly, which is the function the open
# bug names.
#
newwindows(ctxt: ref Draw->Context, n, procs: int)
{
	disp := ctxt.display;
	if(disp == nil){
		say("wmtest: no display\n");
		raise "fail:context";
	}
	# Context.screen is filled in only by the multiplexer, so a client
	# started under wm(1) has none. tkclient allocates one on the display
	# image when there is no window manager, and the same is done here:
	# the function under test is Screen.newwindow either way.
	screen := ctxt.screen;
	if(screen == nil){
		di := disp.image;
		if(di == nil){
			say("wmtest: no display image\n");
			raise "fail:context";
		}
		screen = Screen.allocate(di, disp.color(Draw->Grey), 0);
		if(screen == nil){
			say(sprint("wmtest: cannot allocate a screen: %r\n"));
			raise "fail:screen";
		}
	}
	# Sequentially by default, and concurrently when asked. The concurrent
	# shape is the one worth running: the fault this is aimed at was first
	# characterised on a build where unlock() had no release barrier, so it
	# looked like a race, and one process making windows one after another
	# is close to the least likely way to provoke a race.
	if(procs < 1)
		procs = 1;
	each := n / procs;
	if(each < 1)
		each = 1;
	done := chan of int;
	for(i := 0; i < procs; i++)
		spawn maker(screen, each, i, done);
	bad := 0;
	for(i = 0; i < procs; i++)
		bad += <-done;
	report(sprint("newwindow calls in %d processes", procs), each*procs, bad);
}

maker(screen: ref Screen, n, who: int, done: chan of int)
{
	bad := 0;
	for(i := 0; i < n; i++){
		# a different rectangle per process, so they are not all
		# fighting over one piece of the screen and nothing is hidden
		# by two windows happening to coincide
		x := 10 + (who % 4) * 60;
		y := 10 + (who / 4) * 40;
		r := Rect(Point(x, y), Point(x+200, y+100));
		w := screen.newwindow(r, Draw->Refbackup, Draw->White);
		if(w == nil){
			say(sprint("wmtest: process %d, newwindow %d of %d: nil: %r\n",
				who, i, n));
			bad++;
			continue;
		}
		if(w.r.dx() != r.dx() || w.r.dy() != r.dy()){
			say(sprint("wmtest: process %d, newwindow %d of %d gave %dx%d, wanted %dx%d\n",
				who, i, n, w.r.dx(), w.r.dy(), r.dx(), r.dy()));
			bad++;
		}
		w = nil;
	}
	done <-= bad;
}

#
# Windows that exist are not windows that are right.
#
# Everything else here asks whether a window was made; nothing asks whether
# what was drawn into it is still there. That is the shape of the resize bugs
# this tree has actually had - a white block after a grow, icons going blank -
# where nothing faults, nothing is reported, and the pixels are simply wrong.
# It is the failure class faultprobe(1) calls a quiet wrong answer, and no
# amount of watching the output finds it.
#
# The windows are wm's, through tkclient(2), and not a screen of this
# program's own. A screen allocated on the display image does not survive a
# host resize - the image is replaced underneath it - so windows on one go
# uniformly background-coloured, every time, and reporting that as a fault
# would be reporting the documented behaviour of doing something unsupported.
# An earlier version of this did exactly that and looked like a discovery.
#
# Each widget is located again through Tk before the second reading, because a
# resize is allowed to move it. What is not allowed is for it to stop being
# the colour it was.
#
Nlabel: con 4;

labelcfg := array[] of {
	"frame .f",
	"label .a -text A -bg #cc4444 -width 60 -height 40",
	"label .b -text B -bg #44cc44 -width 60 -height 40",
	"label .c -text C -bg #4444cc -width 60 -height 40",
	"label .d -text D -bg #cccc44 -width 60 -height 40",
	"pack .a .b .c .d -in .f -side left",
	"pack .f",
	"update",
};

lname := array[] of {".a", ".b", ".c", ".d"};

checkpixels(ctxt: ref Draw->Context, nil: int)
{
	tkclient->init();
	(t, nil) := tkclient->toplevel(ctxt, "", "wmtest pixels", 0);
	if(t == nil){
		say(sprint("wmtest: toplevel: nil: %r\n"));
		raise "fail:toplevel";
	}
	for(i := 0; i < len labelcfg; i++)
		tk->cmd(t, labelcfg[i]);
	tkclient->onscreen(t, nil);
	tk->cmd(t, "update");

	first := array[Nlabel] of array of byte;
	for(i = 0; i < Nlabel; i++)
		first[i] = widgetpixel(t, lname[i]);

	bad := 0;
	distinct := 0;
	for(i = 0; i < Nlabel; i++){
		if(first[i] == nil){
			say(sprint("wmtest: %s: cannot read a pixel: %r\n", lname[i]));
			bad++;
			continue;
		}
		for(j := i+1; j < Nlabel; j++)
			if(first[j] != nil && !samebytes(first[i], first[j]))
				distinct++;
	}
	# four labels of four colours must read back as four things, or the
	# comparison below would pass for a window that was blank throughout
	if(distinct == 0){
		say("wmtest: the labels all read back alike, so this proves nothing\n");
		bad++;
	}

	sys->sleep(3000);		# whatever is going to disturb them, does

	tk->cmd(t, "update");
	for(i = 0; i < Nlabel; i++){
		if(first[i] == nil)
			continue;
		again := widgetpixel(t, lname[i]);
		if(again == nil){
			say(sprint("wmtest: %s: cannot read a pixel: %r\n", lname[i]));
			bad++;
			continue;
		}
		if(!samebytes(first[i], again)){
			say(sprint("wmtest: %s changed under it: %s then %s\n",
				lname[i], hex(first[i]), hex(again)));
			bad++;
		}
	}
	report("labels drawn and read back", Nlabel, bad);
}

#
# One pixel from the middle of a named widget, found through Tk so that a
# widget which has been moved is still read where it now is.
#
# The bytes are not decoded, deliberately: a window's channel is not
# necessarily the one a colour was given in, and the first attempt at this
# assumed an order, got every byte reversed, and reported every window broken
# when nothing was wrong with any of them. Comparing a widget with itself
# needs no encoding at all.
#
widgetpixel(t: ref Tk->Toplevel, w: string): array of byte
{
	if(t.image == nil)
		return nil;
	x := int tk->cmd(t, w + " cget -actx");
	y := int tk->cmd(t, w + " cget -acty");
	dw := int tk->cmd(t, w + " cget -actwidth");
	dh := int tk->cmd(t, w + " cget -actheight");
	if(dw <= 2 || dh <= 2)
		return nil;
	p := Point(t.image.r.min.x + x + dw/2, t.image.r.min.y + y + dh/2);
	buf := array[4] of byte;
	if(t.image.readpixels(Rect(p, Point(p.x+1, p.y+1)), buf) <= 0)
		return nil;
	return buf;
}

samebytes(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

hex(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += sprint("%.2ux", int a[i]);
	return s;
}

report(what: string, n, bad: int)
{
	if(bad == 0){
		say(sprint("wmtest: %d %s, none failed\nPASS\n", n, what));
		if(quitwhendone)
			quitsession();
		return;
	}
	say(sprint("wmtest: %d %s, %d failed\nFAIL\n", n, what, bad));
	if(quitwhendone)
		quitsession();
	raise "fail:test";
}
