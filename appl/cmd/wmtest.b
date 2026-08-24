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

rfd: ref Sys->FD;

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
	result := "/wmtest.result";
	arg->init(argv);
	arg->setusage("wmtest [-n windows] [-d] [-r resultfile]");
	while((o := arg->opt()) != 0)
		case o {
		'n' =>	n = int arg->earg();
		'd' =>	direct++;	# Screen.newwindow itself, with no Tk above it
		'r' =>	result = arg->earg();
		* =>	arg->usage();
		}

	if(ctxt == nil){
		fprint(sys->fildes(2), "wmtest: no window context\n");
		raise "fail:context";
	}

	# wm's Log window intercepts sys->print, so a result printed there is
	# invisible to whatever started this. It goes to a file.
	rfd = sys->create(result, Sys->OWRITE, 8r666);

	if(direct){
		newwindows(ctxt, n);
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
newwindows(ctxt: ref Draw->Context, n: int)
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
	bad := 0;
	for(i := 0; i < n; i++){
		r := Rect(Point(10, 10), Point(210, 110));
		w := screen.newwindow(r, Draw->Refbackup, Draw->White);
		if(w == nil){
			say(sprint("wmtest: newwindow %d of %d: nil: %r\n", i, n));
			bad++;
			continue;
		}
		if(w.r.dx() != r.dx() || w.r.dy() != r.dy()){
			say(sprint("wmtest: newwindow %d of %d gave %dx%d, wanted %dx%d\n",
				i, n, w.r.dx(), w.r.dy(), r.dx(), r.dy()));
			bad++;
		}
		w = nil;
	}
	report("newwindow calls", n, bad);
}

report(what: string, n, bad: int)
{
	if(bad == 0){
		say(sprint("wmtest: %d %s, none failed\nPASS\n", n, what));
		return;
	}
	say(sprint("wmtest: %d %s, %d failed\nFAIL\n", n, what, bad));
	raise "fail:test";
}
